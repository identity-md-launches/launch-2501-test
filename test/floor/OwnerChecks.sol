// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

interface IOwned {
    function owner() external view returns (address);
}

/// @notice Shared assertions about who owns a launch contract: never the factory that deploys it, never the
/// launch wallet that pays for the transaction, never the test harness that stands in for either.
abstract contract OwnerChecks is Test {
    /// @dev Stands in for IMD's launch wallet as `tx.origin` of the deployment.
    address internal constant ORIGIN_PROBE = address(uint160(0xA11));

    function checkOwner(string memory name, address target, address factory) internal view {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(IOwned.owner.selector));
        if (!ok || data.length < 32) return; // not ownable: nothing to own
        address owner = abi.decode(data, (address));
        assertTrue(owner != factory, string.concat(name, " is owned by the launch factory"));
        assertTrue(owner != ORIGIN_PROBE, string.concat(name, " is owned by the launch wallet (tx.origin)"));
        assertTrue(owner != address(this), string.concat(name, " is owned by the deploying harness"));
    }
}
