// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HookScenario} from "./support/HookScenario.sol";
import {LaunchHook} from "src/LaunchHook.sol";
import {ToggleVault, IPullable} from "./mocks/Recipients.sol";

/// @notice Pinned mainnet integration. No mock/etch/deal replaces the live PoolManager or recipients.
contract LaunchHookForkTest is HookScenario {
    using StateLibrary for IPoolManager;

    // Official deployment: https://developers.uniswap.org/docs/protocols/v4/deployments
    address internal constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint256 internal constant FORK_BLOCK = 26255649;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        assertEq(block.chainid, 1, "wrong fork chain");
        assertEq(block.number, FORK_BLOCK, "wrong pinned block");
        assertGt(MAINNET_MANAGER.code.length, 0, "live PoolManager has no code");
        assertGt(RESEARCH_VAULT.code.length, 0, "the specified research vault must be a contract");
        _setupScenario(IPoolManager(MAINNET_MANAGER), RESEARCH_VAULT, DEV_WALLET, DEV_WALLET);
    }

    function _fourDirections(uint256 elapsed, uint256 buyRate) internal {
        // A real buy funds this pool's ETH side; the seed itself supplied TEST only.
        trader.swap(pool, _params(true, -50 ether));
        vm.warp(start + elapsed);
        _assertPaidSwap(true, -1 ether, buyRate);
        _assertPaidSwap(true, 1 ether, buyRate);
        _assertPaidSwap(false, -1 ether, 200);
        _assertPaidSwap(false, 0.1 ether, 200);
        assertEq(block.number, FORK_BLOCK, "timestamp changes must not move the pinned block");
    }

    function testFork_allFourSwapTypes_atLaunch() public {
        _fourDirections(0, 3000);
    }

    function testFork_allFourSwapTypes_at1800Seconds() public {
        _fourDirections(1800, 1600);
    }

    function testFork_allFourSwapTypes_at3600Seconds() public {
        _fourDirections(3600, 200);
    }

    function testFork_allFourSwapTypes_afterLaunch() public {
        _fourDirections(86400, 200);
    }

    function testFork_rejectingRecipientDoesNotBlockAnySwapTypeAndCanPull() public {
        // Separate hook and token; only this failure scenario substitutes a recipient.
        ToggleVault rejecting = new ToggleVault();
        rejecting.setAccepting(false);
        _setupScenario(pm, address(rejecting), DEV_WALLET, DEV_WALLET);
        trader.swap(pool, _params(true, -10 ether));
        trader.swap(pool, _params(true, 1 ether));
        trader.swap(pool, _params(false, -1 ether));
        trader.swap(pool, _params(false, 0.1 ether));
        uint256 credit = launchHook.owed(address(rejecting));
        assertGt(credit, 0);
        assertEq(address(rejecting).balance, 0);
        assertEq(address(launchHook).balance, credit);
        vm.expectRevert(LaunchHook.WithdrawFailed.selector);
        rejecting.pull(IPullable(address(launchHook)), address(rejecting));
        assertEq(launchHook.owed(address(rejecting)), credit, "failed withdrawal preserves debt");
        rejecting.setAccepting(true);
        rejecting.pull(IPullable(address(launchHook)), address(rejecting));
        assertEq(address(rejecting).balance, credit);
        assertEq(launchHook.owed(address(rejecting)), 0);
        assertEq(address(launchHook).balance, 0);
        _assertSettled();
    }

    function testFork_adminCannotRaiseFeesAndStrangersCannotAdminister() public {
        address stranger = makeAddr("fork stranger");
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        launchHook.setBaseFee(100);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        launchHook.setLaunchFee(1000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        launchHook.transferOwnership(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        launchHook.renounceOwnership();
        vm.stopPrank();
        vm.startPrank(DEV_WALLET);
        vm.expectRevert(LaunchHook.FeeCanOnlyDecrease.selector);
        launchHook.setLaunchFee(3001);
        vm.expectRevert(LaunchHook.FeeCanOnlyDecrease.selector);
        launchHook.setBaseFee(201);
        launchHook.setBaseFee(50);
        launchHook.setLaunchFee(50);
        vm.expectRevert(LaunchHook.FeeBelowDevShare.selector);
        launchHook.setBaseFee(49);
        vm.expectRevert(LaunchHook.FeeCanOnlyDecrease.selector);
        launchHook.setBaseFee(51);
        vm.expectRevert(LaunchHook.FeeCanOnlyDecrease.selector);
        launchHook.setLaunchFee(51);
        vm.stopPrank();
        _assertPaidSwap(true, -1 ether, 50);
    }

    function testFork_factoryCanCollectAndRemoveLiquidityAfterRenunciation() public {
        trader.swap(pool, _params(true, -10 ether));
        vm.prank(DEV_WALLET);
        launchHook.renounceOwnership();
        uint256 vaultBefore = RESEARCH_VAULT.balance;
        uint256 devBefore = DEV_WALLET.balance;
        BalanceDelta fees = lp.modifyLiquidity(pool, LOWER, 0, 0);
        assertGt(fees.amount0(), 0, "LP has earned ETH fees");
        assertGe(fees.amount1(), 0);
        BalanceDelta removed = lp.modifyLiquidity(pool, LOWER, 0, -LIQUIDITY);
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertEq(RESEARCH_VAULT.balance, vaultBefore, "LP collect/removal has no hook tax");
        assertEq(DEV_WALLET.balance, devBefore);
        _assertSettled();
    }

    function _price() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = pm.getSlot0(pool.toId());
    }

    /// @dev Partial fills on the live manager. With ETH specified the fee was sized for the requested amount,
    /// so the hook must refuse the fill; with ETH unspecified the fee must follow the executed ETH only.
    function _partialFillsAt(uint256 elapsed, uint256 buyRate) internal {
        trader.swap(pool, _params(true, -50 ether));
        vm.warp(start + elapsed);
        // About 0.5 ETH of this pool's depth lies between the current price and a 1e-9 relative move.
        uint160 price = _price();
        (uint256 assumed, uint256 executed) = _expectPartialFill(true, -10 ether, price - price / 1e9);
        assertEq(assumed, 10 ether - uint256(10 ether) * buyRate / 10000, "fee was sized for the full input");
        assertGt(executed, 0);
        (assumed, executed) = _expectPartialFill(false, 10 ether, price + price / 1e9);
        assertEq(assumed, 10 ether + uint256(10 ether) * 200 / (10000 - 200), "gross for the full output");
        assertGt(executed, 0);
        // Asking for more ETH than the pool holds is the same refusal, at the extreme price limit.
        uint256 poolEthBefore = address(pm).balance;
        (assumed, executed) = _expectPartialFill(false, 100 ether, TickMath.MAX_SQRT_PRICE - 1);
        assertLt(executed, 50 ether, "only this pool's ETH could be paid out");
        assertEq(address(pm).balance, poolEthBefore);

        _assertPaidLimitedSwap(true, 10 ether, price - price / 1e9, buyRate, false);
        price = _price();
        _assertPaidLimitedSwap(false, -10 ether, price + price / 1e9, 200, false);
        // A limit the swap never reaches is an ordinary, fully charged fill.
        price = _price();
        _assertPaidLimitedSwap(true, -0.01 ether, price / 2, buyRate, true);
        assertEq(block.number, FORK_BLOCK);
    }

    function testFork_partialFills_atLaunch() public {
        _partialFillsAt(0, 3000);
    }

    function testFork_partialFills_afterWindow() public {
        _partialFillsAt(3600, 200);
    }

    function testFork_withdrawForDeliversOnlyToTheRecipient() public {
        ToggleVault rejecting = new ToggleVault();
        rejecting.setAccepting(false);
        _setupScenario(pm, address(rejecting), DEV_WALLET, DEV_WALLET);
        trader.swap(pool, _params(true, -10 ether));
        uint256 credit = launchHook.owed(address(rejecting));
        assertEq(credit, 10 ether * 3000 / 10000 - 10 ether / 200, "vault share credited, not lost");
        address stranger = makeAddr("fork deliverer");
        vm.prank(stranger);
        vm.expectRevert(LaunchHook.WithdrawFailed.selector);
        launchHook.withdrawFor(address(rejecting));
        assertEq(launchHook.owed(address(rejecting)), credit, "failed delivery keeps the credit");
        vm.prank(stranger);
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        launchHook.withdrawFor(stranger);
        rejecting.setAccepting(true);
        uint256 strangerBefore = stranger.balance;
        vm.prank(stranger);
        launchHook.withdrawFor(address(rejecting));
        assertEq(address(rejecting).balance, credit, "the credit reaches the recipient itself");
        assertEq(stranger.balance, strangerBefore, "the caller gains nothing");
        assertEq(launchHook.owed(address(rejecting)), 0);
        assertEq(address(launchHook).balance, 0);
        vm.prank(stranger);
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        launchHook.withdrawFor(address(rejecting));
    }
}
