# Offsets (OFFSETS)

A plain, fixed-supply ERC-20 token for an IdentityMD custom-token launch on Ethereum.

| Property | Value |
| --- | --- |
| Solidity contract | `OffsetsToken` (`src/OffsetsToken.sol`) |
| Name | `Offsets` |
| Symbol | `OFFSETS` |
| Decimals | 18 |
| Total supply | 1,000,000,000 OFFSETS = `1000000000000000000000000000` minor units |
| Minting | Once, in the constructor, all of it to `msg.sender` (the deployer) |
| Constructor arguments | None |
| Owner / admin | None. There are no privileged functions. |
| Transfer rules | Standard EIP-20. No fee, no burn, no blocklist, no pause. |

## What the contract does

`OffsetsToken` implements EIP-20 and nothing else:

- `name()`, `symbol()`, `decimals()`, `totalSupply()`, `balanceOf()`, `allowance()`
- `transfer()`, `approve()`, `transferFrom()`
- `Transfer` and `Approval` events

The whole supply is written to the deployer's balance in the constructor and a `Transfer` from the
zero address is emitted. `totalSupply()` returns a compile-time constant, so the supply can never
grow or shrink: there is no `mint`, no `burn`, no owner, no upgrade path, no fallback and no
`receive`. Every selector the contract does not implement reverts, and ether sent to it is refused.

Failures revert with typed errors rather than returning `false`:

- `InsufficientBalance(from, balance, needed)`
- `InsufficientAllowance(owner, spender, allowance, needed)`
- `ZeroAddress()` for a zero `from`, `to`, `owner` or `spender`

An allowance of `type(uint256).max` is treated as unlimited and is not decremented, which is the
usual convention routers and pool managers rely on. `transferFrom` emits an `Approval` event with
the remaining allowance when it decrements one.

The contract is self-contained (no inherited library code), so there are no external library calls,
no link placeholders, no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in the runtime bytecode. The
test suite scans the bytecode for those opcodes the same way the launch floor does.

## Assumptions

- **The deployer is the factory.** At launch, IdentityMD's ProjectFactory deploys the token through
  CREATE2 and is therefore `msg.sender` in the constructor. It receives the entire supply and pays
  it out: 10% to the launch's MerkleDistributor, 80% to seed the Uniswap v4 pool, and the remaining
  10% to the requester's `economics.remainderTo` address. The token does not know or care about
  any of those addresses because it treats every transfer identically.
- **No address is special.** Because there is no tax or exemption list, the factory, the pool
  manager, the distributor and every later holder all move exactly the amount they send. The
  constructor takes no `$factory`, `$poolManager` or `$launchNumber` argument because it has no use
  for them.
- **The constructor makes no external calls**, so it deploys on an empty chain and has no
  dependency on any other contract existing first.
- **The supply figure is exact.** `TOTAL_SUPPLY = 1_000_000_000 * 10**18`. The manifest's
  `token.totalSupply` must be `1000000000000000000000000000`.

## Deployment parameters

The launch manifest (written by the manifest step, not by this repository) describes the token as:

| Field | Value |
| --- | --- |
| `token.contract` | `OffsetsToken` |
| `token.name` | `Offsets` |
| `token.symbol` | `OFFSETS` |
| `token.decimals` | `18` |
| `token.constructorArgs` | `[]` |
| `token.totalSupply` | `1000000000000000000000000000` |
| `contracts` | `[]` (no application contracts) |

Launch-decided values this repository does not control and does not need: chain id 1, pair token
IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, pool fee 12500, tick spacing 60, and the
requester's economics (`poolBps` 8000, `initialMarketCapWei` 2500 IMD, `remainderTo`
`0xff3e8d9ba776662ca6ed1420ee366afb436d2684`). They are listed here only so a reviewer can check
them against the manifest.

Build settings that matter for reproducibility are pinned in `foundry.toml`: `solc = "0.8.26"`,
`optimizer = true`, `optimizer_runs = 200`, `evm_version = "cancun"`, `bytecode_hash = "none"`,
`cbor_metadata = false`. The launch deploys the bytecode exactly as `forge build` produces it with
these settings.

### Manual deployment (testnet, or outside the launch)

`script/DeployOffsetsToken.s.sol` is a reference deploy script. Its `deploy()` function holds the
deployment logic and is what the tests call; `run()` only wraps it in a broadcast. Whichever sender
`forge script` is given receives the entire supply:

```sh
forge script script/DeployOffsetsToken.s.sol --rpc-url <RPC_URL> --account <KEYSTORE_ACCOUNT> --broadcast
```

This repository never holds keys and never broadcasts on its own.

## Operational responsibilities

There is nothing to configure after launch: no owner setter, no "After launch" settings, no
parameters to tune. The responsibilities that remain are:

- **The requester** controls `economics.remainderTo` and should treat that wallet as the holder of
  the 10% remainder. Lost keys cannot be recovered by the token.
- **The launch policy / deployer** verifies the source on the block explorer after deployment
  (`forge verify-contract` with the pinned settings above). Nothing in this repository does that.
- **Holders** are the only parties who can move their own balances. There is no recovery, freeze or
  clawback mechanism by design. Tokens sent to a wrong address or to the token contract itself are
  not recoverable.
- **Integrators** should note that failed transfers revert instead of returning `false`, and that
  `approve` has the standard EIP-20 race: set an allowance to zero before changing a non-zero one
  if the spender is not trusted.

## Trust and security notes

- No privileged roles exist, so there is no admin key to rotate, multisig to hand over, or pause to
  misuse.
- The contract is not upgradeable and uses no proxy.
- Arithmetic is checked except in two places where the preceding check makes overflow impossible
  (the balance decrement after the `fromBalance >= amount` check, and the recipient increment, which
  is bounded by the constant total supply).
- Tests passing is not an audit. A separate adversarial review by an independent contributor is
  expected before this handles other people's funds, as the launch policy requires.
- Tools run here: `forge build`, `forge test` (unit and fuzz, 256 runs per fuzz test), and
  `forge fmt --check`. Slither and Mythril were not run; neither is provided in this environment.

## Repository layout

```
foundry.toml                  compiler pins and build settings (solc 0.8.26, bytecode_hash none)
remappings.txt                forge-std/ -> lib/forge-std/src/
src/OffsetsToken.sol          the token
script/DeployOffsetsToken.s.sol  reference deploy script
test/OffsetsToken.t.sol       behaviour, failure, launch-flow and fuzz tests
test/DeployOffsetsToken.t.sol deploy-function and CREATE2 tests
lib/forge-std/                forge-std v1.9.7, vendored as ordinary files (MIT / Apache-2.0)
```

## Building and testing

```sh
forge build
forge test
forge fmt --check
```

The tests read no environment variables, do not depend on the calling address, and pass in any
order and in parallel.
