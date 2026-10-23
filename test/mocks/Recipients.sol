// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPullable {
    function withdraw(address to) external;
}

/// @notice Stand-in for the research vault: a contract with a payable receive that can be switched to reject
/// ETH, and that can pull its credit from the hook.
contract ToggleVault {
    bool public accepting = true;
    uint256 public received;

    receive() external payable {
        require(accepting, "ToggleVault: rejecting");
        received += msg.value;
    }

    function setAccepting(bool value) external {
        accepting = value;
    }

    function pull(IPullable hook, address to) external {
        hook.withdraw(to);
    }
}

/// @notice A recipient whose receive burns more gas than the hook's push allowance.
contract GasHungryVault {
    uint256[] private sink;

    receive() external payable {
        for (uint256 i = 0; i < 20; i++) {
            sink.push(i);
        }
    }

    function pull(IPullable hook, address to) external {
        hook.withdraw(to);
    }
}
