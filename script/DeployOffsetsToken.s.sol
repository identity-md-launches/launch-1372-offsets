// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {OffsetsToken} from "../src/OffsetsToken.sol";

/// @title Deploy script for OffsetsToken
/// @notice The IMD launch deploys the token itself from its built bytecode, so this script is a
///         reviewable reference for a manual deployment (for example to a testnet) and for tests.
///         The token takes no constructor arguments: whoever sends the deployment transaction
///         receives the whole supply.
contract DeployOffsetsToken is Script {
    /// @notice Deploys the token. Pure deployment logic, so tests can call it directly without
    ///         touching the environment or broadcasting.
    function deploy() public returns (OffsetsToken token) {
        token = new OffsetsToken();
    }

    /// @notice Entry point for `forge script`. Broadcasts with the sender `forge script` is given
    ///         (`--private-key`, `--ledger`, `--account` ...); that sender receives the supply.
    function run() external returns (OffsetsToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
