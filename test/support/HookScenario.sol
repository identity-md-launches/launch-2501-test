// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {LaunchHook} from "src/LaunchHook.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {Swapper} from "../mocks/Swapper.sol";
import {SwapProbe} from "./SwapProbe.sol";
import {PartialFillRevert} from "./PartialFillRevert.sol";

abstract contract HookScenario is Test {
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant PRICE = 79228162514264337593543950336;
    int24 internal constant LOWER = -887220;
    int256 internal constant LIQUIDITY = 5e26;
    address internal constant RESEARCH_VAULT = 0x087C0CF0A103acA2c487c5017DbC121ad6C5afEE;
    address internal constant DEV_WALLET = 0x5Cf44fb6a49156125b5f9Dfea73E4011534C7944;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    IPoolManager internal pm;
    LaunchHook internal launchHook;
    LaunchToken internal launchToken;
    SwapProbe internal trader;
    Swapper internal lp;
    PoolKey internal pool;
    address internal vaultRecipient;
    address internal devRecipient;
    uint256 internal start;

    function _setupScenario(IPoolManager manager_, address vault_, address dev_, address admin_) internal {
        pm = manager_;
        vaultRecipient = vault_;
        devRecipient = dev_;
        launchToken = new LaunchToken();
        // Only the new hook is installed at a permission-bearing address. The manager is never etched.
        address hookAt = address(
            uint160(uint256(keccak256(abi.encode(address(launchToken), address(pm))))) & ~uint160(0x3fff)
                | uint160(0x10cc)
        );
        assertEq(hookAt.code.length, 0, "fixture must not replace existing code");
        deployCodeTo("src/LaunchHook.sol:LaunchHook", abi.encode(pm, launchToken, admin_, vault_, dev_), hookAt);
        launchHook = LaunchHook(payable(hookAt));
        pool = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(launchToken)), 12500, 60, IHooks(hookAt));
        pm.initialize(pool, PRICE);
        start = block.timestamp;
        lp = new Swapper(pm);
        launchToken.transfer(address(lp), 800_000_000 ether);
        uint256 managerEth = address(pm).balance;
        BalanceDelta seed = lp.modifyLiquidity(pool, LOWER, 0, LIQUIDITY);
        assertEq(seed.amount0(), 0, "single-sided seed must require no ETH");
        assertLt(seed.amount1(), 0, "single-sided seed deposits TEST");
        assertEq(address(pm).balance, managerEth, "seeding cannot fund the manager with ETH");
        trader = new SwapProbe(pm);
        vm.deal(address(trader), 1000 ether);
        launchToken.transfer(address(trader), 1000 ether);
    }

    function _params(bool buy, int256 specified) internal pure returns (SwapParams memory) {
        return SwapParams(buy, specified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    struct Balances {
        uint256 traderEth;
        uint256 traderToken;
        uint256 managerEth;
        uint256 managerToken;
        uint256 vaultEth;
        uint256 devEth;
    }

    function _balances() internal view returns (Balances memory s) {
        s = Balances(
            address(trader).balance,
            launchToken.balanceOf(address(trader)),
            address(pm).balance,
            launchToken.balanceOf(address(pm)),
            vaultRecipient.balance,
            devRecipient.balance
        );
    }

    /// @dev The PoolManager's Swap event is the independent AMM delta before hook fees.
    /// Fee assertions use actual token/ETH movement, never LaunchHook.splitFee or FeeCharged.
    function _ammDelta(Vm.Log[] memory logs) internal view returns (int128 eth, int128 tokens) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(pm) && logs[i].topics.length == 3 && logs[i].topics[0] == SWAP_EVENT
                    && logs[i].topics[1] == keccak256(abi.encode(pool))
            ) {
                (eth, tokens,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                ++count;
            }
        }
        assertEq(count, 1, "one genuine AMM swap must have executed");
    }

    function _assertPaidSwap(bool buy, int256 specified, uint256 rate) internal {
        _assertPaidLimitedSwap(buy, specified, _params(buy, specified).sqrtPriceLimitX96, rate, true);
    }

    /// @dev `full == false` requires a genuine partial fill: the specified leg moved, but less than asked.
    function _assertPaidLimitedSwap(bool buy, int256 specified, uint160 limit, uint256 rate, bool full) internal {
        Balances memory before_ = _balances();
        vm.recordLogs();
        BalanceDelta actual = trader.swap(pool, SwapParams(buy, specified, limit));
        (int128 ammEth, int128 ammToken) = _ammDelta(vm.getRecordedLogs());
        Balances memory after_ = _balances();
        uint256 fee = (after_.vaultEth - before_.vaultEth) + (after_.devEth - before_.devEth);
        uint256 gross = buy ? before_.traderEth - after_.traderEth : uint256(uint128(ammEth));
        assertGt(gross, 0, "test must move ETH");
        assertGt(fee, 0, "test must collect a fee");
        // Gross-up division may leave < 1 wei relative to the exact rational fee.
        assertLe(fee * 10000, gross * rate, "fee exceeds scheduled percentage");
        assertLt(gross * rate - fee * 10000, 10000, "fee is short by more than rounding dust");
        assertEq(after_.devEth - before_.devEth, gross / 200, "dev gets 0.5% of actual gross ETH");
        assertEq(after_.vaultEth - before_.vaultEth, fee - gross / 200, "research gets the remainder");
        assertEq(int256(actual.amount0()), int256(after_.traderEth) - int256(before_.traderEth));
        assertEq(int256(actual.amount1()), int256(after_.traderToken) - int256(before_.traderToken));
        assertEq(actual.amount1(), ammToken, "no fee may be charged in TEST");
        assertEq(int256(ammEth) - int256(actual.amount0()), int256(fee), "only fee modifies ETH delta");
        assertEq(int256(after_.managerToken) - int256(before_.managerToken), -int256(ammToken));
        assertEq(int256(after_.managerEth) - int256(before_.managerEth), -int256(ammEth));
        int128 filled =
            specified < 0 ? (buy ? actual.amount0() : actual.amount1()) : (buy ? actual.amount1() : actual.amount0());
        if (full) {
            assertEq(filled, specified, specified < 0 ? "full exact input" : "exact output");
        } else {
            assertTrue(filled != 0, "partial fill must move the specified leg");
            if (specified < 0) assertGt(filled, specified, "partial exact input spends less than asked");
            else assertLt(filled, specified, "partial exact output receives less than asked");
        }
        assertEq(launchHook.owed(vaultRecipient), 0);
        assertEq(launchHook.owed(devRecipient), 0);
        assertEq(launchHook.pendingClaims(), 0);
        assertEq(address(launchHook).balance, 0);
        _assertSettled();
    }

    /// @dev A swap the hook must refuse as a partial fill. Returns the hook's reported amounts; nothing moves.
    function _expectPartialFill(bool buy, int256 specified, uint160 limit)
        internal
        returns (uint256 assumed, uint256 executed)
    {
        Balances memory before_ = _balances();
        uint256 vaultCredit = launchHook.owed(vaultRecipient);
        uint256 devCredit = launchHook.owed(devRecipient);
        try trader.swap(pool, SwapParams(buy, specified, limit)) {
            fail("partial fill with ETH specified must revert");
        } catch (bytes memory reason) {
            bool ok;
            (ok, assumed, executed) = PartialFillRevert.decode(reason, address(launchHook));
            assertTrue(ok, "revert must be the hook's PartialFill");
        }
        assertLt(executed, assumed, "the pool swapped less ETH than the fee was sized for");
        assertEq(abi.encode(_balances()), abi.encode(before_), "a refused fill moves nothing");
        assertEq(launchHook.owed(vaultRecipient), vaultCredit);
        assertEq(launchHook.owed(devRecipient), devCredit);
        _assertSettled();
    }

    function _assertSettled() internal view {
        assertFalse(pm.isUnlocked(), "manager must relock");
        assertEq(pm.getNonzeroDeltaCount(), 0, "no unsettled flash accounting");
        assertEq(pm.currencyDelta(address(launchHook), pool.currency0), 0);
        assertEq(pm.currencyDelta(address(launchHook), pool.currency1), 0);
        assertEq(pm.currencyDelta(address(trader), pool.currency0), 0);
        assertEq(pm.currencyDelta(address(trader), pool.currency1), 0);
    }
}
