// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Minimal test router and liquidity provider. It pays the PoolManager from its own balances (fund it
/// with `vm.deal` / token transfers) and keeps whatever it receives, so a test reads its balances directly.
contract Swapper is IUnlockCallback {
    IPoolManager public immutable manager;

    uint8 private constant ACTION_SWAP = 1;
    uint8 private constant ACTION_LIQUIDITY = 2;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    /// @notice Exact-input swap of `amountIn` of the input currency.
    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (BalanceDelta) {
        return swapExact(key, zeroForOne, -int256(amountIn));
    }

    /// @notice Swap with v4 semantics: negative `amountSpecified` is exact input, positive is exact output.
    function swapExact(PoolKey memory key, bool zeroForOne, int256 amountSpecified) public returns (BalanceDelta) {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return swapWithLimit(key, zeroForOne, amountSpecified, limit);
    }

    /// @notice Swap with an explicit price limit; a limit the pool reaches first leaves the swap partially filled.
    function swapWithLimit(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        public
        returns (BalanceDelta)
    {
        bytes memory result =
            manager.unlock(abi.encode(ACTION_SWAP, abi.encode(key, zeroForOne, amountSpecified, sqrtPriceLimitX96)));
        return abi.decode(result, (BalanceDelta));
    }

    /// @notice Add (or, with a negative delta, remove) liquidity on this contract's position.
    function modifyLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        returns (BalanceDelta)
    {
        bytes memory result =
            manager.unlock(abi.encode(ACTION_LIQUIDITY, abi.encode(key, tickLower, tickUpper, liquidityDelta)));
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "Swapper: not manager");
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        BalanceDelta delta;
        PoolKey memory key;
        if (action == ACTION_SWAP) {
            (PoolKey memory k, bool zeroForOne, int256 amountSpecified, uint160 limit) =
                abi.decode(payload, (PoolKey, bool, int256, uint160));
            key = k;
            delta = manager.swap(
                key,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
                ""
            );
        } else {
            (PoolKey memory k, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
                abi.decode(payload, (PoolKey, int24, int24, int256));
            key = k;
            (delta,) = manager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
                }),
                ""
            );
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owedAmount = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owedAmount}();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).transfer(address(manager), owedAmount);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
