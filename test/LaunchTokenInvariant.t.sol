// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract FixedSupplyHandler is Test {
    LaunchToken public immutable token;
    address[4] public actors;
    address private immutable outsider;

    constructor(LaunchToken token_) {
        token = token_;
        actors = [makeAddr("token alice"), makeAddr("token bob"), makeAddr("token carol"), makeAddr("token dave")];
        outsider = makeAddr("token outsider");
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 amount = bound(amountSeed, 0, fromBefore);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(from), from == to ? fromBefore : fromBefore - amount);
        assertEq(token.balanceOf(to), from == to ? toBefore : toBefore + amount);
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amountSeed, bool unlimited) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 amount = unlimited ? type(uint256).max : bound(amountSeed, 0, token.totalSupply());
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    function spend(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        uint256 allowance = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        uint256 amount = bound(amountSeed, 0, allowance < balance ? allowance : balance);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        assertEq(token.balanceOf(owner), owner == to ? balance : balance - amount);
        assertEq(token.balanceOf(to), owner == to ? toBefore : toBefore + amount);
        assertEq(token.allowance(owner, spender), allowance == type(uint256).max ? allowance : allowance - amount);
    }

    function unauthorizedSpend(uint8 ownerSeed) external {
        address owner = actors[ownerSeed % 4];
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, outsider, 0, 1));
        token.transferFrom(owner, outsider, 1);
        assertEq(token.balanceOf(outsider), 0);
    }

    function overspend(uint8 ownerSeed) external {
        address owner = actors[ownerSeed % 4];
        uint256 balance = token.balanceOf(owner);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, balance + 1)
        );
        token.transfer(outsider, balance + 1);
        assertEq(token.balanceOf(owner), balance);
    }

    function attemptSupplyChange(uint8 actorSeed, uint256 amount) external {
        vm.prank(actors[actorSeed % 4]);
        (bool minted,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", outsider, amount));
        assertFalse(minted, "no post-deployment mint entry point");
        vm.prank(actors[actorSeed % 4]);
        (bool burned,) = address(token).call(abi.encodeWithSignature("burn(uint256)", amount));
        assertFalse(burned, "no supply-changing burn entry point");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    LaunchToken internal token;
    FixedSupplyHandler internal handler;

    function setUp() public {
        token = new LaunchToken();
        handler = new FixedSupplyHandler(token);
        token.transfer(handler.actors(0), token.totalSupply());
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.spend.selector;
        selectors[3] = handler.unauthorizedSpend.selector;
        selectors[4] = handler.overspend.selector;
        selectors[5] = handler.attemptSupplyChange.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_supplyRemainsFixedAndEqualsEveryHolderBalance() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), sum);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }
}
