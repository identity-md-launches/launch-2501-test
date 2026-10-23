// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title HookFlags
/// @notice The permission bits a Uniswap v4 hook address carries, and helpers to compare an address with a
/// declared set of flags. Mirrors `Hooks` so address mining and the launch floor can reason about the bits
/// without importing the whole library.
library HookFlags {
    uint160 internal constant ALL = Hooks.ALL_HOOK_MASK;

    uint160 internal constant BEFORE_INITIALIZE = Hooks.BEFORE_INITIALIZE_FLAG;
    uint160 internal constant AFTER_INITIALIZE = Hooks.AFTER_INITIALIZE_FLAG;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
    uint160 internal constant AFTER_ADD_LIQUIDITY = Hooks.AFTER_ADD_LIQUIDITY_FLAG;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
    uint160 internal constant BEFORE_SWAP = Hooks.BEFORE_SWAP_FLAG;
    uint160 internal constant AFTER_SWAP = Hooks.AFTER_SWAP_FLAG;
    uint160 internal constant BEFORE_DONATE = Hooks.BEFORE_DONATE_FLAG;
    uint160 internal constant AFTER_DONATE = Hooks.AFTER_DONATE_FLAG;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

    /// @notice The permission bits encoded in `hook`'s address.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice Whether `hook`'s address carries exactly `flags` (and no other permission bit).
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }

    /// @notice The flags a `Hooks.Permissions` struct declares, as address bits.
    function fromPermissions(Hooks.Permissions memory p) internal pure returns (uint160 flags) {
        if (p.beforeInitialize) flags |= BEFORE_INITIALIZE;
        if (p.afterInitialize) flags |= AFTER_INITIALIZE;
        if (p.beforeAddLiquidity) flags |= BEFORE_ADD_LIQUIDITY;
        if (p.afterAddLiquidity) flags |= AFTER_ADD_LIQUIDITY;
        if (p.beforeRemoveLiquidity) flags |= BEFORE_REMOVE_LIQUIDITY;
        if (p.afterRemoveLiquidity) flags |= AFTER_REMOVE_LIQUIDITY;
        if (p.beforeSwap) flags |= BEFORE_SWAP;
        if (p.afterSwap) flags |= AFTER_SWAP;
        if (p.beforeDonate) flags |= BEFORE_DONATE;
        if (p.afterDonate) flags |= AFTER_DONATE;
        if (p.beforeSwapReturnDelta) flags |= BEFORE_SWAP_RETURN_DELTA;
        if (p.afterSwapReturnDelta) flags |= AFTER_SWAP_RETURN_DELTA;
        if (p.afterAddLiquidityReturnDelta) flags |= AFTER_ADD_LIQUIDITY_RETURN_DELTA;
        if (p.afterRemoveLiquidityReturnDelta) flags |= AFTER_REMOVE_LIQUIDITY_RETURN_DELTA;
    }
}
