// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchHookBase} from "./LaunchHookBase.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LaunchHook} from "../src/LaunchHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {GasHungryVault, IPullable} from "./mocks/Recipients.sol";

/// @notice Partial fills. A swap stops early when it reaches `sqrtPriceLimitX96` or when the pool runs out
/// of the output currency; v4 does not revert on that. When ETH is the specified currency the fee was sized
/// in `beforeSwap` from the requested amount and cannot be resized, so the hook refuses the partial fill.
/// When ETH is the unspecified currency the fee is sized from the executed amount and partial fills work.
contract LaunchHookPartialFillTest is LaunchHookBase {
    using StateLibrary for IPoolManager;

    /// @dev A price limit this close to the current price stops the swap after a tiny fill.
    uint160 internal constant NEAR = 1e12;

    // ------------------------------------------------------------------------------------------------
    // ETH specified: partial fills revert, nothing moves
    // ------------------------------------------------------------------------------------------------

    function test_partialExactInputBuy_reverts() public {
        Snapshot memory before = _snap();
        (uint256 assumed, uint256 executed) = _expectPartialFill(true, -1 ether, SQRT_PRICE_1_1 - NEAR);
        assertEq(assumed, 0.7 ether, "fee was sized for the full 1 ETH input minus 30%");
        assertLt(executed, assumed, "the pool swapped less");
        assertGt(executed, 0, "but not nothing");
        _assertUnchanged(before);
    }

    function test_partialExactInputBuy_afterWindow_reverts() public {
        vm.warp(launchedAt + 3600);
        Snapshot memory before = _snap();
        (uint256 assumed,) = _expectPartialFill(true, -1 ether, SQRT_PRICE_1_1 - NEAR);
        assertEq(assumed, 0.98 ether);
        _assertUnchanged(before);
    }

    function test_partialExactOutputSell_priceLimit_reverts() public {
        _primePoolWithEth(10 ether);
        _giveTokens(address(swapper), 1_000_000 ether);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        Snapshot memory before = _snap();
        (uint256 assumed, uint256 executed) = _expectPartialFill(false, 0.1 ether, price + NEAR);
        assertEq(assumed, 0.1 ether + uint256(0.1 ether) * 200 / (BPS - 200), "fee sized for the full gross");
        assertLt(executed, assumed);
        _assertUnchanged(before);
    }

    function test_exactOutputSellBeyondPoolEth_reverts() public {
        // Before any buy the pool holds no ETH: an exact-output sell can fill nothing.
        _giveTokens(address(swapper), 1_000_000 ether);
        Snapshot memory before = _snap();
        (uint256 assumed, uint256 executed) = _expectPartialFill(false, 1 ether, 0);
        assertEq(assumed, 1 ether + uint256(1 ether) * 200 / (BPS - 200));
        assertEq(executed, 0, "the pool paid nothing");
        _assertUnchanged(before);
    }

    function test_exactOutputSellMoreThanPoolHolds_reverts() public {
        _primePoolWithEth(1 ether); // the pool now holds 0.7 ETH
        _giveTokens(address(swapper), 1_000_000 ether);
        Snapshot memory before = _snap();
        (uint256 assumed, uint256 executed) = _expectPartialFill(false, 5 ether, 0);
        assertGt(assumed, executed);
        assertLe(executed, 0.7 ether, "at most what the pool holds");
        _assertUnchanged(before);
    }

    function test_fullFillWithPriceLimitStillWorks() public {
        // A limit the swap does not reach is an ordinary full fill.
        Snapshot memory before = _snap();
        swapper.swapWithLimit(key, true, -1 ether, SQRT_PRICE_1_1 / 2);
        Snapshot memory after_ = _snap();
        assertEq(before.swapperEth - after_.swapperEth, 1 ether);
        assertEq(after_.devEth - before.devEth, 0.005 ether);
        assertEq(after_.vaultEth - before.vaultEth, 0.295 ether);
    }

    // ------------------------------------------------------------------------------------------------
    // ETH unspecified: partial fills pay the rate on the executed ETH
    // ------------------------------------------------------------------------------------------------

    function test_partialExactOutputBuy_paysFeeOnExecutedEth() public {
        Snapshot memory before = _snap();
        uint256 wanted = 1_000_000 ether;

        BalanceDelta delta = swapper.swapWithLimit(key, true, int256(wanted), SQRT_PRICE_1_1 - NEAR);
        Snapshot memory after_ = _snap();

        uint256 got = after_.swapperToken - before.swapperToken;
        assertGt(got, 0, "something filled");
        assertLt(got, wanted, "genuinely partial");
        assertEq(uint256(int256(delta.amount1())), got);
        uint256 poolEth = after_.managerEth - before.managerEth;
        uint256 paid = before.swapperEth - after_.swapperEth;
        uint256 fee = paid - poolEth;
        assertEq(fee, poolEth * 3000 / (BPS - 3000), "30% of gross on the executed ETH only");
        assertEq(after_.devEth - before.devEth, paid * 50 / BPS, "dev 0.5% of gross");
        assertEq(after_.vaultEth - before.vaultEth, fee - paid * 50 / BPS, "vault the rest");
        assertLe(fee * BPS, paid * 3000 + BPS, "never above the 30% cap");
    }

    function test_partialExactInputSell_paysFeeOnExecutedEth() public {
        _primePoolWithEth(10 ether);
        _giveTokens(address(swapper), 1_000_000 ether);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        Snapshot memory before = _snap();
        uint256 offered = 1_000_000 ether;

        swapper.swapWithLimit(key, false, -int256(offered), price + NEAR);
        Snapshot memory after_ = _snap();

        uint256 sold = before.swapperToken - after_.swapperToken;
        assertGt(sold, 0, "something filled");
        assertLt(sold, offered, "genuinely partial");
        uint256 gross = before.managerEth - after_.managerEth;
        uint256 fee = gross * 200 / BPS;
        assertGt(gross, 0);
        assertEq(after_.swapperEth - before.swapperEth, gross - fee, "seller gets gross minus 2% of it");
        assertEq(after_.devEth - before.devEth, gross * 50 / BPS);
        assertEq(after_.vaultEth - before.vaultEth, fee - gross * 50 / BPS);
    }

    // ------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------

    /// @dev Runs a swap that must stop early and asserts it reverted with the hook's `PartialFill`, wrapped by
    /// the PoolManager in `WrappedError(hook, afterSwap, PartialFill(...), HookCallFailed())`.
    function _expectPartialFill(bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (uint256 assumed, uint256 executed)
    {
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        try swapper.swapWithLimit(key, zeroForOne, amountSpecified, limit) {
            fail("swap should have reverted with PartialFill");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "PoolManager wraps hook reverts");
            bytes memory body = new bytes(reason.length - 4);
            for (uint256 i = 0; i < body.length; i++) {
                body[i] = reason[i + 4];
            }
            (address target, bytes4 selector, bytes memory inner, bytes memory details) =
                abi.decode(body, (address, bytes4, bytes, bytes));
            assertEq(target, address(hook));
            assertEq(selector, IHooks.afterSwap.selector);
            assertEq(bytes4(details), Hooks.HookCallFailed.selector);
            assertEq(bytes4(inner), LaunchHook.PartialFill.selector, "inner error is PartialFill");
            bytes memory args = new bytes(inner.length - 4);
            for (uint256 i = 0; i < args.length; i++) {
                args[i] = inner[i + 4];
            }
            (assumed, executed) = abi.decode(args, (uint256, uint256));
        }
    }

    function _assertUnchanged(Snapshot memory before) internal view {
        Snapshot memory now_ = _snap();
        assertEq(now_.swapperEth, before.swapperEth, "swapper ETH untouched");
        assertEq(now_.swapperToken, before.swapperToken, "swapper tokens untouched");
        assertEq(now_.managerEth, before.managerEth, "pool ETH untouched");
        assertEq(now_.devEth, before.devEth, "dev got nothing");
        assertEq(now_.vaultEth, before.vaultEth, "vault got nothing");
        assertEq(now_.hookEth, before.hookEth, "hook holds nothing new");
        assertEq(hook.owed(dev), 0);
        assertEq(hook.owed(address(vault)), 0);
        assertEq(hook.pendingClaims(), 0);
    }
}

/// @notice `withdrawFor`: anyone may deliver a recipient's credit to that recipient with all gas, so a
/// recipient contract that cannot call `withdraw` itself is never stuck.
contract LaunchHookWithdrawForTest is LaunchHookBase {
    address internal stranger = makeAddr("stranger");

    function test_withdrawFor_deliversToRecipientWithFullGas() public {
        GasHungryVault hungry = new GasHungryVault();
        uint160 flags = HookFlags.fromPermissions(hook.getHookPermissions());
        address at = address((uint160(0x2222) << 144) | flags);
        deployCodeTo("LaunchHook.sol:LaunchHook", abi.encode(manager, token, owner, address(hungry), dev), at);
        LaunchHook h = LaunchHook(payable(at));
        PoolKey memory k = key;
        k.hooks = IHooks(address(h));
        vm.prank(factory);
        manager.initialize(k, SQRT_PRICE_1_1);
        seeder.modifyLiquidity(k, -887_220, 0, SEED_LIQUIDITY / 5);

        swapper.swap(k, true, 1 ether);
        assertEq(address(hungry).balance, 0, "bounded push ran out of gas");
        assertEq(h.owed(address(hungry)), 0.295 ether);

        // redeemClaims retries with the same bound and cannot deliver it either.
        h.redeemClaims();
        assertEq(address(hungry).balance, 0);
        assertEq(h.owed(address(hungry)), 0.295 ether);

        vm.prank(stranger);
        vm.expectEmit(true, true, false, true, address(h));
        emit LaunchHook.Withdrawn(address(hungry), address(hungry), 0.295 ether);
        h.withdrawFor(address(hungry));
        assertEq(address(hungry).balance, 0.295 ether, "delivered with full gas");
        assertEq(h.owed(address(hungry)), 0);
        assertEq(address(h).balance, 0);
        assertEq(stranger.balance, 0, "the caller gets nothing");
    }

    function test_withdrawFor_rejectingRecipient_revertsAndKeepsCredit() public {
        vault.setAccepting(false);
        swapper.swap(key, true, 1 ether);
        assertEq(hook.owed(address(vault)), 0.295 ether);

        vm.prank(stranger);
        vm.expectRevert(LaunchHook.WithdrawFailed.selector);
        hook.withdrawFor(address(vault));
        assertEq(hook.owed(address(vault)), 0.295 ether, "credit kept");
        assertEq(address(hook).balance, 0.295 ether);

        vault.setAccepting(true);
        vm.prank(stranger);
        hook.withdrawFor(address(vault));
        assertEq(address(vault).balance, 0.295 ether);
        assertEq(hook.owed(address(vault)), 0);
        assertEq(address(hook).balance, 0);
    }

    function test_withdrawFor_nothingOwed_reverts() public {
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        hook.withdrawFor(address(vault));
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        hook.withdrawFor(stranger);
    }

    function test_withdrawFor_cannotRedirectCredit() public {
        vault.setAccepting(false);
        swapper.swap(key, true, 1 ether);
        vm.startPrank(stranger);
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        hook.withdrawFor(stranger);
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        hook.withdraw(stranger);
        vm.stopPrank();
        assertEq(hook.owed(address(vault)), 0.295 ether);
        assertEq(stranger.balance, 0);
    }

    function test_withdrawFor_afterOwnPull_isEmpty() public {
        vault.setAccepting(false);
        swapper.swap(key, true, 1 ether);
        vault.setAccepting(true);
        vault.pull(IPullable(address(hook)), address(vault));
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        hook.withdrawFor(address(vault));
    }
}

/// @notice `withdrawFor` on a PoolManager with no ETH: it redeems the hook's claims on demand first.
contract LaunchHookWithdrawForFreshManagerTest is LaunchHookBase {
    function _fundManager() internal pure override returns (bool) {
        return false;
    }

    function test_withdrawFor_redeemsClaimsOnDemand() public {
        swapper.swap(key, true, 1 ether);
        assertEq(hook.pendingClaims(), 0.3 ether);
        assertEq(address(hook).balance, 0);

        vm.prank(makeAddr("stranger"));
        hook.withdrawFor(address(vault));
        assertEq(address(vault).balance, 0.295 ether);
        assertEq(hook.owed(address(vault)), 0);
        assertEq(hook.pendingClaims(), 0, "claims redeemed");
        assertEq(address(hook).balance, 0.005 ether, "dev's share waits in the hook");

        hook.withdrawFor(dev);
        assertEq(dev.balance, 0.005 ether);
        assertEq(address(hook).balance, 0);
    }
}
