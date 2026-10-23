// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {DeployLaunchHook, LaunchParams} from "../script/Deploy.s.sol";
import {LaunchHook} from "../src/LaunchHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract DeployTest is Test {
    function test_deployWithLaunchParams() public {
        PoolManager manager = new PoolManager(address(this));
        LaunchToken token = new LaunchToken();
        DeployLaunchHook deployer = new DeployLaunchHook();

        LaunchHook hook = deployer.deploy(IPoolManager(address(manager)), address(token));

        assertTrue(HookFlags.matches(address(hook), LaunchParams.HOOK_FLAGS), "address carries the flags");
        assertEq(hook.owner(), LaunchParams.OWNER);
        assertEq(hook.researchVault(), LaunchParams.RESEARCH_VAULT);
        assertEq(hook.devWallet(), LaunchParams.DEV_WALLET);
        assertEq(hook.token(), address(token));
        assertEq(address(hook.poolManager()), address(manager));
        assertTrue(hook.owner() != address(deployer) && hook.owner() != address(this), "not owned by a deployer");

        // The pool the factory opens is accepted.
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, 79228162514264337593543950336);
        assertEq(hook.launchedAt(), block.timestamp);
    }

    function test_launchParamsMatchBrief() public pure {
        assertEq(LaunchParams.RESEARCH_VAULT, 0x087C0CF0A103acA2c487c5017DbC121ad6C5afEE);
        assertEq(LaunchParams.DEV_WALLET, 0x5Cf44fb6a49156125b5f9Dfea73E4011534C7944);
        assertEq(LaunchParams.OWNER, LaunchParams.DEV_WALLET);
        assertEq(LaunchParams.HOOK_FLAGS, 0x10CC);
    }
}
