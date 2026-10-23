// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LaunchHook} from "src/LaunchHook.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {HookScenario} from "./support/HookScenario.sol";
import {SwapProbe} from "./support/SwapProbe.sol";
import {PartialFillRevert} from "./support/PartialFillRevert.sol";
import {ToggleVault, IPullable} from "./mocks/Recipients.sol";

contract ForceFeeDonation {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

/// @notice Drives real swaps, credit withdrawals, redemptions, fee changes and ownership changes.
/// Ghost fees derive from actual AMM deltas and actual trader deltas, not hook accounting/events.
contract FeeAccountingHandler is Test {
    using StateLibrary for IPoolManager;
    bytes32 private constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    IPoolManager public immutable pm;
    LaunchHook public immutable hook;
    LaunchToken public immutable token;
    ToggleVault public immutable vault;
    ToggleVault public immutable dev;
    PoolKey private pool;
    SwapProbe[3] public actors;
    address public immutable vaultSink;
    address public immutable devSink;
    address public immutable outsider;
    uint256 public expectedVault;
    uint256 public expectedDev;
    uint256 public poolEth;
    uint256 public donatedEth;
    uint256 public donatedTokens;
    uint256 public successfulSwaps;
    uint256 public withdrawals;
    uint256 public partialFills;
    uint256 public refusedFills;
    uint16 public lastLaunch = 3000;
    uint16 public lastBase = 200;

    constructor(
        IPoolManager pm_,
        LaunchHook hook_,
        LaunchToken token_,
        PoolKey memory pool_,
        SwapProbe[3] memory actors_
    ) {
        pm = pm_;
        hook = hook_;
        token = token_;
        pool = pool_;
        actors = actors_;
        vault = ToggleVault(payable(hook_.researchVault()));
        dev = ToggleVault(payable(hook_.devWallet()));
        vaultSink = makeAddr("invariant vault sink");
        devSink = makeAddr("invariant dev sink");
        outsider = makeAddr("invariant outsider");
    }

    function trade(uint256 actorSeed, uint256 amountSeed, bool buy, bool exactInput) external {
        // Extreme price limits. Sells are sized from measured AMM ETH, but part of that ETH is LP fees the
        // swap cannot pay out, so an exact-output sell may still meet an exhausted pool: the hook must then
        // refuse it with PartialFill. A buy at the extreme limit always has TEST depth and must fill.
        if (poolEth < 1e8 || _atTopPrice()) buy = true;
        uint256 maximum = buy || poolEth / 4 > 0.5 ether ? 0.5 ether : poolEth / 4;
        uint256 amount = bound(amountSeed, 1e6, maximum);
        bool refused = _execute(
            actors[actorSeed % 3],
            SwapParams(
                buy,
                exactInput ? -int256(amount) : int256(amount),
                buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        if (refused) assertFalse(buy, "an extreme-limit buy never runs out of TEST");
    }

    /// @dev Price-limited swaps of every type, sized up to twice the pool's ETH so both stop conditions
    /// (limit reached, ETH exhausted) occur. ETH-specified swaps must fill fully or revert with PartialFill;
    /// ETH-unspecified swaps may fill partially and are charged on the executed ETH.
    function limitedTrade(uint256 actorSeed, uint256 amountSeed, uint256 limitSeed, bool buy, bool exactInput)
        external
    {
        if (poolEth < 1e8 || _atTopPrice()) buy = true;
        uint256 amount = bound(amountSeed, 1e6, buy ? 2 ether : 2 * poolEth);
        SwapProbe actor = actors[actorSeed % 3];
        if (!buy && exactInput && amount > token.balanceOf(address(actor))) amount = token.balanceOf(address(actor));
        (uint160 price,,,) = pm.getSlot0(pool.toId());
        // Relative moves from 1e-12 to 1e-6 span fills from dust to several ETH at this pool's depth.
        uint256 move = price / bound(limitSeed, 1e6, 1e12);
        uint160 limit = buy ? price - uint160(move) : price + uint160(move);
        // An extreme-limit sell can leave the price at the top bound; there is nothing left to sell into.
        if (!buy && limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
        _execute(actor, SwapParams(buy, exactInput ? -int256(amount) : int256(amount), limit));
    }

    /// @dev An extreme-limit sell that runs past the TEST-only range leaves the price at the top bound, where
    /// the PoolManager rejects every further sell before the hook runs.
    function _atTopPrice() private view returns (bool) {
        (uint160 price,,,) = pm.getSlot0(pool.toId());
        return price >= TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev One real swap. Success: the fee is checked against the executed ETH and booked. Failure: only the
    /// hook's PartialFill on an ETH-specified swap is acceptable, and the whole swap is undone.
    function _execute(SwapProbe actor, SwapParams memory p) private returns (bool refused) {
        bool buy = p.zeroForOne;
        bool ethSpecified = (p.amountSpecified < 0) == buy;
        uint256 rate = buy ? _expectedBuyRate() : hook.baseFeeBps();
        uint256 managerEth = address(pm).balance;
        vm.recordLogs();
        try actor.swap(pool, p) returns (BalanceDelta delta) {
            int128 ammEth = _readAmmEth(vm.getRecordedLogs());
            int128 filled = ethSpecified ? delta.amount0() : delta.amount1();
            if (ethSpecified) assertEq(filled, p.amountSpecified, "ETH-specified swaps only ever fill fully");
            else if (filled != p.amountSpecified) ++partialFills;
            uint256 fee = uint256(int256(ammEth) - int256(delta.amount0()));
            uint256 gross = buy ? uint256(-int256(delta.amount0())) : uint256(uint128(ammEth));
            assertLe(fee * 10000, gross * rate, "fee exceeds the rate on executed ETH");
            assertLt(gross * rate - fee * 10000, 10000, "fee undercharged on executed ETH");
            expectedDev += gross / 200;
            expectedVault += fee - gross / 200;
            poolEth = uint256(int256(poolEth) - int256(ammEth));
            ++successfulSwaps;
        } catch (bytes memory reason) {
            (bool ok, uint256 assumed, uint256 executed) = PartialFillRevert.decode(reason, address(hook));
            assertTrue(ok, "only the hook's PartialFill may refuse a swap");
            assertTrue(ethSpecified, "only ETH-specified swaps are refused");
            assertLt(executed, assumed);
            assertEq(address(pm).balance, managerEth, "a refused swap moves no ETH");
            ++refusedFills;
            refused = true;
        }
    }

    /// @dev Anyone may deliver a recipient's credit, only ever to the recipient itself.
    function deliver(uint8 recipientSeed) external {
        ToggleVault recipient = recipientSeed % 2 == 0 ? vault : dev;
        uint256 credit = hook.owed(address(recipient));
        uint256 before_ = address(recipient).balance;
        uint256 outsiderBefore = outsider.balance;
        vm.prank(outsider);
        if (credit == 0) {
            vm.expectRevert(LaunchHook.NothingOwed.selector);
            hook.withdrawFor(address(recipient));
        } else if (!recipient.accepting()) {
            vm.expectRevert(LaunchHook.WithdrawFailed.selector);
            hook.withdrawFor(address(recipient));
            assertEq(hook.owed(address(recipient)), credit, "failed delivery must preserve credit");
        } else {
            hook.withdrawFor(address(recipient));
            assertEq(address(recipient).balance - before_, credit, "deliver exactly the recipient's credit");
            assertEq(hook.owed(address(recipient)), 0);
            ++withdrawals;
        }
        assertEq(outsider.balance, outsiderBefore, "the deliverer gains nothing");
    }

    function toggleRecipients(bool vaultAccepting, bool devAccepting) external {
        vault.setAccepting(vaultAccepting);
        dev.setAccepting(devAccepting);
    }

    function pull(uint8 recipientSeed, bool toSelf) external {
        ToggleVault recipient = recipientSeed % 2 == 0 ? vault : dev;
        address sink = recipientSeed % 2 == 0 ? vaultSink : devSink;
        address to = toSelf ? address(recipient) : sink;
        uint256 credit = hook.owed(address(recipient));
        if (credit == 0) {
            vm.expectRevert(LaunchHook.NothingOwed.selector);
            recipient.pull(IPullable(address(hook)), to);
        } else if (toSelf && !recipient.accepting()) {
            vm.expectRevert(LaunchHook.WithdrawFailed.selector);
            recipient.pull(IPullable(address(hook)), to);
            assertEq(hook.owed(address(recipient)), credit, "failed pull must preserve credit");
        } else {
            uint256 before_ = to.balance;
            recipient.pull(IPullable(address(hook)), to);
            assertEq(to.balance - before_, credit, "withdraw exactly caller's credit");
            assertEq(hook.owed(address(recipient)), 0);
            ++withdrawals;
        }
    }

    function redeem() external {
        hook.redeemClaims();
    }

    function advanceTime(uint32 secondsSeed) external {
        uint256 oldRate = hook.buyFeeBps();
        vm.warp(block.timestamp + bound(secondsSeed, 0, 900));
        assertLe(hook.buyFeeBps(), oldRate, "time cannot increase the rate");
    }

    function lowerFees(uint16 baseSeed, uint16 launchSeed) external {
        address owner = hook.owner();
        if (owner == address(0)) {
            _rejectAdmin();
            return;
        }
        uint16 base = uint16(bound(baseSeed, 50, lastBase));
        uint16 launch = uint16(bound(launchSeed, base, lastLaunch));
        uint256 oldRate = hook.buyFeeBps();
        vm.startPrank(owner);
        hook.setBaseFee(base);
        hook.setLaunchFee(launch);
        vm.stopPrank();
        assertLe(hook.buyFeeBps(), oldRate, "administration cannot increase the current rate");
        assertLe(base, lastBase);
        assertLe(launch, lastLaunch);
        lastBase = base;
        lastLaunch = launch;
    }

    function attemptIncrease() external {
        address owner = hook.owner();
        if (owner == address(0)) {
            _rejectAdmin();
            return;
        }
        vm.startPrank(owner);
        vm.expectRevert(LaunchHook.FeeCanOnlyDecrease.selector);
        hook.setBaseFee(lastBase + 1);
        vm.expectRevert(LaunchHook.FeeCanOnlyDecrease.selector);
        hook.setLaunchFee(lastLaunch + 1);
        vm.stopPrank();
    }

    function ownership(uint8 seed, bool renounce) external {
        address owner = hook.owner();
        if (owner == address(0)) {
            _rejectAdmin();
            return;
        }
        vm.prank(owner);
        if (renounce) hook.renounceOwnership();
        else hook.transferOwnership(address(actors[seed % 3]));
        // Previous owners other than the new one lose all administrative privileges.
        if (hook.owner() != owner) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
            hook.setBaseFee(lastBase);
        }
    }

    function unauthorized() external {
        _rejectAdmin();
        vm.prank(outsider);
        vm.expectRevert(LaunchHook.NothingOwed.selector);
        hook.withdraw(outsider);
    }

    function donate(uint96 ethSeed, uint96 tokenSeed) external {
        uint256 ethAmount = bound(ethSeed, 0, 1e12);
        uint256 tokenAmount = bound(tokenSeed, 0, 1e12);
        if (ethAmount != 0) {
            new ForceFeeDonation{value: ethAmount}(payable(address(hook)));
            donatedEth += ethAmount;
        }
        if (tokenAmount != 0) {
            token.transfer(address(hook), tokenAmount);
            donatedTokens += tokenAmount;
        }
    }

    function _rejectAdmin() private {
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.setBaseFee(50);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.setLaunchFee(200);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.transferOwnership(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.renounceOwnership();
        vm.stopPrank();
    }

    function _expectedBuyRate() private view returns (uint256) {
        uint256 elapsed = block.timestamp - hook.launchedAt();
        uint256 base = hook.baseFeeBps();
        if (elapsed >= 3600) return base;
        return base + ((hook.launchFeeBps() - base) * (3600 - elapsed) + 3599) / 3600;
    }

    function _readAmmEth(Vm.Log[] memory logs) private view returns (int128 eth) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pm) && logs[i].topics[0] == SWAP_EVENT) {
                (eth,,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                ++count;
            }
        }
        assertEq(count, 1, "handler must execute a real swap");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchHookInvariantTest is HookScenario {
    FeeAccountingHandler internal handler;
    ToggleVault internal vault;
    ToggleVault internal dev;
    SwapProbe[3] internal actors;

    function setUp() public {
        vm.warp(1700000000);
        vault = new ToggleVault();
        dev = new ToggleVault();
        _setupScenario(
            IPoolManager(address(new PoolManager(address(this)))), address(vault), address(dev), address(this)
        );
        actors[0] = trader;
        for (uint256 i = 1; i < 3; ++i) {
            actors[i] = new SwapProbe(pm);
            vm.deal(address(actors[i]), 1000 ether);
            launchToken.transfer(address(actors[i]), 1000 ether);
        }
        handler = new FeeAccountingHandler(pm, launchHook, launchToken, pool, actors);
        vm.deal(address(handler), 1 ether);
        launchToken.transfer(address(handler), 1 ether);
        // Guarantee the initial state includes a backed claim and unpaid fees on an empty manager.
        handler.toggleRecipients(false, false);
        handler.trade(0, 0.1 ether, true, true);
        assertGt(launchHook.pendingClaims(), 0, "initial sequence exercises claim fallback");
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.toggleRecipients.selector;
        selectors[2] = handler.pull.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.advanceTime.selector;
        selectors[5] = handler.lowerFees.selector;
        selectors[6] = handler.attemptIncrease.selector;
        selectors[7] = handler.ownership.selector;
        selectors[8] = handler.unauthorized.selector;
        selectors[9] = handler.donate.selector;
        selectors[10] = handler.limitedTrade.selector;
        selectors[11] = handler.deliver.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_feeCreditsAreFullyBackedAndConserved() public view {
        uint256 liabilities = launchHook.owed(address(vault)) + launchHook.owed(address(dev));
        assertEq(address(launchHook).balance + launchHook.pendingClaims(), liabilities + handler.donatedEth());
        assertEq(
            handler.expectedVault(),
            address(vault).balance + handler.vaultSink().balance + launchHook.owed(address(vault))
        );
        assertEq(
            handler.expectedDev(), address(dev).balance + handler.devSink().balance + launchHook.owed(address(dev))
        );
        assertEq(
            address(pm).balance, handler.poolEth() + launchHook.pendingClaims(), "pool reserves plus outstanding claims"
        );
        assertGt(handler.successfulSwaps(), 0);
    }

    function invariant_tokenSupplyAndEthBalancesAreConserved() public view {
        uint256 sum = launchToken.balanceOf(address(this)) + launchToken.balanceOf(address(lp))
            + launchToken.balanceOf(address(pm)) + launchToken.balanceOf(address(handler))
            + launchToken.balanceOf(address(launchHook));
        uint256 eth = address(pm).balance + address(launchHook).balance + address(vault).balance + address(dev).balance
            + handler.vaultSink().balance + handler.devSink().balance + address(handler).balance;
        for (uint256 i; i < 3; ++i) {
            sum += launchToken.balanceOf(address(actors[i]));
            eth += address(actors[i]).balance;
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(launchToken.totalSupply(), sum);
        assertEq(launchToken.balanceOf(address(launchHook)), handler.donatedTokens(), "no TEST swap fee");
        assertEq(eth, 3001 ether, "ETH never appears or disappears through payouts/claims");
    }

    function invariant_feesStayLoweredAndThePoolRemainsBound() public view {
        assertEq(launchHook.launchFeeBps(), handler.lastLaunch());
        assertEq(launchHook.baseFeeBps(), handler.lastBase());
        assertGe(launchHook.baseFeeBps(), 50);
        assertLe(launchHook.baseFeeBps(), 200);
        assertLe(launchHook.launchFeeBps(), 3000);
        assertGe(launchHook.launchFeeBps(), launchHook.baseFeeBps());
        assertEq(launchHook.launchedAt(), start);
        assertEq(abi.encode(launchHook.poolId()), abi.encode(pool.toId()));
        _assertSettled();
    }

    /// @dev End every random sequence by proving all credits are actually withdrawable.
    function afterInvariant() public {
        vault.setAccepting(true);
        dev.setAccepting(true);
        launchHook.redeemClaims();
        assertEq(launchHook.pendingClaims(), 0);
        assertEq(launchHook.owed(address(vault)), 0);
        assertEq(launchHook.owed(address(dev)), 0);
        assertEq(address(vault).balance + handler.vaultSink().balance, handler.expectedVault());
        assertEq(address(dev).balance + handler.devSink().balance, handler.expectedDev());
        assertEq(address(launchHook).balance, handler.donatedEth());
    }
}
