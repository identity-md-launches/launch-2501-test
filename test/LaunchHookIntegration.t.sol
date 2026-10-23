// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HookScenario} from "./support/HookScenario.sol";
import {ToggleVault} from "./mocks/Recipients.sol";

contract LaunchHookIntegrationTest is HookScenario {
    function setUp() public {
        IPoolManager manager_ = IPoolManager(address(new PoolManager(address(this))));
        vm.deal(address(manager_), 1000 ether);
        vm.warp(1700000000);
        _setupScenario(manager_, address(new ToggleVault()), makeAddr("integration dev"), makeAddr("integration owner"));
    }

    function test_fourSwapTypesAtEveryScheduleBoundary() public {
        trader.swap(pool, _params(true, -50 ether));
        uint256[6] memory times = [uint256(0), 1, 1800, 3599, 3600, 86400];
        uint256[6] memory rates = [uint256(3000), 3000, 1600, 201, 200, 200];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(start + times[i]);
            _assertPaidSwap(true, -1 ether, rates[i]);
            _assertPaidSwap(true, 1 ether, rates[i]);
            _assertPaidSwap(false, -1 ether, 200);
            _assertPaidSwap(false, 0.1 ether, 200);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exactOutputFeesUseActualEth(uint96 amountSeed, uint32 elapsedSeed, bool buy) public {
        trader.swap(pool, _params(true, -50 ether));
        uint256 elapsed = bound(elapsedSeed, 0, 7200);
        vm.warp(start + elapsed);
        uint256 amount = bound(amountSeed, 1e9, 1 ether);
        // Ceil of the remaining linear premium, independently of the hook's fee view.
        uint256 buyRate = elapsed >= 3600 ? 200 : 200 + (2800 * (3600 - elapsed) + 3599) / 3600;
        _assertPaidSwap(buy, int256(amount), buy ? buyRate : 200);
    }

    function test_alternatingSwapTypesInOneUnlockHaveIndependentTransientFees() public {
        trader.swap(pool, _params(true, -20 ether));
        SwapParams[] memory sequence = new SwapParams[](4);
        sequence[0] = _params(true, -1 ether);
        sequence[1] = _params(false, -0.1 ether);
        sequence[2] = _params(true, 0.2 ether);
        sequence[3] = _params(false, 0.1 ether);
        uint256 snapshot = vm.snapshotState();
        Balances memory before_ = _balances();
        BalanceDelta[4] memory expected;
        for (uint256 i; i < sequence.length; ++i) {
            expected[i] = trader.swap(pool, sequence[i]);
        }
        Balances memory separate = _balances();
        assertTrue(vm.revertToState(snapshot));
        (BalanceDelta[] memory together, bool reverted) = trader.batch(pool, sequence, false);
        assertFalse(reverted);
        for (uint256 i; i < sequence.length; ++i) {
            assertEq(BalanceDelta.unwrap(together[i]), BalanceDelta.unwrap(expected[i]));
        }
        assertEq(abi.encode(_balances()), abi.encode(separate), "same state for batched and separate swaps");
        assertGt(vaultRecipient.balance - before_.vaultEth, 0);
        _assertSettled();
    }

    function test_revertedSwapDoesNotContaminateLaterSwapInSameUnlock() public {
        SwapParams[] memory sequence = new SwapParams[](2);
        // beforeSwap writes a 30 ETH transient fee, then PoolManager rejects this invalid limit.
        sequence[0] = SwapParams(true, -100 ether, PRICE);
        sequence[1] = _params(true, 1 ether);
        uint256 snapshot = vm.snapshotState();
        BalanceDelta expected = trader.swap(pool, sequence[1]);
        Balances memory separate = _balances();
        assertTrue(vm.revertToState(snapshot));
        (BalanceDelta[] memory together, bool firstReverted) = trader.batch(pool, sequence, true);
        assertTrue(firstReverted, "invalid limit must reach and fail the AMM");
        assertEq(BalanceDelta.unwrap(together[0]), 0);
        assertEq(BalanceDelta.unwrap(together[1]), BalanceDelta.unwrap(expected));
        assertEq(abi.encode(_balances()), abi.encode(separate));
        _assertSettled();
    }

    function test_zeroSwapRevertsWithoutMovingMoney() public {
        Balances memory before_ = _balances();
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        trader.swap(pool, _params(true, 0));
        assertEq(abi.encode(_balances()), abi.encode(before_));
        _assertSettled();
    }
}
