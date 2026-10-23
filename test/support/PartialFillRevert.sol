// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LaunchHook} from "src/LaunchHook.sol";

/// @dev Decodes the PoolManager's wrapped revert of `LaunchHook.afterSwap` into the hook's PartialFill
/// arguments. Any other revert (a different hook error, a different callback, a manager error) fails `ok`.
library PartialFillRevert {
    function decode(bytes memory reason, address hook)
        internal
        pure
        returns (bool ok, uint256 assumed, uint256 executed)
    {
        if (reason.length < 4 || bytes4(reason) != CustomRevert.WrappedError.selector) return (false, 0, 0);
        (address target, bytes4 selector, bytes memory inner, bytes memory details) =
            abi.decode(_tail(reason), (address, bytes4, bytes, bytes));
        if (target != hook || selector != IHooks.afterSwap.selector) return (false, 0, 0);
        if (details.length < 4 || bytes4(details) != Hooks.HookCallFailed.selector) return (false, 0, 0);
        if (inner.length != 68 || bytes4(inner) != LaunchHook.PartialFill.selector) return (false, 0, 0);
        (assumed, executed) = abi.decode(_tail(inner), (uint256, uint256));
        ok = true;
    }

    function _tail(bytes memory data) private pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }
}
