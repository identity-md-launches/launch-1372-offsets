// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OffsetsToken} from "../src/OffsetsToken.sol";
import {DeployOffsetsToken} from "../script/DeployOffsetsToken.s.sol";

contract DeployOffsetsTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    /// @dev The script's deploy function is called directly, with no environment and no broadcast.
    ///      The supply lands on the script contract, because that is the deployer in this call.
    function test_deployMintsSupplyToTheDeployingContract() public {
        DeployOffsetsToken script = new DeployOffsetsToken();
        OffsetsToken token = script.deploy();
        assertEq(token.name(), "Offsets");
        assertEq(token.symbol(), "OFFSETS");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(script)), SUPPLY);
    }

    /// @dev Bytecode built here is what the launch deploys: a no-argument creation code that
    ///      succeeds on an empty chain through CREATE2, minting to the CREATE2 deployer.
    function test_creationCodeDeploysThroughCreate2OnEmptyChain() public {
        bytes memory code = type(OffsetsToken).creationCode;
        bytes32 salt = bytes32(uint256(7));
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        assertTrue(deployed != address(0), "create2 failed");
        OffsetsToken token = OffsetsToken(deployed);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
