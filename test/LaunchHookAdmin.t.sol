// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchHookBase} from "./LaunchHookBase.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LaunchHook} from "../src/LaunchHook.sol";

/// @notice The owner can only lower fees; nobody else can touch them; ownership can move or be renounced.
contract LaunchHookAdminTest is LaunchHookBase {
    address internal stranger = makeAddr("stranger");

    function test_ownerCanLowerBaseFee_andSwapsUseIt() public {
        vm.prank(owner);
        hook.setBaseFee(100);
        assertEq(hook.baseFeeBps(), 100);
        assertEq(hook.sellFeeBps(), 100);

        _primePoolWithEth(10 ether);
        _giveTokens(address(swapper), 1_000_000 ether);
        Snapshot memory before = _snap();
        swapper.swap(key, false, 1 ether);
        Snapshot memory after_ = _snap();
        uint256 gross = before.managerEth - after_.managerEth;
        assertEq(after_.swapperEth - before.swapperEth, gross - gross * 100 / BPS, "sell pays 1%");
        assertEq(after_.devEth - before.devEth, gross * 50 / BPS, "dev share unchanged");
        assertEq(after_.vaultEth - before.vaultEth, gross * 100 / BPS - gross * 50 / BPS, "vault gets 0.5%");
    }

    function test_ownerCannotRaiseBaseFee() public {
        vm.startPrank(owner);
        vm.expectRevert(LaunchHook.FeeCanOnlyDecrease.selector);
        hook.setBaseFee(201);
        hook.setBaseFee(150);
        vm.expectRevert(LaunchHook.FeeCanOnlyDecrease.selector);
        hook.setBaseFee(151);
        vm.expectRevert(LaunchHook.FeeCanOnlyDecrease.selector);
        hook.setBaseFee(200);
        vm.stopPrank();
        assertEq(hook.baseFeeBps(), 150);
    }

    function test_baseFeeCannotGoBelowDevShare() public {
        vm.startPrank(owner);
        vm.expectRevert(LaunchHook.FeeBelowDevShare.selector);
        hook.setBaseFee(49);
        vm.expectRevert(LaunchHook.FeeBelowDevShare.selector);
        hook.setBaseFee(0);
        hook.setBaseFee(50);
        vm.stopPrank();
        assertEq(hook.baseFeeBps(), 50);

        // At the floor the whole fee is the dev share and the vault gets nothing.
        vm.warp(launchedAt + 3600);
        Snapshot memory before = _snap();
        swapper.swap(key, true, 1 ether);
        Snapshot memory after_ = _snap();
        assertEq(after_.devEth - before.devEth, 0.005 ether);
        assertEq(after_.vaultEth, before.vaultEth);
    }

    function test_ownerCanLowerLaunchFee_andDecayStartsThere() public {
        vm.prank(owner);
        hook.setLaunchFee(1000);
        assertEq(hook.launchFeeBps(), 1000);
        assertEq(hook.buyFeeBps(), 1000, "t=0");
        vm.warp(launchedAt + 1800);
        assertEq(hook.buyFeeBps(), 600, "t=1800 halfway between 10% and 2%");

        Snapshot memory before = _snap();
        swapper.swap(key, true, 1 ether);
        Snapshot memory after_ = _snap();
        assertEq(after_.managerEth - before.managerEth, 0.94 ether);
        assertEq(after_.devEth - before.devEth, 0.005 ether);
        assertEq(after_.vaultEth - before.vaultEth, 0.055 ether);
    }

    function test_ownerCannotRaiseLaunchFee() public {
        vm.startPrank(owner);
        vm.expectRevert(LaunchHook.FeeCanOnlyDecrease.selector);
        hook.setLaunchFee(3001);
        hook.setLaunchFee(2000);
        vm.expectRevert(LaunchHook.FeeCanOnlyDecrease.selector);
        hook.setLaunchFee(2001);
        vm.expectRevert(LaunchHook.FeeCanOnlyDecrease.selector);
        hook.setLaunchFee(3000);
        vm.stopPrank();
    }

    function test_launchFeeCannotGoBelowBaseFee() public {
        vm.startPrank(owner);
        vm.expectRevert(LaunchHook.LaunchFeeBelowBaseFee.selector);
        hook.setLaunchFee(199);
        hook.setLaunchFee(200); // equal is fine: no launch premium at all
        vm.stopPrank();
        assertEq(hook.buyFeeBps(), 200);
        vm.warp(launchedAt + 1000);
        assertEq(hook.buyFeeBps(), 200);
    }

    function test_loweringBaseBelowLaunchKeepsDecayValid() public {
        vm.startPrank(owner);
        hook.setLaunchFee(200);
        hook.setBaseFee(100);
        vm.stopPrank();
        assertEq(hook.buyFeeBps(), 200, "launch cap stays where it was lowered to");
        vm.warp(launchedAt + 1800);
        assertEq(hook.buyFeeBps(), 150);
        vm.warp(launchedAt + 3600);
        assertEq(hook.buyFeeBps(), 100);
    }

    function test_nonOwnerCannotSetFees() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        hook.setBaseFee(100);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        hook.setLaunchFee(100);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        hook.transferOwnership(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        hook.renounceOwnership();
        vm.stopPrank();
        assertEq(hook.baseFeeBps(), 200);
        assertEq(hook.launchFeeBps(), 3000);
        assertEq(hook.owner(), owner);
    }

    function test_recipientsAndFactoryAreNotOwners() public {
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, dev));
        hook.setBaseFee(100);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, factory));
        hook.setBaseFee(100);
    }

    function test_transferOwnership() public {
        address next = makeAddr("nextOwner");
        vm.prank(owner);
        hook.transferOwnership(next);
        assertEq(hook.owner(), next);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        hook.setBaseFee(100);
        vm.prank(next);
        hook.setBaseFee(100);
        assertEq(hook.baseFeeBps(), 100);
    }

    function test_renounceOwnership_freezesFees() public {
        vm.prank(owner);
        hook.renounceOwnership();
        assertEq(hook.owner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        hook.setBaseFee(100);
        // Swaps keep working with the frozen schedule.
        swapper.swap(key, true, 1 ether);
        assertEq(dev.balance, 0.005 ether);
    }

    function test_ownerHasNoAccessToRecipientCredit() public {
        vault.setAccepting(false);
        swapper.swap(key, true, 1 ether);
        assertEq(hook.owed(address(vault)), 0.295 ether);
        vm.prank(owner);
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        hook.withdraw(owner);
        assertEq(address(hook).balance, 0.295 ether);
        assertEq(hook.owed(address(vault)), 0.295 ether);
    }

    function test_noLiquidityOrMintOrPauseEntryPoints() public {
        string[8] memory signatures = [
            "pause()",
            "unpause()",
            "mint(address,uint256)",
            "withdrawETH(uint256)",
            "sweep(address)",
            "removeLiquidity(uint256)",
            "setDevShare(uint16)",
            "setRecipients(address,address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(owner);
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], owner, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
    }
}
