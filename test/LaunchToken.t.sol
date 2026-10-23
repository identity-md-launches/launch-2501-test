// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer = makeAddr("factory");

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "TEST");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
    }

    function test_supplyMintedOnceToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(deployer), 1e27);
    }

    function test_transferMovesExactly() public {
        address to = makeAddr("to");
        vm.prank(deployer);
        assertTrue(token.transfer(to, 123 ether));
        assertEq(token.balanceOf(to), 123 ether);
        assertEq(token.balanceOf(deployer), 1e27 - 123 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromNeedsAllowance() public {
        address spender = makeAddr("spender");
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(deployer, spender, 1);
        vm.prank(deployer);
        token.approve(spender, 5);
        vm.prank(spender);
        token.transferFrom(deployer, spender, 5);
        assertEq(token.balanceOf(spender), 5);
    }

    function test_noMintPauseOrOwner() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "pause()",
            "owner()",
            "transferOwnership(address)",
            "burnFrom(address,uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], deployer, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 1e27);
    }
}
