// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {LaunchHook} from "src/LaunchHook.sol";
import {HookScenario} from "./support/HookScenario.sol";
import {ToggleVault, IPullable} from "./mocks/Recipients.sol";

contract ReenteringRecipient {
    LaunchHook public hook;
    bool public rejecting;
    bool public armed;
    bool public nestedSucceeded;
    bytes4 public nestedError;
    bool public flushInstead;

    function configure(LaunchHook hook_, bool rejecting_, bool armed_, bool flush_) external {
        hook = hook_;
        rejecting = rejecting_;
        armed = armed_;
        flushInstead = flush_;
    }

    function pull(address to) external {
        hook.withdraw(to);
    }

    receive() external payable {
        require(!rejecting, "recipient rejects ETH");
        if (!armed) return;
        armed = false;
        if (flushInstead) {
            try hook.redeemClaims() {
                nestedSucceeded = true;
            } catch (bytes memory data) {
                nestedError = bytes4(data);
            }
        } else {
            try hook.withdraw(address(this)) {
                nestedSucceeded = true;
            } catch (bytes memory data) {
                nestedError = bytes4(data);
            }
        }
    }
}

contract ReturnDataRecipient {
    bool public rejecting;

    constructor(bool rejecting_) {
        rejecting = rejecting_;
    }

    function pull(LaunchHook hook, address to) external {
        hook.withdraw(to);
    }

    receive() external payable {
        if (rejecting) {
            assembly { revert(0, 0x10000) }
        }
        assembly { return(0, 0x10000) }
    }
}

contract LaunchHookPayoutTest is HookScenario {
    ToggleVault internal vault;
    ToggleVault internal dev;

    function setUp() public {
        vault = new ToggleVault();
        dev = new ToggleVault();
        vm.warp(1700000000);
        IPoolManager manager_ = IPoolManager(address(new PoolManager(address(this))));
        vm.deal(address(manager_), 1000 ether);
        _setupScenario(manager_, address(vault), address(dev), address(this));
    }

    function test_bothRejectingRecipientsAccumulateAndIndependentlyWithdraw() public {
        vault.setAccepting(false);
        dev.setAccepting(false);
        trader.swap(pool, _params(true, -1 ether));
        vm.warp(start + 1800);
        trader.swap(pool, _params(true, -2 ether));
        assertEq(launchHook.owed(address(dev)), 0.015 ether);
        assertEq(launchHook.owed(address(vault)), 0.605 ether);
        assertEq(address(launchHook).balance, 0.62 ether);
        address devSink = makeAddr("payout dev sink");
        dev.pull(IPullable(address(launchHook)), devSink);
        assertEq(devSink.balance, 0.015 ether);
        assertEq(launchHook.owed(address(vault)), 0.605 ether);
        assertEq(address(launchHook).balance, 0.605 ether);
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        dev.pull(IPullable(address(launchHook)), devSink);
        vm.expectRevert(LaunchHook.ZeroAddress.selector);
        vault.pull(IPullable(address(launchHook)), address(0));
        assertEq(launchHook.owed(address(vault)), 0.605 ether);
        vault.setAccepting(true);
        launchHook.redeemClaims();
        assertEq(address(vault).balance, 0.605 ether);
        assertEq(address(launchHook).balance, 0);
        _assertSettled();
    }

    function test_withdrawReentrancyCannotSpendTheSameCreditTwice() public {
        ReenteringRecipient receiver = new ReenteringRecipient();
        _setupScenario(pm, address(receiver), address(dev), address(this));
        receiver.configure(launchHook, true, false, false);
        trader.swap(pool, _params(true, -1 ether));
        assertEq(launchHook.owed(address(receiver)), 0.295 ether);
        receiver.configure(launchHook, false, true, false);
        receiver.pull(address(receiver));
        assertFalse(receiver.nestedSucceeded());
        assertEq(receiver.nestedError(), LaunchHook.NothingOwed.selector);
        assertEq(address(receiver).balance, 0.295 ether);
        assertEq(launchHook.owed(address(receiver)), 0);
        assertEq(address(launchHook).balance, 0);
    }

    function test_payoutReentrancyCanOnlyFlushPreviouslyEarnedCredit() public {
        ReenteringRecipient receiver = new ReenteringRecipient();
        _setupScenario(pm, address(receiver), address(dev), address(this));
        receiver.configure(launchHook, true, false, false);
        trader.swap(pool, _params(true, -1 ether));
        assertEq(launchHook.owed(address(receiver)), 0.295 ether);
        receiver.configure(launchHook, false, true, true);
        trader.swap(pool, _params(true, -1 ether));
        assertTrue(receiver.nestedSucceeded(), "exercise successful nested flush");
        assertEq(address(receiver).balance, 0.59 ether, "only two earned research shares");
        assertEq(address(dev).balance, 0.01 ether);
        assertEq(launchHook.owed(address(receiver)), 0);
        assertEq(address(launchHook).balance, 0);
        _assertSettled();
    }

    function test_returnDataBombCannotBlockSwapOrLoseCredit() public {
        ReturnDataRecipient rejecting = new ReturnDataRecipient(true);
        ReturnDataRecipient accepting = new ReturnDataRecipient(false);
        _setupScenario(pm, address(rejecting), address(accepting), address(this));
        BalanceDelta delta = trader.swap(pool, _params(true, -1 ether));
        assertGt(delta.amount1(), 0);
        assertEq(address(accepting).balance, 0.005 ether);
        assertEq(launchHook.owed(address(rejecting)), 0.295 ether);
        assertEq(address(launchHook).balance, 0.295 ether);
        address sink = makeAddr("return data sink");
        rejecting.pull(launchHook, sink);
        assertEq(sink.balance, 0.295 ether);
        assertEq(address(launchHook).balance, 0);
        _assertSettled();
    }

    function test_failedClaimBackedPullRestoresClaimsAndBothCredits() public {
        // Here a fresh manager has no native ETH until the first buyer settles.
        _setupScenario(
            IPoolManager(address(new PoolManager(address(this)))), address(vault), address(dev), address(this)
        );
        vault.setAccepting(false);
        dev.setAccepting(false);
        trader.swap(pool, _params(true, -1 ether));
        uint256 claims = launchHook.pendingClaims();
        assertEq(claims, 0.3 ether);
        vm.expectRevert(LaunchHook.WithdrawFailed.selector);
        vault.pull(IPullable(address(launchHook)), address(vault));
        assertEq(launchHook.pendingClaims(), claims, "redeem and burn rolled back with failed send");
        assertEq(launchHook.owed(address(vault)), 0.295 ether);
        assertEq(launchHook.owed(address(dev)), 0.005 ether);
        assertEq(address(launchHook).balance, 0);
        assertEq(address(pm).balance, 1 ether);
        address sink = makeAddr("claim sink");
        vault.pull(IPullable(address(launchHook)), sink);
        assertEq(sink.balance, 0.295 ether);
        assertEq(launchHook.pendingClaims(), 0);
        assertEq(address(launchHook).balance, 0.005 ether);
        dev.setAccepting(true);
        launchHook.redeemClaims();
        assertEq(address(dev).balance, 0.005 ether);
        assertEq(address(launchHook).balance, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitFeeConservesAndHasBoundedRounding(uint128 a, uint128 b, uint16 rateSeed) public view {
        uint256 rate = bound(rateSeed, 50, 3000);
        (uint256 feeA, uint256 devA, uint256 vaultA) = launchHook.splitFee(a, rate);
        (uint256 feeB, uint256 devB, uint256 vaultB) = launchHook.splitFee(b, rate);
        (uint256 feeBoth, uint256 devBoth, uint256 vaultBoth) = launchHook.splitFee(uint256(a) + b, rate);
        assertEq(devA + vaultA, feeA);
        assertEq(devB + vaultB, feeB);
        assertEq(devBoth + vaultBoth, feeBoth);
        assertLe(feeA, a);
        assertLe(feeB, b);
        assertGe(feeBoth, feeA + feeB);
        assertLe(feeBoth, feeA + feeB + 1, "per-call rounding loses at most one wei");
        assertGe(devBoth, devA + devB);
        assertLe(devBoth, devA + devB + 1);
        (, uint256 devAtCap,) = launchHook.splitFee(a, 3000);
        assertEq(devA, devAtCap, "dev fraction is independent of launch premium");
    }

    function test_splitFeeZeroOneAndDevRoundingBoundaries() public view {
        (uint256 zeroFee, uint256 zeroDev, uint256 zeroVault) = launchHook.splitFee(0, 3000);
        assertEq(zeroFee + zeroDev + zeroVault, 0);
        (uint256 oneFee, uint256 oneDev, uint256 oneVault) = launchHook.splitFee(1, 3000);
        assertEq(oneFee + oneDev + oneVault, 0);
        (uint256 fee199, uint256 dev199, uint256 vault199) = launchHook.splitFee(199, 200);
        assertEq(fee199, 3);
        assertEq(dev199, 0);
        assertEq(vault199, 3);
        (uint256 fee200, uint256 dev200, uint256 vault200) = launchHook.splitFee(200, 200);
        assertEq(fee200, 4);
        assertEq(dev200, 1);
        assertEq(vault200, 3);
    }
}
