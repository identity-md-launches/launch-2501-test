// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Test actor funded from its own balances. All callbacks and settlement for a batch
/// happen in one external call, so EIP-1153 state has the same lifetime as a real transaction.
contract SwapProbe is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }
    receive() external payable {}

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        SwapParams[] memory sequence = new SwapParams[](1);
        sequence[0] = params;
        (BalanceDelta[] memory deltas,) = batch(key, sequence, false);
        return deltas[0];
    }

    function batch(PoolKey memory key, SwapParams[] memory sequence, bool catchFirst)
        public
        returns (BalanceDelta[] memory deltas, bool firstReverted)
    {
        return abi.decode(manager.unlock(abi.encode(key, sequence, catchFirst)), (BalanceDelta[], bool));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "SwapProbe: manager only");
        (PoolKey memory key, SwapParams[] memory sequence, bool catchFirst) =
            abi.decode(data, (PoolKey, SwapParams[], bool));
        BalanceDelta[] memory deltas = new BalanceDelta[](sequence.length);
        bool firstReverted;
        for (uint256 i; i < sequence.length; ++i) {
            if (i == 0 && catchFirst) {
                try manager.swap(key, sequence[i], "") returns (BalanceDelta d) {
                    deltas[i] = d;
                } catch {
                    firstReverted = true;
                }
            } else {
                deltas[i] = manager.swap(key, sequence[i], "");
            }
            _settle(key.currency0, deltas[i].amount0());
            _settle(key.currency1, deltas[i].amount1());
        }
        // Inspect transient accounting inside the unlock, before the transaction ends.
        // A later top-level test call would see cleared transient slots.
        require(manager.isUnlocked(), "SwapProbe: callback must be inside unlock");
        require(manager.getNonzeroDeltaCount() == 0, "SwapProbe: unsettled deltas");
        require(manager.currencyDelta(address(this), key.currency0) == 0, "SwapProbe: ETH debt");
        require(manager.currencyDelta(address(this), key.currency1) == 0, "SwapProbe: token debt");
        require(manager.currencyDelta(address(key.hooks), key.currency0) == 0, "SwapProbe: hook ETH debt");
        require(manager.currencyDelta(address(key.hooks), key.currency1) == 0, "SwapProbe: hook token debt");
        return abi.encode(deltas, firstReverted);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            // Explicitly reset the synced currency for native ETH too.
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: amount}();
            } else {
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(uint128(delta)));
        }
    }
}
