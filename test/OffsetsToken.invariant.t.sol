// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OffsetsToken} from "../src/OffsetsToken.sol";

/// @notice Drives OffsetsToken with bounded inputs from several actors and keeps ghost copies of
///         every balance and allowance it changed. Every handler asserts the postconditions of the
///         call it made (exact amounts, exact revert reasons, nothing else touched), so a wrong
///         result surfaces as a reverted handler call and the failing sequence is printed.
/// @dev Holders are the actors plus two sinks that never act: a stranger and the token itself.
///      Tokens sent to either are stuck but still count toward the sum, which is how the
///      conservation invariant catches a transfer that credits less than it debits.
contract OffsetsHandler is Test {
    OffsetsToken public immutable token;
    uint256 public immutable supply;

    address[] internal actors;
    address[] internal holders;

    mapping(address holder => uint256) public ghostBalance;
    mapping(address owner => mapping(address spender => uint256)) public ghostAllowance;

    // Call accounting: proof that each path was actually exercised.
    uint256 public transfers;
    uint256 public fullTransfers;
    uint256 public zeroTransfers;
    uint256 public selfTransfers;
    uint256 public transfersRefusedForBalance;
    uint256 public transfersRefusedForZeroAddress;
    uint256 public approvals;
    uint256 public infiniteApprovals;
    uint256 public approvalsRefusedForZeroSpender;
    uint256 public transferFroms;
    uint256 public infiniteTransferFroms;
    uint256 public transferFromsRefusedForAllowance;
    uint256 public transferFromsRefusedForBalance;
    uint256 public transferFromsRefusedForZeroAddress;
    uint256 public unknownSelectorsRefused;
    uint256 public etherRefused;

    constructor(OffsetsToken token_, address deployer, address[] memory otherActors, address stranger) {
        token = token_;
        supply = token_.totalSupply();
        actors.push(deployer);
        holders.push(deployer);
        for (uint256 i; i < otherActors.length; ++i) {
            actors.push(otherActors[i]);
            holders.push(otherActors[i]);
        }
        holders.push(stranger);
        holders.push(address(token_));
        ghostBalance[deployer] = supply;
    }

    /// @dev Spreads a slice of the deployer's supply over the other actors so that a random walk
    ///      starts from a state where everyone can send, not one where five of six holders are empty.
    ///      Goes through the checked `_transfer`, so the seeding itself is verified and in the ledger.
    ///      The fuzzer may also call it; when the deployer can no longer afford a slice it is a no-op.
    function seed() external {
        uint256 slice = supply / (actors.length * 4);
        for (uint256 i = 1; i < actors.length; ++i) {
            if (ghostBalance[actors[0]] < slice * i) return;
            _transfer(actors[0], actors[i], slice * i);
            transfers++;
        }
    }

    // ------------------------------------------------------------------
    // Views for the invariants
    // ------------------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function holderAt(uint256 i) external view returns (address) {
        return holders[i];
    }

    function sumOfGhostBalances() external view returns (uint256 sum) {
        for (uint256 i; i < holders.length; ++i) {
            sum += ghostBalance[holders[i]];
        }
    }

    function sumOfActualBalances() external view returns (uint256 sum) {
        for (uint256 i; i < holders.length; ++i) {
            sum += token.balanceOf(holders[i]);
        }
    }

    // ------------------------------------------------------------------
    // Clamped handlers: the happy paths, with exact postconditions
    // ------------------------------------------------------------------

    /// @dev A transfer of any amount the sender can afford, to any holder (including itself).
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        amount = _bound(amount, 0, ghostBalance[from]);
        _transfer(from, to, amount);
        transfers++;
        if (amount == 0) zeroTransfers++;
        if (from == to) selfTransfers++;
    }

    /// @dev The whole balance leaves in one call: the sender must land on exactly zero.
    function transferFull(uint256 fromSeed, uint256 toSeed) public {
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        uint256 amount = ghostBalance[from];
        _transfer(from, to, amount);
        fullTransfers++;
        if (from == to) selfTransfers++;
        require(token.balanceOf(from) == (from == to ? amount : 0), "full transfer left dust behind");
    }

    /// @dev Any allowance at all, including values far above the supply. Allowances are not balances.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        _approve(owner, spender, amount);
        approvals++;
    }

    function approveInfinite(uint256 ownerSeed, uint256 spenderSeed) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        _approve(owner, spender, type(uint256).max);
        infiniteApprovals++;
    }

    /// @dev A delegated transfer the owner can afford and the spender is allowed to make.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) public {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _holder(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 cap = allowed < ghostBalance[owner] ? allowed : ghostBalance[owner];
        amount = _bound(amount, 0, cap);
        _transferFrom(spender, owner, to, amount);
        transferFroms++;
        if (allowed == type(uint256).max) infiniteTransferFroms++;
        if (owner == to) selfTransfers++;
    }

    // ------------------------------------------------------------------
    // Failure-path handlers: the call must be refused with the exact error and change nothing
    // ------------------------------------------------------------------

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) public {
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        uint256 have = ghostBalance[from];
        excess = _bound(excess, 1, type(uint256).max - have);
        uint256 amount = have + excess;

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientBalance.selector, from, have, amount));
        token.transfer(to, amount);

        require(token.balanceOf(from) == have, "refused transfer changed the sender");
        require(token.balanceOf(to) == ghostBalance[to], "refused transfer changed the recipient");
        transfersRefusedForBalance++;
    }

    function transferToZeroAddress(uint256 fromSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        amount = _bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        vm.expectRevert(OffsetsToken.ZeroAddress.selector);
        token.transfer(address(0), amount);
        require(token.balanceOf(from) == ghostBalance[from], "refused transfer changed the sender");
        transfersRefusedForZeroAddress++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        vm.expectRevert(OffsetsToken.ZeroAddress.selector);
        token.approve(address(0), amount);
        approvalsRefusedForZeroSpender++;
    }

    /// @dev More than the allowance (when it is finite): refused for the allowance, before the balance
    ///      is even looked at, and the allowance is left as it was.
    function transferFromAboveAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess) public {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _holder(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed == type(uint256).max) {
            // Infinite allowance never refuses on allowance; cap it first so the path is reachable.
            allowed = _bound(excess, 0, supply);
            _approve(owner, spender, allowed);
        }
        excess = _bound(excess, 1, type(uint256).max - allowed);
        uint256 amount = allowed + excess;

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(OffsetsToken.InsufficientAllowance.selector, owner, spender, allowed, amount)
        );
        token.transferFrom(owner, to, amount);

        require(token.allowance(owner, spender) == allowed, "refused transferFrom spent allowance");
        require(token.balanceOf(owner) == ghostBalance[owner], "refused transferFrom moved the owner's balance");
        transferFromsRefusedForAllowance++;
    }

    /// @dev Within the allowance but above the owner's balance: refused for the balance, and because
    ///      the whole call reverts the allowance decrement is rolled back too.
    function transferFromAboveBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess) public {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _holder(toSeed);
        uint256 have = ghostBalance[owner];
        excess = _bound(excess, 1, supply);
        uint256 amount = have + excess;
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed < amount) {
            allowed = type(uint256).max;
            _approve(owner, spender, allowed);
        }

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(OffsetsToken.InsufficientBalance.selector, owner, have, amount));
        token.transferFrom(owner, to, amount);

        require(token.allowance(owner, spender) == allowed, "a reverted transferFrom still spent allowance");
        require(token.balanceOf(owner) == have, "refused transferFrom moved the owner's balance");
        transferFromsRefusedForBalance++;
    }

    function transferFromToZeroAddress(uint256 spenderSeed, uint256 ownerSeed, uint256 amount) public {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 cap = allowed < ghostBalance[owner] ? allowed : ghostBalance[owner];
        amount = _bound(amount, 0, cap);
        vm.prank(spender);
        vm.expectRevert(OffsetsToken.ZeroAddress.selector);
        token.transferFrom(owner, address(0), amount);
        require(token.allowance(owner, spender) == allowed, "a reverted transferFrom still spent allowance");
        transferFromsRefusedForZeroAddress++;
    }

    /// @dev Any selector the token does not implement must revert, whoever calls it and whatever
    ///      follows it. The known nine are skipped: this handler is about everything else.
    function callUnknownSelector(uint256 callerSeed, bytes4 selector, bytes memory tail) public {
        if (_isKnownSelector(selector)) return;
        vm.prank(_actor(callerSeed));
        (bool ok,) = address(token).call(abi.encodePacked(selector, tail));
        require(!ok, "the token answered an unknown selector");
        unknownSelectorsRefused++;
    }

    /// @dev The token has no receive or fallback and no payable function: ether is always refused.
    function sendEther(uint256 callerSeed, uint256 amount, bool withTransferCalldata) public {
        address caller = _actor(callerSeed);
        amount = _bound(amount, 1, 1_000 ether);
        vm.deal(caller, amount);
        bytes memory data = withTransferCalldata ? abi.encodeCall(token.transfer, (caller, 0)) : bytes("");
        vm.prank(caller);
        (bool ok,) = address(token).call{value: amount}(data);
        require(!ok, "the token accepted ether");
        require(address(token).balance == 0, "the token holds ether");
        etherRefused++;
    }

    // ------------------------------------------------------------------
    // Raw calls with postconditions and ghost updates
    // ------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        require(fromBefore == ghostBalance[from] && toBefore == ghostBalance[to], "ghost drifted before transfer");

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        require(ok, "transfer returned false");

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        require(token.balanceOf(from) == ghostBalance[from], "sender debited the wrong amount");
        require(token.balanceOf(to) == ghostBalance[to], "recipient credited the wrong amount");
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        require(ok, "approve returned false");
        ghostAllowance[owner][spender] = amount;
        require(token.allowance(owner, spender) == amount, "allowance not set to the exact amount");
    }

    function _transferFrom(address spender, address owner, address to, uint256 amount) internal {
        uint256 allowedBefore = token.allowance(owner, spender);
        require(allowedBefore == ghostAllowance[owner][spender], "ghost allowance drifted");
        uint256 spenderBefore = token.balanceOf(spender);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        require(ok, "transferFrom returned false");

        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        if (allowedBefore != type(uint256).max) {
            ghostAllowance[owner][spender] = allowedBefore - amount;
        }
        require(token.balanceOf(owner) == ghostBalance[owner], "owner debited the wrong amount");
        require(token.balanceOf(to) == ghostBalance[to], "recipient credited the wrong amount");
        require(token.allowance(owner, spender) == ghostAllowance[owner][spender], "allowance spent wrongly");
        if (spender != owner && spender != to) {
            require(token.balanceOf(spender) == spenderBefore, "the spender's own balance moved");
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _holder(uint256 seed) internal view returns (address) {
        return holders[seed % holders.length];
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

/// @notice Invariants over random sequences of the handler's calls.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract OffsetsTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant STRANGER = address(0x57A6E);

    OffsetsToken internal token;
    OffsetsHandler internal handler;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new OffsetsToken();

        address[] memory others = new address[](5);
        others[0] = address(0xA11CE);
        others[1] = address(0xB0B);
        others[2] = address(0xCA201);
        others[3] = address(0xDA7E);
        others[4] = address(uint160(uint256(keccak256("offsets.actor.contract"))));
        // One actor is a contract, not an EOA: the token must not care.
        vm.etch(others[4], hex"00");

        handler = new OffsetsHandler(token, DEPLOYER, others, STRANGER);
        handler.seed();
        assertEq(handler.sumOfActualBalances(), SUPPLY, "seeding lost tokens");
        assertGt(token.balanceOf(others[4]), 0, "seeding left an actor empty");

        targetContract(address(handler));
    }

    /// @dev The supply is a compile-time constant: no sequence of calls may move it.
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY, "the supply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// @dev Conservation: every unit minted is held by someone we know about, and by nobody else.
    function invariant_sumOfHolderBalancesEqualsSupply() public view {
        assertEq(handler.sumOfActualBalances(), SUPPLY, "balances do not add up to the supply");
        assertEq(handler.sumOfGhostBalances(), SUPPLY, "the ghost ledger does not add up (harness bug)");
    }

    /// @dev Internal accounting equals what we expected from the exact sequence of calls.
    function invariant_everyBalanceMatchesTheGhostLedger() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address holder = handler.holderAt(i);
            assertEq(token.balanceOf(holder), handler.ghostBalance(holder), "a balance drifted from the ledger");
            assertLe(token.balanceOf(holder), SUPPLY, "a holder has more than exists");
        }
    }

    function invariant_everyAllowanceMatchesTheGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actorAt(i);
                address spender = handler.actorAt(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "an allowance drifted from the ledger"
                );
            }
        }
    }

    /// @dev The zero address can neither receive nor be approved, so it never holds or may spend anything.
    function invariant_zeroAddressHoldsAndMaySpendNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            assertEq(token.allowance(handler.actorAt(i), address(0)), 0, "the zero address was approved");
            assertEq(token.allowance(address(0), handler.actorAt(i)), 0, "the zero address approved someone");
        }
    }

    /// @dev Approvals never move tokens: the deployer's supply only leaves through transfers it or an
    ///      approved spender made, and those are all in the ledger. Checked here as "nothing the
    ///      handler did not record ever left", which the ghost comparison above already enforces, plus
    ///      the token contract never acquires ether and never gains a way to spend what it was sent.
    function invariant_tokenContractHoldsNoEtherAndCannotSpendItsOwnBalance() public view {
        assertEq(address(token).balance, 0, "the token holds ether");
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            assertEq(token.allowance(address(token), handler.actorAt(i)), 0, "the token approved a spender");
        }
    }

    /// @dev Metadata is pure and cannot be changed by any sequence.
    function invariant_metadataIsFixed() public view {
        assertEq(token.name(), "Offsets");
        assertEq(token.symbol(), "OFFSETS");
        assertEq(token.decimals(), 18);
    }

    /// @dev Printed after each run so a reviewer can see every path was exercised, not just the happy one.
    function afterInvariant() public {
        uint256 total = handler.transfers() + handler.fullTransfers() + handler.approvals()
            + handler.infiniteApprovals() + handler.transferFroms() + handler.transfersRefusedForBalance()
            + handler.transfersRefusedForZeroAddress() + handler.approvalsRefusedForZeroSpender()
            + handler.transferFromsRefusedForAllowance() + handler.transferFromsRefusedForBalance()
            + handler.transferFromsRefusedForZeroAddress() + handler.unknownSelectorsRefused() + handler.etherRefused();
        assertGt(total, 0, "the handler was never called");
        emit log_named_uint("transfers", handler.transfers());
        emit log_named_uint("  of which zero-amount", handler.zeroTransfers());
        emit log_named_uint("  of which self", handler.selfTransfers());
        emit log_named_uint("full-balance transfers", handler.fullTransfers());
        emit log_named_uint("approvals", handler.approvals());
        emit log_named_uint("infinite approvals", handler.infiniteApprovals());
        emit log_named_uint("transferFroms", handler.transferFroms());
        emit log_named_uint("  of which on infinite allowance", handler.infiniteTransferFroms());
        emit log_named_uint("transfers refused: balance", handler.transfersRefusedForBalance());
        emit log_named_uint("transfers refused: zero address", handler.transfersRefusedForZeroAddress());
        emit log_named_uint("approvals refused: zero spender", handler.approvalsRefusedForZeroSpender());
        emit log_named_uint("transferFroms refused: allowance", handler.transferFromsRefusedForAllowance());
        emit log_named_uint("transferFroms refused: balance", handler.transferFromsRefusedForBalance());
        emit log_named_uint("transferFroms refused: zero address", handler.transferFromsRefusedForZeroAddress());
        emit log_named_uint("unknown selectors refused", handler.unknownSelectorsRefused());
        emit log_named_uint("ether refused", handler.etherRefused());
    }
}

/// @notice The token driven directly with unbounded calldata: whatever the fuzzer sends, from
///         whichever of the actors, the supply constant and the zero-address rule must survive.
///         Reverts are expected and allowed here; the point is what holds across them.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
contract OffsetsTokenOpenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    address internal constant DEPLOYER = address(0xFAC7);

    OffsetsToken internal token;
    address[] internal senders;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new OffsetsToken();

        senders.push(DEPLOYER);
        senders.push(address(0xA11CE));
        senders.push(address(0xB0B));
        senders.push(address(0xBEEF));
        for (uint256 i; i < senders.length; ++i) {
            targetSender(senders[i]);
        }
        targetContract(address(token));
    }

    function invariant_open_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY, "the supply changed");
    }

    function invariant_open_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
    }

    /// @dev The deployer was given the whole supply and nothing can create more, so no sender's
    ///      balance can exceed it, and the senders together cannot hold more than it.
    function invariant_open_noSenderExceedsSupply() public view {
        uint256 sum;
        for (uint256 i; i < senders.length; ++i) {
            uint256 b = token.balanceOf(senders[i]);
            assertLe(b, SUPPLY, "a sender holds more than the supply");
            sum += b;
        }
        assertLe(sum, SUPPLY, "the senders together hold more than the supply");
    }

    function invariant_open_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0);
    }
}
