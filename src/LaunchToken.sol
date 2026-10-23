// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken (TEST)
/// @notice The launch's fixed-supply ERC-20. The whole supply is minted once to the deployer (the launch
/// factory) in the constructor. There is no owner, no mint, no pause, no blocklist, no transfer fee and
/// no upgrade path: every fee of this launch lives in the hook, never in the token.
contract LaunchToken is ERC20 {
    /// @notice 1,000,000,000 tokens at 18 decimals, the launch policy's supply.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("TEST", "TEST") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
