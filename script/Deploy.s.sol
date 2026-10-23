// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LaunchHook} from "../src/LaunchHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @title LaunchParams
/// @notice The launch's fixed deployment parameters, in one place. The IMD launch factory deploys the token
/// and the hook from their bytecode with these constructor arguments ("$poolManager", "$token" and "$owner"
/// are resolved by the deployer); this file records the values and lets a rehearsal reproduce them.
library LaunchParams {
    /// @notice Research vault: receives everything above the dev share.
    address internal constant RESEARCH_VAULT = 0x087C0CF0A103acA2c487c5017DbC121ad6C5afEE;
    /// @notice Dev wallet: receives 0.5% of every swap's gross ETH.
    address internal constant DEV_WALLET = 0x5Cf44fb6a49156125b5f9Dfea73E4011534C7944;
    /// @notice Owner of the fee-lowering functions.
    address internal constant OWNER = 0x5Cf44fb6a49156125b5f9Dfea73E4011534C7944;
    /// @notice Address bits the hook's address must carry.
    uint160 internal constant HOOK_FLAGS = HookFlags.AFTER_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    /// @notice ABI-encoded constructor arguments for `LaunchHook`.
    function hookConstructorArgs(IPoolManager poolManager, address token) internal pure returns (bytes memory) {
        return abi.encode(poolManager, token, OWNER, RESEARCH_VAULT, DEV_WALLET);
    }

    /// @notice Mines a CREATE2 salt so that `deployer` lands the hook on an address carrying `HOOK_FLAGS`.
    function mineSalt(address deployer, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (bytes32 salt, address hook)
    {
        bytes32 initCodeHash = keccak256(creationCodeWithArgs);
        for (uint256 i = 0; i < 500_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (HookFlags.matches(predicted, HOOK_FLAGS)) return (bytes32(i), predicted);
        }
        revert("LaunchParams: no salt found");
    }
}

/// @title DeployLaunchHook
/// @notice Rehearsal deployer: deploys `LaunchHook` with the launch's fixed parameters at a mined address.
/// The production launch is made by the IMD factory, not by this script.
contract DeployLaunchHook is Script {
    /// @notice Deploy the hook from this contract with CREATE2 at an address carrying its flags.
    function deploy(IPoolManager poolManager, address token) public returns (LaunchHook hook) {
        bytes memory code =
            abi.encodePacked(type(LaunchHook).creationCode, LaunchParams.hookConstructorArgs(poolManager, token));
        (bytes32 salt, address predicted) = LaunchParams.mineSalt(address(this), code);
        hook = new LaunchHook{salt: salt}(
            poolManager, token, LaunchParams.OWNER, LaunchParams.RESEARCH_VAULT, LaunchParams.DEV_WALLET
        );
        require(address(hook) == predicted, "DeployLaunchHook: address mismatch");
    }

    /// @notice `POOL_MANAGER` and `TOKEN` come from the environment; everything else is fixed above.
    function run() external returns (LaunchHook hook) {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address token = vm.envAddress("TOKEN");
        vm.startBroadcast();
        hook = deploy(poolManager, token);
        vm.stopBroadcast();
    }
}
