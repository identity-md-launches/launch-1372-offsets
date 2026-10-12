// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OffsetsToken} from "../src/OffsetsToken.sol";

/// @notice Edge cases and failure paths the behaviour suite in OffsetsToken.t.sol does not pin down:
///         the zero address on every side of every call, allowances one below infinite, the owner
///         spending from itself, the token as a recipient, return data shape, ether with calldata,
///         unknown selectors, and property tests over the arithmetic at its bounds.
/// forge-config: default.fuzz.runs = 1000
contract OffsetsTokenEdgesTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant MAX = type(uint256).max;

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
    // The zero address, on every side of every call
    // ------------------------------------------------------------------

    /// @dev The zero check comes before the balance check: a zero sender is refused as ZeroAddress,
    ///      not as InsufficientBalance, and a zero recipient is refused even for a zero amount.
    function test_RevertWhen_zeroAddressSends() public {
        vm.expectRevert(OffsetsToken.ZeroAddress.selector);
        vm.prank(address(0));
        token.transfer(ALICE, 0);
    }

    function test_RevertWhen_transferZeroAmountToZeroAddress() public {
        vm.expectRevert(OffsetsToken.ZeroAddress.selector);
        vm.prank(DEPLOYER);
        token.transfer(address(0), 0);
    }

    function test_RevertWhen_zeroAddressApproves() public {
        vm.expectRevert(OffsetsToken.ZeroAddress.selector);
        vm.prank(address(0));
        token.approve(ALICE, 1);
        assertEq(token.allowance(address(0), ALICE), 0);
    }

    /// @dev Zero amount passes the allowance check for any owner, so the zero-owner guard must be
    ///      what stops a transferFrom out of the zero address.
    function test_RevertWhen_transferFromZeroAddressOwnerEvenForZeroAmount() public {
        vm.expectRevert(OffsetsToken.ZeroAddress.selector);
        vm.prank(ALICE);
        token.transferFrom(address(0), BOB, 0);
        assertEq(token.allowance(address(0), ALICE), 0, "a reverted call left an allowance behind");
    }

    function test_RevertWhen_transferFromZeroAddressOwnerWithAmountIsRefusedForAllowanceFirst() public {
        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientAllowance.selector, address(0), ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(0), BOB, 1);
    }

    function test_RevertWhen_transferFromZeroAmountToZeroAddress() public {
        vm.expectRevert(OffsetsToken.ZeroAddress.selector);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, address(0), 0);
    }

    // ------------------------------------------------------------------
    // Allowances at the edges
    // ------------------------------------------------------------------

    /// @dev Only exactly type(uint256).max is infinite. One below it is an ordinary allowance and is spent.
    function test_allowanceOneBelowMaxIsDecremented() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, MAX - 1);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 1);
        assertEq(token.allowance(DEPLOYER, ALICE), MAX - 2);
    }

    /// @dev On an infinite allowance there is nothing to decrement, so no Approval is emitted.
    ///      On a finite one, exactly one Approval with the remainder precedes the Transfer.
    function test_transferFromOnInfiniteAllowanceEmitsNoApproval() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, MAX);

        vm.recordLogs();
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 5e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "expected only the Transfer event");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), DEPLOYER);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), BOB);
        assertEq(abi.decode(logs[0].data, (uint256)), 5e18);
    }

    function test_transferFromOnFiniteAllowanceEmitsApprovalThenTransfer() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 9e18);

        vm.recordLogs();
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 4e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 2, "expected Approval then Transfer");
        assertEq(logs[0].topics[0], keccak256("Approval(address,address,uint256)"));
        assertEq(abi.decode(logs[0].data, (uint256)), 5e18, "Approval must carry the remaining allowance");
        assertEq(logs[1].topics[0], keccak256("Transfer(address,address,uint256)"));
    }

    /// @dev A zero-amount transferFrom needs no allowance, moves nothing, and still emits both events.
    function test_transferFromZeroAmountWithoutAllowanceSucceeds() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(DEPLOYER, ALICE, 0);
        vm.expectEmit(true, true, true, true);
        emit Transfer(DEPLOYER, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 0));
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
    }

    /// @dev There is no owner-as-spender shortcut: the owner must approve itself to call transferFrom
    ///      on its own balance. A plain transfer is the path for that; this pins the actual behaviour.
    function test_RevertWhen_ownerCallsTransferFromOnItselfWithoutSelfApproval() public {
        vm.expectRevert(
            abi.encodeWithSelector(OffsetsToken.InsufficientAllowance.selector, DEPLOYER, DEPLOYER, 0, 1e18)
        );
        vm.prank(DEPLOYER);
        token.transferFrom(DEPLOYER, ALICE, 1e18);
    }

    function test_ownerCanTransferFromItselfAfterSelfApproval() public {
        vm.startPrank(DEPLOYER);
        token.approve(DEPLOYER, 3e18);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, 2e18));
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 2e18);
        assertEq(token.allowance(DEPLOYER, DEPLOYER), 1e18);
    }

    /// @dev from == to through transferFrom: the balance is unchanged but the allowance is still spent.
    function test_transferFromToOwnerItselfSpendsAllowanceOnly() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 10e18);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(DEPLOYER, DEPLOYER, 6e18));
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.allowance(DEPLOYER, ALICE), 4e18);
    }

    /// @dev Approving does not check or reserve balance, and later transfers do not shrink allowances:
    ///      an allowance can exceed what the owner holds, and then transferFrom fails on balance.
    function test_RevertWhen_allowanceOutlivesBalance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(BOB, SUPPLY - 1);
        assertEq(token.allowance(DEPLOYER, ALICE), SUPPLY, "a plain transfer changed an allowance");

        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientBalance.selector, DEPLOYER, 1, 2));
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, CAROL, 2);

        vm.prank(ALICE);
        assertTrue(token.transferFrom(DEPLOYER, CAROL, 1));
        assertEq(token.balanceOf(CAROL), 1);
        assertEq(token.allowance(DEPLOYER, ALICE), SUPPLY - 1);
    }

    /// @dev The allowance is checked before the balance, so the error names the allowance even when
    ///      the owner could not have paid either.
    function test_RevertWhen_bothAllowanceAndBalanceAreShortAllowanceIsReportedFirst() public {
        vm.prank(CAROL);
        token.approve(ALICE, 1);
        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientAllowance.selector, CAROL, ALICE, 1, 2));
        vm.prank(ALICE);
        token.transferFrom(CAROL, BOB, 2);
    }

    // ------------------------------------------------------------------
    // The token contract as a counterparty
    // ------------------------------------------------------------------

    /// @dev Tokens sent to the token itself are accepted and then stuck: nothing can move them out,
    ///      which the README documents. Pinned so a later "rescue" function cannot appear unnoticed.
    function test_tokensSentToTheContractAreStuck() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(address(token), 7e18));
        assertEq(token.balanceOf(address(token)), 7e18);

        // The contract cannot be made to transfer or approve: there is no path by which it is msg.sender.
        vm.prank(DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(OffsetsToken.InsufficientAllowance.selector, address(token), DEPLOYER, 0, 1)
        );
        token.transferFrom(address(token), DEPLOYER, 1);

        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", DEPLOYER, 7e18));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("recoverERC20(address,uint256)", address(token), 7e18));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("sweep(address)", DEPLOYER));
        assertFalse(ok);
        assertEq(token.balanceOf(address(token)), 7e18);
    }

    // ------------------------------------------------------------------
    // ABI surface: return data, ether, selectors, calldata
    // ------------------------------------------------------------------

    /// @dev Integrators that check return data (SafeERC20 and the like) need exactly one word, true.
    function test_mutatorsReturnExactlyOneTrueWord() public {
        vm.prank(DEPLOYER);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(token.transfer, (ALICE, 1e18)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertTrue(abi.decode(ret, (bool)));

        vm.prank(DEPLOYER);
        (ok, ret) = address(token).call(abi.encodeCall(token.approve, (ALICE, 1e18)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertTrue(abi.decode(ret, (bool)));

        vm.prank(ALICE);
        (ok, ret) = address(token).call(abi.encodeCall(token.transferFrom, (DEPLOYER, BOB, 1e18)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertTrue(abi.decode(ret, (bool)));
    }

    /// @dev Every function is non-payable: ether attached to a valid call is refused and the call
    ///      has no effect, not even the transfer it asked for.
    function test_RevertWhen_etherAttachedToValidCall() public {
        vm.deal(DEPLOYER, 1 ether);
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call{value: 1 wei}(abi.encodeCall(token.transfer, (ALICE, 1e18)));
        assertFalse(ok, "a non-payable function accepted ether");
        assertEq(token.balanceOf(ALICE), 0, "the call took effect despite the revert");
        assertEq(address(token).balance, 0);

        vm.prank(DEPLOYER);
        (ok,) = address(token).call{value: 1 wei}(abi.encodeCall(token.approve, (ALICE, 1e18)));
        assertFalse(ok);
        assertEq(token.allowance(DEPLOYER, ALICE), 0);

        vm.prank(DEPLOYER);
        (ok,) = address(token).call{value: 1 wei}(abi.encodeCall(token.balanceOf, (ALICE)));
        assertFalse(ok, "a view accepted ether");
    }

    function test_RevertWhen_calldataIsShorterThanASelector() public {
        (bool ok,) = address(token).call(hex"a9");
        assertFalse(ok);
        (ok,) = address(token).call(hex"a9059c");
        assertFalse(ok);
    }

    /// @dev Truncated arguments are refused by the ABI decoder rather than read as zero.
    function test_RevertWhen_transferCalldataIsTruncated() public {
        bytes memory full = abi.encodeCall(token.transfer, (ALICE, 1e18));
        bytes memory truncated = new bytes(full.length - 1);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = full[i];
        }
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call(truncated);
        assertFalse(ok, "a truncated transfer was accepted");
        assertEq(token.balanceOf(ALICE), 0);
    }

    /// @dev Metadata is `pure`: it is the same for every caller and costs no state.
    function test_metadataIsCallerIndependent() public {
        address[3] memory callers = [address(0), DEPLOYER, address(0xBEEF)];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            assertEq(token.name(), "Offsets");
            assertEq(token.symbol(), "OFFSETS");
            assertEq(token.decimals(), 18);
            assertEq(token.totalSupply(), SUPPLY);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------
    // Properties
    // ------------------------------------------------------------------

    /// @dev Whoever deploys gets the whole supply, for any deployer address.
    function testFuzz_supplyGoesToAnyDeployer(address deployer) public {
        deployer = _plausibleAddress(deployer);
        vm.prank(deployer);
        OffsetsToken other = new OffsetsToken();
        assertEq(other.balanceOf(deployer), SUPPLY);
        assertEq(other.totalSupply(), SUPPLY);
    }

    /// @dev An allowance is set to exactly the requested value for any owner, spender and amount,
    ///      including amounts far above the supply, and overwrites whatever was there.
    function testFuzz_approveSetsExactValueAndOverwrites(address owner, address spender, uint256 first, uint256 second)
        public
    {
        owner = _plausibleAddress(owner);
        spender = _plausibleAddress(spender);
        vm.startPrank(owner);
        assertTrue(token.approve(spender, first));
        assertEq(token.allowance(owner, spender), first);
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(owner, spender), second);
        vm.stopPrank();
        assertEq(token.balanceOf(owner), owner == DEPLOYER ? SUPPLY : 0, "approve moved tokens");
        assertEq(token.balanceOf(spender), spender == DEPLOYER ? SUPPLY : 0, "approve moved tokens");
    }

    /// @dev Every finite allowance is decremented by exactly the amount spent; only the maximum is not.
    function testFuzz_finiteAllowanceIsAlwaysDecremented(uint256 allowed, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        allowed = bound(allowed, amount, MAX - 1);
        vm.prank(DEPLOYER);
        token.approve(ALICE, allowed);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(DEPLOYER, BOB, amount));
        assertEq(token.allowance(DEPLOYER, ALICE), allowed - amount);
        assertEq(token.balanceOf(BOB), amount);
    }

    function testFuzz_infiniteAllowanceIsNeverDecremented(uint256 amount, uint8 times) public {
        amount = bound(amount, 0, SUPPLY / 256);
        vm.prank(DEPLOYER);
        token.approve(ALICE, MAX);
        for (uint256 i; i < times; ++i) {
            vm.prank(ALICE);
            token.transferFrom(DEPLOYER, BOB, amount);
        }
        assertEq(token.allowance(DEPLOYER, ALICE), MAX);
        assertEq(token.balanceOf(BOB), amount * times);
    }

    /// @dev One above any finite allowance is refused with the exact figures, and nothing moves.
    function testFuzz_transferFromAboveAllowanceReverts(uint256 allowed, uint256 excess) public {
        allowed = bound(allowed, 0, MAX - 2);
        excess = bound(excess, 1, MAX - 1 - allowed);
        uint256 amount = allowed + excess;
        vm.prank(DEPLOYER);
        token.approve(ALICE, allowed);

        vm.expectRevert(
            abi.encodeWithSelector(OffsetsToken.InsufficientAllowance.selector, DEPLOYER, ALICE, allowed, amount)
        );
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, amount);

        assertEq(token.allowance(DEPLOYER, ALICE), allowed);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
    }

    /// @dev Within the allowance but above the balance: refused for the balance, allowance untouched.
    function testFuzz_transferFromAboveBalanceRevertsAndKeepsAllowance(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(CAROL, held);
        vm.prank(CAROL);
        token.approve(ALICE, amount);

        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientBalance.selector, CAROL, held, amount));
        vm.prank(ALICE);
        token.transferFrom(CAROL, BOB, amount);

        assertEq(token.allowance(CAROL, ALICE), amount, "a reverted transferFrom spent allowance");
        assertEq(token.balanceOf(CAROL), held);
    }

    /// @dev Transfers are exactly additive: two transfers of x and y leave the same state as one of x + y.
    function testFuzz_transfersAreAdditive(uint256 x, uint256 y) public {
        x = bound(x, 0, SUPPLY);
        y = bound(y, 0, SUPPLY - x);
        vm.prank(DEPLOYER);
        OffsetsToken other = new OffsetsToken();

        vm.startPrank(DEPLOYER);
        token.transfer(ALICE, x);
        token.transfer(ALICE, y);
        other.transfer(ALICE, x + y);
        vm.stopPrank();

        assertEq(token.balanceOf(ALICE), other.balanceOf(ALICE));
        assertEq(token.balanceOf(DEPLOYER), other.balanceOf(DEPLOYER));
        assertEq(token.balanceOf(ALICE), x + y);
    }

    /// @dev A transfer there and back restores both balances exactly, for any amount up to the supply.
    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(DEPLOYER, amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    /// @dev Self-transfer of anything the holder has is a no-op on balance; one more is refused.
    function testFuzz_selfTransferIsNoOpUpToBalance(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);

        amount = bound(amount, 0, held);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), held);

        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientBalance.selector, ALICE, held, held + 1));
        vm.prank(ALICE);
        token.transfer(ALICE, held + 1);
        assertEq(token.balanceOf(ALICE), held);
    }

    /// @dev An account that holds nothing can send exactly zero and nothing else.
    function testFuzz_emptyAccountCanOnlySendZero(address who, address to, uint256 amount) public {
        who = _plausibleAddress(who);
        to = _plausibleAddress(to);
        vm.assume(who != DEPLOYER);
        amount = bound(amount, 1, MAX);

        vm.prank(who);
        assertTrue(token.transfer(to, 0));

        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientBalance.selector, who, 0, amount));
        vm.prank(who);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), to == DEPLOYER ? SUPPLY : 0);
    }

    /// @dev A transfer of a holder's whole balance is exact: zero left, every unit on the other side,
    ///      and the same holds when the recipient already has a balance (no overflow in the unchecked add).
    function testFuzz_wholeBalanceTransferIsExact(uint256 split) public {
        split = bound(split, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, split);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY - split);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), 0);
        vm.prank(ALICE);
        token.transfer(DEPLOYER, SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    /// @dev Any selector outside the token's ABI reverts, for any arguments and any caller.
    function testFuzz_unknownSelectorReverts(bytes4 selector, bytes memory args, address caller) public {
        vm.assume(!_isKnownSelector(selector));
        caller = _plausibleAddress(caller);
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok, "the token answered an unknown selector");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Keeps fuzzed addresses away from the zero address, precompiles and the test tooling,
    ///      which would turn a token test into a test of the harness. Uses bound, not assume.
    function _plausibleAddress(address a) internal pure returns (address) {
        uint256 n = bound(uint256(uint160(a)), 0x10000, type(uint160).max);
        address out = address(uint160(n));
        if (out == VM_ADDRESS || out == CONSOLE || out == DEFAULT_SENDER || out == DEFAULT_TEST_CONTRACT) {
            out = address(uint160(n) ^ 1);
        }
        return out;
    }

    function _isKnownSelector(bytes4 selector) internal pure returns (bool) {
        return selector == OffsetsToken.name.selector || selector == OffsetsToken.symbol.selector
            || selector == OffsetsToken.decimals.selector || selector == OffsetsToken.totalSupply.selector
            || selector == OffsetsToken.balanceOf.selector || selector == OffsetsToken.allowance.selector
            || selector == OffsetsToken.transfer.selector || selector == OffsetsToken.approve.selector
            || selector == OffsetsToken.transferFrom.selector || selector == bytes4(keccak256("TOTAL_SUPPLY()"))
            || selector == bytes4(keccak256("SUPPLY_WHOLE_TOKENS()"));
    }
}
