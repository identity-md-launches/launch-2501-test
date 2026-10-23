// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LaunchHook} from "../src/LaunchHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {ToggleVault} from "./mocks/Recipients.sol";

/// @notice Shared fixture: the real v4 PoolManager (compiled from v4-core), the launch token, the hook at an
/// address carrying its flags, and an ETH/TEST pool seeded with tokens only, as the launch seeds it.
abstract contract LaunchHookBase is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant POOL_FEE = 12_500;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant BPS = 10_000;
    /// @dev Token-only liquidity: ~5e26 wei of TEST in [minUsableTick, 0] at a 1:1 opening price.
    int256 internal constant SEED_LIQUIDITY = 5e26;
    /// @dev ETH other pools hold in the manager; a fresh manager (`fundManager = false`) has none.
    uint256 internal constant MANAGER_ETH = 1_000 ether;
    /// @dev afterInitialize, beforeSwap, afterSwap and both swap return deltas.
    uint160 internal constant HOOK_FLAGS = HookFlags.AFTER_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    PoolManager internal manager;
    LaunchToken internal token;
    LaunchHook internal hook;
    Swapper internal swapper;
    Swapper internal seeder;
    ToggleVault internal vault;
    address internal dev = makeAddr("devWallet");
    address internal owner = makeAddr("owner");
    address internal factory = makeAddr("launchFactory");
    PoolKey internal key;
    uint256 internal launchedAt;

    function _fundManager() internal view virtual returns (bool) {
        return true;
    }

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        vm.prank(factory);
        token = new LaunchToken();
        vault = new ToggleVault();

        hook = _deployHook(address(token), owner, address(vault), dev);
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.warp(1_700_000_000);
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);
        launchedAt = block.timestamp;

        // Single-sided seed from the factory's stand-in: tokens only, below the opening price.
        seeder = new Swapper(IPoolManager(address(manager)));
        vm.prank(factory);
        token.transfer(address(seeder), 800_000_000 ether);
        BalanceDelta seedDelta = seeder.modifyLiquidity(key, TickMath.minUsableTick(TICK_SPACING), 0, SEED_LIQUIDITY);
        assertEq(seedDelta.amount0(), 0, "seed must not need ETH");
        assertLt(seedDelta.amount1(), 0, "seed must deposit tokens");

        if (_fundManager()) vm.deal(address(manager), MANAGER_ETH);

        swapper = new Swapper(IPoolManager(address(manager)));
        vm.deal(address(swapper), 1_000 ether);
    }

    function _deployHook(address token_, address owner_, address vault_, address dev_) internal returns (LaunchHook) {
        // Any address whose low 14 bits are the flags will do for a local deployment.
        address at = address((uint160(0x1234) << 144) | HOOK_FLAGS);
        deployCodeTo("LaunchHook.sol:LaunchHook", abi.encode(manager, token_, owner_, vault_, dev_), at);
        return LaunchHook(payable(at));
    }

    /// @dev Give the swapper tokens to sell.
    function _giveTokens(address to, uint256 amount) internal {
        vm.prank(factory);
        token.transfer(to, amount);
    }

    /// @dev Put ETH into the pool through a buy so sells have something to pay out.
    function _primePoolWithEth(uint256 ethIn) internal {
        swapper.swap(key, true, ethIn);
    }

    struct Snapshot {
        uint256 swapperEth;
        uint256 swapperToken;
        uint256 managerEth;
        uint256 devEth;
        uint256 vaultEth;
        uint256 hookEth;
    }

    function _snap() internal view returns (Snapshot memory s) {
        s.swapperEth = address(swapper).balance;
        s.swapperToken = token.balanceOf(address(swapper));
        s.managerEth = address(manager).balance;
        s.devEth = dev.balance;
        s.vaultEth = address(vault).balance;
        s.hookEth = address(hook).balance;
    }
}
