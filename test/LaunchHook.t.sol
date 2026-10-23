// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchHookBase} from "./LaunchHookBase.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LaunchHook} from "../src/LaunchHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ToggleVault, GasHungryVault, IPullable} from "./mocks/Recipients.sol";

/// @notice Fee behaviour on a funded PoolManager (one that already holds ETH, as mainnet's does).
contract LaunchHookTest is LaunchHookBase {
    // ------------------------------------------------------------------------------------------------
    // Buys
    // ------------------------------------------------------------------------------------------------

    function test_buyExactInput_t0_pays30Percent() public {
        Snapshot memory before = _snap();
        uint256 ethIn = 1 ether;

        BalanceDelta delta = swapper.swap(key, true, ethIn);
        Snapshot memory after_ = _snap();

        uint256 fee = ethIn * 3000 / BPS; // 0.3 ETH
        uint256 devAmt = ethIn * 50 / BPS; // 0.005 ETH
        assertEq(before.swapperEth - after_.swapperEth, ethIn, "swapper pays exactly the input");
        assertEq(delta.amount0(), -int256(ethIn), "swapper delta is the full input");
        assertEq(after_.managerEth - before.managerEth, ethIn - fee, "pool keeps input minus fee");
        assertEq(after_.devEth - before.devEth, devAmt, "dev gets 0.5%");
        assertEq(after_.vaultEth - before.vaultEth, fee - devAmt, "vault gets the rest (29.5%)");
        assertEq(after_.hookEth, 0, "hook keeps nothing");
        assertGt(after_.swapperToken - before.swapperToken, 0, "swapper got tokens");
        assertEq(hook.pendingClaims(), 0, "no claims when the manager holds ETH");
    }

    function test_buyExactOutput_t0_pays30PercentOfGross() public {
        Snapshot memory before = _snap();
        uint256 tokensOut = 1 ether; // one token is about one ETH at the 1:1 opening price

        swapper.swapExact(key, true, int256(tokensOut));
        Snapshot memory after_ = _snap();

        uint256 poolEth = after_.managerEth - before.managerEth;
        uint256 paid = before.swapperEth - after_.swapperEth;
        uint256 fee = paid - poolEth;
        assertEq(after_.swapperToken - before.swapperToken, tokensOut, "exact token output");
        assertEq(fee, poolEth * 3000 / (BPS - 3000), "fee is 30% of the gross ETH paid");
        assertEq(after_.devEth - before.devEth, paid * 50 / BPS, "dev gets 0.5% of gross");
        assertEq(after_.vaultEth - before.vaultEth, fee - paid * 50 / BPS, "vault gets the rest");
        // Effective rate on what the swapper paid is the launch rate (within integer rounding).
        assertApproxEqAbs(fee * BPS / paid, 3000, 1, "effective rate");
    }

    // ------------------------------------------------------------------------------------------------
    // Sells
    // ------------------------------------------------------------------------------------------------

    function test_sellExactInput_pays2Percent() public {
        _primePoolWithEth(10 ether);
        _giveTokens(address(swapper), 1_000_000 ether);
        Snapshot memory before = _snap();
        uint256 tokensIn = 1 ether; // about 1 ETH of the ~7 ETH the pool holds

        swapper.swap(key, false, tokensIn);
        Snapshot memory after_ = _snap();

        uint256 poolEthOut = before.managerEth - after_.managerEth; // gross
        uint256 fee = poolEthOut * 200 / BPS;
        uint256 devAmt = poolEthOut * 50 / BPS;
        assertGt(poolEthOut, 0, "pool paid ETH");
        assertEq(before.swapperToken - after_.swapperToken, tokensIn, "exact token input");
        assertEq(after_.swapperEth - before.swapperEth, poolEthOut - fee, "swapper gets gross minus 2%");
        assertEq(after_.devEth - before.devEth, devAmt, "dev gets 0.5%");
        assertEq(after_.vaultEth - before.vaultEth, fee - devAmt, "vault gets 1.5%");
    }

    function test_sellExactOutput_pays2PercentOfGross() public {
        _primePoolWithEth(10 ether);
        _giveTokens(address(swapper), 1_000_000 ether);
        Snapshot memory before = _snap();
        uint256 ethOut = 0.1 ether;

        swapper.swapExact(key, false, int256(ethOut));
        Snapshot memory after_ = _snap();

        uint256 gross = before.managerEth - after_.managerEth;
        uint256 fee = ethOut * 200 / (BPS - 200);
        assertEq(after_.swapperEth - before.swapperEth, ethOut, "swapper gets exactly the requested ETH");
        assertEq(gross, ethOut + fee, "pool pays gross = net + fee");
        assertEq(after_.devEth - before.devEth, gross * 50 / BPS, "dev gets 0.5% of gross");
        assertEq(after_.vaultEth - before.vaultEth, fee - gross * 50 / BPS, "vault gets the rest");
        assertGt(before.swapperToken - after_.swapperToken, 0, "tokens were sold");
    }

    function test_sellInsideLaunchWindow_stillPays2Percent() public {
        _primePoolWithEth(10 ether);
        _giveTokens(address(swapper), 1_000_000 ether);
        assertEq(hook.buyFeeBps(), 3000);
        assertEq(hook.sellFeeBps(), 200);
        Snapshot memory before = _snap();
        swapper.swap(key, false, 1 ether);
        Snapshot memory after_ = _snap();
        uint256 gross = before.managerEth - after_.managerEth;
        assertGt(gross, 0);
        assertEq(after_.swapperEth - before.swapperEth, gross - gross * 200 / BPS);
    }

    // ------------------------------------------------------------------------------------------------
    // Fee schedule over time
    // ------------------------------------------------------------------------------------------------

    function test_feeSchedule_views() public {
        assertEq(hook.launchedAt(), launchedAt);
        assertEq(hook.buyFeeBps(), 3000, "t=0");
        vm.warp(launchedAt + 900);
        assertEq(hook.buyFeeBps(), 2300, "t=900");
        vm.warp(launchedAt + 1800);
        assertEq(hook.buyFeeBps(), 1600, "t=1800");
        vm.warp(launchedAt + 3599);
        assertEq(hook.buyFeeBps(), 201, "t=3599 rounds to just above base");
        vm.warp(launchedAt + 3600);
        assertEq(hook.buyFeeBps(), 200, "t=3600");
        vm.warp(launchedAt + 1 days);
        assertEq(hook.buyFeeBps(), 200, "after the window");
        assertEq(hook.sellFeeBps(), 200, "sells always base");
    }

    function test_buyAt1800_pays16Percent() public {
        vm.warp(launchedAt + 1800);
        Snapshot memory before = _snap();
        swapper.swap(key, true, 1 ether);
        Snapshot memory after_ = _snap();
        assertEq(after_.managerEth - before.managerEth, 0.84 ether, "pool keeps 84%");
        assertEq(after_.devEth - before.devEth, 0.005 ether, "dev 0.5%");
        assertEq(after_.vaultEth - before.vaultEth, 0.155 ether, "vault 15.5%");
    }

    function test_buyAt3600_pays2Percent() public {
        vm.warp(launchedAt + 3600);
        Snapshot memory before = _snap();
        swapper.swap(key, true, 1 ether);
        Snapshot memory after_ = _snap();
        assertEq(after_.managerEth - before.managerEth, 0.98 ether, "pool keeps 98%");
        assertEq(after_.devEth - before.devEth, 0.005 ether, "dev 0.5%");
        assertEq(after_.vaultEth - before.vaultEth, 0.015 ether, "vault 1.5%");
    }

    function test_buyLongAfterWindow_pays2Percent() public {
        vm.warp(launchedAt + 30 days);
        Snapshot memory before = _snap();
        swapper.swapExact(key, true, int256(1 ether));
        Snapshot memory after_ = _snap();
        uint256 poolEth = after_.managerEth - before.managerEth;
        uint256 paid = before.swapperEth - after_.swapperEth;
        assertEq(paid - poolEth, poolEth * 200 / (BPS - 200), "2% of gross on exact output");
    }

    function testFuzz_buyExactInput_conservesEthAndSplitsCorrectly(uint256 ethIn, uint256 dt) public {
        ethIn = bound(ethIn, 1e9, 100 ether);
        dt = bound(dt, 0, 2 * 3600);
        vm.warp(launchedAt + dt);
        uint256 rate = hook.buyFeeBps();
        Snapshot memory before = _snap();

        swapper.swap(key, true, ethIn);
        Snapshot memory after_ = _snap();

        uint256 fee = ethIn * rate / BPS;
        uint256 devAmt = ethIn * 50 / BPS;
        assertEq(before.swapperEth - after_.swapperEth, ethIn);
        assertEq(after_.devEth - before.devEth, devAmt);
        assertEq(after_.vaultEth - before.vaultEth, fee - devAmt);
        assertEq(after_.managerEth - before.managerEth, ethIn - fee);
        // Conservation: what the swapper paid is exactly what the pool, dev and vault received.
        assertEq(
            (after_.managerEth - before.managerEth) + (after_.devEth - before.devEth)
                + (after_.vaultEth - before.vaultEth),
            ethIn
        );
    }

    function testFuzz_sellExactInput_conservesEthAndSplitsCorrectly(uint256 tokensIn) public {
        _primePoolWithEth(50 ether);
        tokensIn = bound(tokensIn, 1e9, 20 ether); // the pool holds ~35 ETH after the prime
        _giveTokens(address(swapper), tokensIn);
        Snapshot memory before = _snap();

        swapper.swap(key, false, tokensIn);
        Snapshot memory after_ = _snap();

        uint256 gross = before.managerEth - after_.managerEth;
        uint256 fee = gross * 200 / BPS;
        uint256 devAmt = gross * 50 / BPS;
        assertEq(after_.swapperEth - before.swapperEth, gross - fee);
        assertEq(after_.devEth - before.devEth, devAmt);
        assertEq(after_.vaultEth - before.vaultEth, fee - devAmt);
    }

    function testFuzz_buyFeeDecaysMonotonically(uint256 t1, uint256 t2) public view {
        t1 = bound(t1, 0, 4000);
        t2 = bound(t2, t1, 4000);
        uint256 f1 = hook.buyFeeBpsAt(launchedAt + t1);
        uint256 f2 = hook.buyFeeBpsAt(launchedAt + t2);
        assertGe(f1, f2);
        assertLe(f1, 3000);
        assertGe(f2, 200);
    }

    // ------------------------------------------------------------------------------------------------
    // Recipients that cannot receive ETH
    // ------------------------------------------------------------------------------------------------

    function test_rejectingVault_doesNotBlockSwap_andCanWithdraw() public {
        vault.setAccepting(false);
        Snapshot memory before = _snap();

        swapper.swap(key, true, 1 ether);
        Snapshot memory after_ = _snap();

        assertEq(after_.vaultEth, before.vaultEth, "vault refused the push");
        assertEq(after_.devEth - before.devEth, 0.005 ether, "dev still paid");
        assertEq(hook.owed(address(vault)), 0.295 ether, "vault credited");
        assertEq(after_.hookEth, 0.295 ether, "hook holds the credited ETH");

        // Still rejecting: the pull fails too, credit stays.
        vm.expectRevert(LaunchHook.WithdrawFailed.selector);
        vault.pull(IPullable(address(hook)), address(vault));
        assertEq(hook.owed(address(vault)), 0.295 ether);

        // Accepting again: pull succeeds.
        vault.setAccepting(true);
        vault.pull(IPullable(address(hook)), address(vault));
        assertEq(address(vault).balance, before.vaultEth + 0.295 ether);
        assertEq(hook.owed(address(vault)), 0);
        assertEq(address(hook).balance, 0);
    }

    function test_rejectingVault_canWithdrawToAnotherAddress() public {
        vault.setAccepting(false);
        swapper.swap(key, true, 1 ether);
        address sink = makeAddr("sink");
        vault.pull(IPullable(address(hook)), sink);
        assertEq(sink.balance, 0.295 ether);
    }

    function test_gasHungryVault_isCredited_andPullsWithFullGas() public {
        GasHungryVault hungry = new GasHungryVault();
        LaunchHook h = _deployHookAt(address(hungry), 0x2222);
        PoolKey memory k = key;
        k.hooks = IHooks(address(h));
        vm.prank(factory);
        manager.initialize(k, SQRT_PRICE_1_1);
        seeder.modifyLiquidity(k, -887_220, 0, SEED_LIQUIDITY / 5);

        swapper.swap(k, true, 1 ether);
        assertEq(address(hungry).balance, 0, "push ran out of gas");
        assertEq(h.owed(address(hungry)), 0.295 ether);
        hungry.pull(IPullable(address(h)), address(hungry));
        assertEq(address(hungry).balance, 0.295 ether);
    }

    function test_withdraw_nothingOwed_reverts() public {
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        hook.withdraw(address(this));
        vm.prank(dev);
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        hook.withdraw(dev);
    }

    function test_withdraw_toZero_reverts() public {
        vm.expectRevert(LaunchHook.ZeroAddress.selector);
        hook.withdraw(address(0));
    }

    function test_strangerCannotTakeRecipientCredit() public {
        vault.setAccepting(false);
        swapper.swap(key, true, 1 ether);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        hook.withdraw(stranger);
        assertEq(hook.owed(address(vault)), 0.295 ether);
    }

    function test_hookRefusesStrayEth() public {
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "only the PoolManager may send ETH to the hook");
    }

    // ------------------------------------------------------------------------------------------------
    // Pool binding and callbacks
    // ------------------------------------------------------------------------------------------------

    function test_secondInitialize_reverts() public {
        PoolKey memory other = key;
        other.fee = 3_000;
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
        assertEq(hook.launchedAt(), launchedAt, "first launch unchanged");
    }

    function test_initializeWithWrongToken_reverts() public {
        LaunchHook fresh = _deployHookAt(address(vault), 0x3333);
        MockERC20 other = new MockERC20("Other", "OTHER", 1e24);
        PoolKey memory k = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(other)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(fresh))
        });
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        assertEq(fresh.launchedAt(), 0);
    }

    function test_initializeWithoutEth_reverts() public {
        LaunchHook fresh = _deployHookAt(address(vault), 0x4444);
        MockERC20 other = new MockERC20("Other", "OTHER", 1e24);
        (address c0, address c1) =
            address(other) < address(token) ? (address(other), address(token)) : (address(token), address(other));
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(fresh))
        });
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        assertEq(fresh.launchedAt(), 0);
    }

    function test_initializeAcceptsAnyListedFeeAndSpacing() public {
        LaunchHook fresh = _deployHookAt(address(vault), 0x5555);
        PoolKey memory k = key;
        k.hooks = IHooks(address(fresh));
        k.fee = 3_000;
        k.tickSpacing = 10;
        vm.prank(factory);
        manager.initialize(k, SQRT_PRICE_1_1);
        assertEq(fresh.launchedAt(), block.timestamp);
    }

    function test_callbacksRefuseNonManager() public {
        SwapParams memory p = SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2);
        vm.expectRevert(LaunchHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(LaunchHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(LaunchHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(LaunchHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
        vm.expectRevert(LaunchHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
    }

    function test_permissionsMatchAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.afterInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertTrue(HookFlags.matches(address(hook), HookFlags.fromPermissions(p)));
        assertEq(HookFlags.fromPermissions(p), uint160(0x10CC));
    }

    function test_constructorRejectsZeroAddresses() public {
        uint160 flags = HookFlags.fromPermissions(hook.getHookPermissions());
        address at = address(uint160(0x6666 << 144) | flags);
        vm.expectRevert(LaunchHook.ZeroAddress.selector);
        deployCodeTo("LaunchHook.sol:LaunchHook", abi.encode(manager, address(0), owner, vault, dev), at);
        vm.expectRevert(LaunchHook.ZeroAddress.selector);
        deployCodeTo("LaunchHook.sol:LaunchHook", abi.encode(manager, token, owner, address(0), dev), at);
        vm.expectRevert(LaunchHook.ZeroAddress.selector);
        deployCodeTo("LaunchHook.sol:LaunchHook", abi.encode(manager, token, owner, vault, address(0)), at);
    }

    function test_constructorRejectsWrongFlags() public {
        address at = address(uint160(0x7777 << 144) | uint160(Hooks.BEFORE_SWAP_FLAG));
        vm.expectRevert();
        deployCodeTo("LaunchHook.sol:LaunchHook", abi.encode(manager, token, owner, vault, dev), at);
    }

    function test_immutablesAndDefaults() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
        assertEq(hook.researchVault(), address(vault));
        assertEq(hook.devWallet(), dev);
        assertEq(hook.owner(), owner);
        assertEq(hook.launchFeeBps(), 3000);
        assertEq(hook.baseFeeBps(), 200);
        assertEq(hook.DEV_SHARE_BPS(), 50);
        assertEq(hook.LAUNCH_WINDOW(), 3600);
    }

    /// @dev A second hook instance for pools that must not touch the fixture's.
    function _deployHookAt(address vault_, uint160 prefix) internal returns (LaunchHook) {
        uint160 flags = HookFlags.fromPermissions(hook.getHookPermissions());
        address at = address((prefix << 144) | flags);
        deployCodeTo("LaunchHook.sol:LaunchHook", abi.encode(manager, token, owner, vault_, dev), at);
        return LaunchHook(payable(at));
    }
}

/// @notice The same hook on a PoolManager that holds no ETH at all: the launch pool is seeded with tokens
/// only, so the first buy's fee cannot be taken as ETH before the buyer settles. The hook holds a claim.
contract LaunchHookFreshManagerTest is LaunchHookBase {
    function _fundManager() internal pure override returns (bool) {
        return false;
    }

    function test_firstBuyOnFreshManager_mintsClaim_thenRedeems() public {
        assertEq(address(manager).balance, 0, "fresh manager");
        Snapshot memory before = _snap();

        swapper.swap(key, true, 1 ether);
        Snapshot memory after_ = _snap();

        assertEq(before.swapperEth - after_.swapperEth, 1 ether, "swapper paid the full input");
        assertEq(after_.managerEth, 1 ether, "manager holds the buyer's ETH, claim included");
        assertEq(hook.pendingClaims(), 0.3 ether, "fee held as an ERC-6909 claim");
        assertEq(hook.owed(dev), 0.005 ether);
        assertEq(hook.owed(address(vault)), 0.295 ether);
        assertEq(after_.devEth, before.devEth, "nothing pushed yet");
        assertEq(after_.vaultEth, before.vaultEth, "nothing pushed yet");

        hook.redeemClaims();
        assertEq(hook.pendingClaims(), 0);
        assertEq(dev.balance - before.devEth, 0.005 ether);
        assertEq(address(vault).balance - before.vaultEth, 0.295 ether);
        assertEq(hook.owed(dev), 0);
        assertEq(hook.owed(address(vault)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(address(manager).balance, 0.7 ether, "pool keeps input minus fee");
    }

    function test_secondBuyOnFreshManager_paysDirectlyOnceEthIsIn() public {
        swapper.swap(key, true, 1 ether); // claim path
        Snapshot memory before = _snap();
        swapper.swap(key, true, 1 ether); // manager now holds 1 ETH >= fee
        Snapshot memory after_ = _snap();
        assertEq(after_.devEth - before.devEth, 0.005 ether, "second buy pays dev directly");
        assertEq(after_.vaultEth - before.vaultEth, 0.295 ether, "second buy pays vault directly");
        assertEq(hook.pendingClaims(), 0.3 ether, "first buy's claim still pending");
    }

    function test_withdrawRedeemsClaimsOnDemand() public {
        swapper.swap(key, true, 1 ether);
        assertEq(address(hook).balance, 0);
        vm.prank(dev);
        hook.withdraw(dev);
        assertEq(dev.balance, 0.005 ether);
        assertEq(hook.pendingClaims(), 0, "all claims redeemed on first pull");
        assertEq(address(hook).balance, 0.295 ether, "vault's share waits in the hook");
        vault.pull(IPullable(address(hook)), address(vault));
        assertEq(address(vault).balance, 0.295 ether);
        assertEq(address(hook).balance, 0);
    }

    function test_redeemClaims_withNothingPending_isNoop() public {
        hook.redeemClaims();
        assertEq(hook.pendingClaims(), 0);
    }

    function test_redeemClaims_keepsCreditForRejectingVault() public {
        vault.setAccepting(false);
        swapper.swap(key, true, 1 ether);
        hook.redeemClaims();
        assertEq(hook.owed(address(vault)), 0.295 ether, "still credited");
        assertEq(address(hook).balance, 0.295 ether, "ETH waits in the hook");
        assertEq(dev.balance, 0.005 ether, "dev paid");
        vault.setAccepting(true);
        hook.redeemClaims();
        assertEq(address(vault).balance, 0.295 ether, "flushed once accepting");
        assertEq(hook.owed(address(vault)), 0);
    }
}
