// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OffsetsToken} from "../src/OffsetsToken.sol";

/// @notice A holder that can only receive and forward tokens: a stand-in for the launch's
///         MerkleDistributor, which is itself just an ordinary holder from the token's point of view.
contract Forwarder {
    function forward(OffsetsToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract OffsetsTokenTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    OffsetsToken internal token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new OffsetsToken();
    }

    // ------------------------------------------------------------------
    // Metadata and supply
    // ------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Offsets");
        assertEq(token.symbol(), "OFFSETS");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 1_000_000_000);
        assertEq(token.totalSupply(), token.SUPPLY_WHOLE_TOKENS() * 10 ** token.decimals());
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsMintTransferFromZero() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        new OffsetsToken();
    }

    /// @dev The supply goes to whoever deploys, which at launch is the factory. Two deployments
    ///      from two senders each hold their own whole supply: nothing is tied to a fixed address.
    function test_supplyGoesToMsgSenderWhoeverThatIs() public {
        vm.prank(BOB);
        OffsetsToken other = new OffsetsToken();
        assertEq(other.balanceOf(BOB), SUPPLY);
        assertEq(other.balanceOf(DEPLOYER), 0);
        assertEq(other.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------
    // transfer
    // ------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        uint256 amount = 1_234_567 * 1e18;
        vm.expectEmit(true, true, true, true);
        emit Transfer(DEPLOYER, ALICE, amount);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, amount));

        assertEq(token.balanceOf(ALICE), amount, "recipient got less or more than sent");
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY, "a transfer changed the supply");
    }

    function test_transferWholeBalance() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(DEPLOYER, 5e18));
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function test_RevertWhen_transferExceedsBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10e18);

        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientBalance.selector, ALICE, 10e18, 10e18 + 1));
        vm.prank(ALICE);
        token.transfer(BOB, 10e18 + 1);

        assertEq(token.balanceOf(ALICE), 10e18, "a failed transfer changed the sender's balance");
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_RevertWhen_transferFromEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientBalance.selector, CAROL, 0, 1));
        vm.prank(CAROL);
        token.transfer(BOB, 1);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        vm.expectRevert(OffsetsToken.ZeroAddress.selector);
        vm.prank(DEPLOYER);
        token.transfer(address(0), 1e18);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    // ------------------------------------------------------------------
    // approve / allowance
    // ------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(ALICE, BOB, 42e18);
        vm.prank(ALICE);
        assertTrue(token.approve(BOB, 42e18));
        assertEq(token.allowance(ALICE, BOB), 42e18);
        assertEq(token.allowance(BOB, ALICE), 0, "allowance is directional");
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(ALICE);
        token.approve(BOB, 10e18);
        token.approve(BOB, 3e18);
        vm.stopPrank();
        assertEq(token.allowance(ALICE, BOB), 3e18);
    }

    function test_approveDoesNotRequireBalance() public {
        vm.prank(CAROL);
        assertTrue(token.approve(BOB, SUPPLY));
        assertEq(token.allowance(CAROL, BOB), SUPPLY);
    }

    function test_RevertWhen_approveZeroSpender() public {
        vm.expectRevert(OffsetsToken.ZeroAddress.selector);
        vm.prank(ALICE);
        token.approve(address(0), 1);
    }

    // ------------------------------------------------------------------
    // transferFrom
    // ------------------------------------------------------------------

    function test_transferFromSpendsAllowanceAndEmits() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 100e18);

        vm.expectEmit(true, true, true, true);
        emit Approval(DEPLOYER, ALICE, 60e18);
        vm.expectEmit(true, true, true, true);
        emit Transfer(DEPLOYER, BOB, 40e18);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 40e18));

        assertEq(token.balanceOf(BOB), 40e18);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 40e18);
        assertEq(token.balanceOf(ALICE), 0, "the spender received nothing itself");
        assertEq(token.allowance(DEPLOYER, ALICE), 60e18);
    }

    function test_transferFromExactAllowanceLeavesZero() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 7e18);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 7e18);
        assertEq(token.allowance(DEPLOYER, ALICE), 0);
    }

    function test_transferFromInfiniteAllowanceIsNotDecremented() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 1_000e18);
        assertEq(token.allowance(DEPLOYER, ALICE), type(uint256).max);
        assertEq(token.balanceOf(BOB), 1_000e18);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 5e18);

        vm.expectRevert(
            abi.encodeWithSelector(OffsetsToken.InsufficientAllowance.selector, DEPLOYER, ALICE, 5e18, 5e18 + 1)
        );
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 5e18 + 1);

        assertEq(token.allowance(DEPLOYER, ALICE), 5e18, "a failed transferFrom spent allowance");
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_RevertWhen_transferFromWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientAllowance.selector, DEPLOYER, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    /// @dev An allowance is not a balance: the owner must actually hold what the spender moves.
    function test_RevertWhen_transferFromExceedsOwnerBalance() public {
        vm.prank(CAROL);
        token.approve(ALICE, 10e18);
        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientBalance.selector, CAROL, 0, 10e18));
        vm.prank(ALICE);
        token.transferFrom(CAROL, BOB, 10e18);
    }

    function test_RevertWhen_transferFromToZeroAddress() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 10e18);
        vm.expectRevert(OffsetsToken.ZeroAddress.selector);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, address(0), 1e18);
    }

    // ------------------------------------------------------------------
    // Launch flows: everything arrives whole, nothing is exempt because nothing is taxed
    // ------------------------------------------------------------------

    /// @dev Mirrors the factory's payout: 10% to the distributor, which pays a claimant in full;
    ///      80% to the pool seed; the remaining 10% to the requester. Every leg must land exactly.
    function test_launchFlowsArriveWhole() public {
        Forwarder distributor = new Forwarder();
        address poolManager = address(0x900C);
        address remainderTo = address(0xff3E8d9bA776662Ca6Ed1420EE366AFB436d2684);

        uint256 swarm = SUPPLY * 1_000 / 10_000;
        uint256 pool = SUPPLY * 8_000 / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        vm.startPrank(DEPLOYER);
        assertTrue(token.transfer(address(distributor), swarm));
        assertTrue(token.transfer(poolManager, pool));
        assertTrue(token.transfer(remainderTo, remainder));
        vm.stopPrank();

        assertEq(token.balanceOf(address(distributor)), swarm, "the swarm share arrived short");
        assertEq(token.balanceOf(poolManager), pool, "the pool seed arrived short");
        assertEq(token.balanceOf(remainderTo), remainder, "the remainder arrived short");
        assertEq(token.balanceOf(DEPLOYER), 0, "the factory kept something back");

        assertTrue(distributor.forward(token, ALICE, swarm));
        assertEq(token.balanceOf(ALICE), swarm, "a claim arrived short");
        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(token.totalSupply(), SUPPLY, "the launch flows changed the supply");
    }

    // ------------------------------------------------------------------
    // No privileged functions exist
    // ------------------------------------------------------------------

    /// @dev The contract has no fallback, so any selector it does not implement reverts. None of
    ///      the usual admin entry points exist, and the supply and balances are untouched after trying.
    function test_noAdminOrMintEntryPointsExist() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1_000e18);
        uint256 held = token.balanceOf(ALICE);

        string[22] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "owner()",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "seize(address)"
        ];
        address[2] memory callers = [DEPLOYER, address(0xBEEF)];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, type(uint128).max);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, string.concat("unexpected entry point: ", signatures[i]));
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.balanceOf(address(0xBEEF)), 0);

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2), "the holder can no longer transfer");
    }

    function test_RevertWhen_plainEtherIsSent() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0);
    }

    /// @dev Same opcode scan the launch floor runs: no DELEGATECALL, CALLCODE or SELFDESTRUCT.
    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "runtime code contains DELEGATECALL");
            assertTrue(op != 0xF2, "runtime code contains CALLCODE");
            assertTrue(op != 0xFF, "runtime code contains SELFDESTRUCT");
        }
    }

    // ------------------------------------------------------------------
    // Fuzz: conservation and exactness
    // ------------------------------------------------------------------

    function testFuzz_transferIsExact(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != DEPLOYER);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(DEPLOYER), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientBalance.selector, DEPLOYER, SUPPLY, amount));
        vm.prank(DEPLOYER);
        token.transfer(ALICE, amount);
    }

    function testFuzz_transferFromIsExactAndSpendsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, allowed);
        vm.prank(DEPLOYER);
        token.approve(ALICE, allowed);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(DEPLOYER, BOB, amount));
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.allowance(DEPLOYER, ALICE), allowed - amount);
    }

    /// @dev A random walk of transfers among four accounts never changes the sum of balances.
    function testFuzz_supplyIsConserved(uint8[16] memory fromIdx, uint8[16] memory toIdx, uint64[16] memory amounts)
        public
    {
        address[4] memory accounts = [DEPLOYER, ALICE, BOB, CAROL];
        for (uint256 i; i < 16; ++i) {
            address from = accounts[fromIdx[i] % 4];
            address to = accounts[toIdx[i] % 4];
            uint256 amount = uint256(amounts[i]) * 1e12;
            uint256 have = token.balanceOf(from);
            vm.prank(from);
            if (amount > have) {
                vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientBalance.selector, from, have, amount));
                token.transfer(to, amount);
            } else {
                assertTrue(token.transfer(to, amount));
            }
        }
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(accounts[i]);
        }
        assertEq(sum, SUPPLY, "supply was not conserved");
        assertEq(token.totalSupply(), SUPPLY);
    }
}
