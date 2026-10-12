// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Offsets (OFFSETS)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 OFFSETS (18 decimals)
///         is minted once, in the constructor, to the deployer (`msg.sender`). There is no owner,
///         no minter, no pause, no blocklist and no fee on transfer: after construction the
///         contract has no privileged functions at all, and the supply can never grow.
/// @dev Self-contained on purpose: no external library, no delegatecall, no upgradeability.
///      Every state transition is one of the four ERC-20 moves (transfer, transferFrom, approve,
///      and allowance consumption), implemented exactly as EIP-20 specifies.
contract OffsetsToken {
    // ------------------------------------------------------------------
    // Token constants
    // ------------------------------------------------------------------

    /// @notice Number of whole tokens in the supply, before the decimals scale.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice Fixed total supply in minor units: 1,000,000,000 * 10**18.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** DECIMALS;

    uint8 private constant DECIMALS = 18;
    string private constant NAME = "Offsets";
    string private constant SYMBOL = "OFFSETS";

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    /// @notice `from` tried to move more than it holds.
    error InsufficientBalance(address from, uint256 balance, uint256 needed);
    /// @notice `spender` tried to spend more of `owner`'s balance than `owner` allowed.
    error InsufficientAllowance(address owner, address spender, uint256 allowance, uint256 needed);
    /// @notice The zero address may not send, receive, approve or be approved.
    error ZeroAddress();

    // ------------------------------------------------------------------
    // Events (EIP-20)
    // ------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    /// @notice Mints the entire fixed supply to the deployer. Nothing else is ever minted.
    /// @dev The deployer is `msg.sender`: at launch this is the ProjectFactory, which pays the
    ///      supply out (swarm share, pool seed, remainder). The constructor takes no arguments and
    ///      makes no external calls, so it deploys on an empty chain.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ------------------------------------------------------------------
    // ERC-20 metadata
    // ------------------------------------------------------------------

    /// @notice The token's name, "Offsets".
    function name() external pure returns (string memory) {
        return NAME;
    }

    /// @notice The token's symbol, "OFFSETS".
    function symbol() external pure returns (string memory) {
        return SYMBOL;
    }

    /// @notice 18, so one OFFSETS is 10**18 minor units.
    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    // ------------------------------------------------------------------
    // ERC-20 views
    // ------------------------------------------------------------------

    /// @notice The fixed supply. It is a constant: nothing can change it after deployment.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @notice The balance held by `account`.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice How much `spender` may still move out of `owner`'s balance.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ------------------------------------------------------------------
    // ERC-20 actions
    // ------------------------------------------------------------------

    /// @notice Moves `amount` from the caller to `to`. Reverts rather than returning false.
    /// @dev No fee, no burn, no exemption list: `to` always receives exactly `amount`.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to exactly `amount`.
    /// @dev Standard EIP-20 semantics. Callers that want to change a non-zero allowance safely
    ///      should set it to zero first, or use the amount they intend as the final value.
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves `amount` from `from` to `to` using the caller's allowance from `from`.
    /// @dev An allowance of `type(uint256).max` is treated as infinite and is not decremented.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // fromBalance >= amount was just checked, and the sum of all balances is the constant
            // TOTAL_SUPPLY, so the recipient's balance cannot overflow.
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (owner == address(0) || spender == address(0)) revert ZeroAddress();
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(owner, spender, current, amount);
        unchecked {
            _allowances[owner][spender] = current - amount;
        }
        emit Approval(owner, spender, current - amount);
    }
}
