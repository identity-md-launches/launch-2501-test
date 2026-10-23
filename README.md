# TEST launch: Uniswap v4 ETH-fee hook

A Uniswap v4 hook for the TEST launch pool (native ETH / TEST) on Ethereum mainnet. Every swap pays a fee in
ETH that is forwarded, inside the swap, to two fixed recipients that fund research jobs.

The launch deploys two contracts, both in `src/`:

| Contract      | File                  | Role                                                                 |
| ------------- | --------------------- | -------------------------------------------------------------------- |
| `LaunchToken` | `src/LaunchToken.sol` | Fixed-supply ERC-20 "TEST"/"TEST", 18 decimals, 1,000,000,000 tokens |
| `LaunchHook`  | `src/LaunchHook.sol`  | The fee hook, bound to the one ETH/TEST pool                         |

`src/HookFlags.sol` is a small helper library (address-bit arithmetic) used by the deploy helper and tests.

## Fee schedule

All rates are in basis points (bps, 1/10,000) of the swap's **gross ETH amount** (defined below).

| Swap                                     | Fee                                                   |
| ---------------------------------------- | ----------------------------------------------------- |
| Buy (ETH in, TEST out), t < 3600 s       | Linear decay from `launchFeeBps` (30%) to `baseFeeBps` (2%) |
| Buy, t ≥ 3600 s                          | `baseFeeBps` (2%)                                     |
| Sell (TEST in, ETH out), at any time     | `baseFeeBps` (2%)                                     |

`t` is seconds since the pool was initialized; `afterInitialize` records `block.timestamp` once. At t = 1800
the buy fee is 16%: `3000 - (3000 - 200) * 1800 / 3600 = 1600` bps.

Split of each fee: `DEV_SHARE_BPS` = 50 bps (0.5%) of the gross ETH goes to the dev wallet; everything else
(1.5% plus any launch premium above 2%) goes to the research vault.

### Gross ETH amount

The fee is always charged in ETH, for both directions and for exact-input and exact-output swaps. The rate
applies to the ETH leg *before* the hook's cut, so no swap type gets a lower effective rate:

| Swap type        | ETH is…              | Taken in     | Gross = …                                   |
| ---------------- | -------------------- | ------------ | ------------------------------------------- |
| Exact-input buy  | specified (input)    | `beforeSwap` | the ETH the swapper pays                    |
| Exact-output buy | unspecified (input)  | `afterSwap`  | pool ETH / (1 − rate): swapper pays gross   |
| Exact-input sell | unspecified (output) | `afterSwap`  | the ETH the pool pays out                   |
| Exact-output sell| specified (output)   | `beforeSwap` | net ETH / (1 − rate): pool pays out gross   |

`beforeSwap` uses `beforeSwapReturnDelta` when ETH is the specified currency and leaves the rate and the fee it
took in **transient storage** (EIP-1153, `tstore`/`tload`) for `afterSwap`, which pays out. `afterSwap` uses
`afterSwapReturnDelta` when ETH is the unspecified currency. The LP fee of the pool itself (1.25%, the launch
policy's tier) is separate and untouched; the hook returns no LP fee override.

### Partial fills

A v4 swap stops early, without reverting, when it reaches `sqrtPriceLimitX96` or when the pool runs out of
the output currency (this pool holds only the ETH buyers have paid in, so an exact-output sell can ask for
more than it has). The fee must never exceed the rate on the ETH actually swapped, so:

| Swap type                           | Partial fill                                                        |
| ----------------------------------- | ------------------------------------------------------------------- |
| Exact-output buy, exact-input sell  | Allowed. The fee is sized in `afterSwap` from the executed ETH leg. |
| Exact-input buy, exact-output sell  | **Reverts** with `PartialFill(assumed, executed)`.                  |

For the second row the fee was sized in `beforeSwap` from the requested amount, and v4 gives the hook no way
to resize the specified (ETH) delta in `afterSwap`. Refunding the excess to the swapper's router would strand
it in a router that has no sweep step, so the hook refuses the fill instead: `afterSwap` compares the pool's
executed ETH (`delta.amount0()`) with the amount `beforeSwap` assumed and reverts on any difference. The whole
swap is undone; nobody pays anything. Routers that use the extreme price limit (the usual case, with slippage
checked on the output amount) are unaffected; a trader who wants a price-limited partial fill uses an
exact-output buy or an exact-input sell.

## Payout

Inside each swap the hook takes the fee ETH from the PoolManager (`take`) and pushes the dev and vault shares
with a bounded-gas call (`PAYOUT_GAS` = 100,000, enough for any ordinary `receive`).

- **A recipient that rejects ETH** (reverting `receive`, or one that needs more gas) does not block the swap:
  its share is credited in `owed[recipient]` and stays in the hook. The recipient pulls it later with
  `withdraw(address to)`, which forwards all gas and pays the caller's credit to `to`. Anyone may instead call
  `withdrawFor(address recipient)`, which pays the recipient's whole credit to the recipient itself with all
  gas, so a vault contract that has no way to call `withdraw` (or whose `receive` needs more than
  `PAYOUT_GAS`) is never stuck. Only the recipient can redirect its credit; the owner has no access to it.
- **A PoolManager that holds less ETH than the fee** (a fresh pool seeded with tokens only, before the first
  buyer's ETH is settled) cannot pay the hook during `afterSwap`. The hook then mints itself an ERC-6909 ETH
  claim for the fee and credits both recipients. Anyone may call `redeemClaims()` to burn the claims, take the
  ETH and push what is owed; `withdraw` also redeems claims on demand. On mainnet the PoolManager holds ETH from
  other pools, so this path is only expected on an empty manager, as tested in `LaunchHookFreshManagerTest`.

The hook never keeps ETH for itself. Its balance always equals the sum of credits not yet pulled (minus any
claims not yet redeemed). `receive()` only accepts ETH from the PoolManager so nothing can get stuck.

## Admin powers (owner = `0x5Cf44fb6a49156125b5f9Dfea73E4011534C7944`)

| Function                       | Rule                                                                   |
| ------------------------------ | ---------------------------------------------------------------------- |
| `setLaunchFee(uint16 bps)`     | Only lower: `bps <= launchFeeBps` and `bps >= baseFeeBps`              |
| `setBaseFee(uint16 bps)`       | Only lower: `bps <= baseFeeBps` and `bps >= DEV_SHARE_BPS` (50)        |
| `transferOwnership(address)`   | OpenZeppelin `Ownable`                                                 |
| `renounceOwnership()`          | Freezes the fee schedule for good                                      |

The 30% launch cap (`MAX_LAUNCH_FEE_BPS`) and the 2% base cap (`MAX_BASE_FEE_BPS`) are hardcoded starting
values; every change is monotonic downward, so the owner can never raise a fee back. There is no function
that moves pool liquidity, mints tokens, pauses swaps, changes recipients, changes the dev share, or
withdraws ETH owed to a recipient. The hook has no remove-liquidity callbacks, so the launch factory's fee
collection (a zero-liquidity modify) always goes through.

## Pool binding

The hook serves exactly one pool. `afterInitialize` (caller must be the PoolManager) accepts the pool only if
`currency0` is native ETH and `currency1` is the launch token given at construction, records the launch
timestamp and reverts with `AlreadyInitialized` on any later initialization. Any listed LP fee and tick
spacing is accepted, so the factory's 12500 / 60 pool opens. All other callbacks revert
`HookNotImplemented`; every enabled callback reverts `NotPoolManager` for any caller but the PoolManager.

Hook permissions (address bits `0x10CC`):

```json
{
  "hook": "BaseHook",
  "name": "LaunchHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": true,
  "shares": {"options": false},
  "permissions": {
    "beforeInitialize": false, "afterInitialize": true,
    "beforeAddLiquidity": false, "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false, "afterRemoveLiquidity": false,
    "beforeSwap": true, "afterSwap": true,
    "beforeDonate": false, "afterDonate": false,
    "beforeSwapReturnDelta": true, "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false, "afterRemoveLiquidityReturnDelta": false
  },
  "access": "ownable",
  "info": {"license": "MIT"}
}
```

`afterInitialize` is required by the launch (the factory deploys the hook and opens the pool in one
transaction). `beforeSwap`/`afterSwap` with both return-delta flags are what charging the fee in ETH for all
four swap types needs. The hook does not inherit v4-periphery's `BaseHook`; it implements `IHooks` directly
and validates its own address bits in the constructor with `Hooks.validateHookPermissions`.

## Deployment parameters

The IMD launch factory deploys both contracts from their bytecode as built. `LaunchToken` takes no
constructor arguments. `LaunchHook` takes five:

| Argument         | Value                                        | Manifest       |
| ---------------- | -------------------------------------------- | -------------- |
| `poolManager_`   | the chain's Uniswap v4 PoolManager           | `$poolManager` |
| `token_`         | the launch token                             | `$token`       |
| `owner_`         | `0x5Cf44fb6a49156125b5f9Dfea73E4011534C7944` | `$owner`       |
| `researchVault_` | `0x087C0CF0A103acA2c487c5017DbC121ad6C5afEE` | fixed          |
| `devWallet_`     | `0x5Cf44fb6a49156125b5f9Dfea73E4011534C7944` | fixed          |

The hook's address must carry the flags `0x10CC`; `script/Deploy.s.sol` (`LaunchParams.mineSalt`) shows how
a salt is mined and `DeployLaunchHook.deploy` rehearses a CREATE2 deployment with these constants. That script
is a rehearsal and parameter record; the production deployment is the factory's. Pool terms decided by the
launch: chain id 1, pair native ETH, LP fee 12500, tick spacing 60; the deployer sets the opening price.
Liquidity is single-sided: the factory supplies tokens only (a range below the opening price), buyers bring
the ETH. The test fixture seeds the pool the same way and asserts the seed needs no ETH.

Build settings (`foundry.toml`): solc 0.8.26, EVM `cancun` (transient storage), optimizer 200 runs,
`bytecode_hash = "none"`, no `ffi`, no filesystem permissions.

## Operational responsibilities

- **Owner**: may lower fees; should consider renouncing once the schedule is final. Nothing else to run.
- **Recipients**: if a push ever fails (event `PayoutCredited`), call `withdraw(to)` from the recipient
  address, or have anyone call `withdrawFor(recipient)`. The research vault is a contract with a payable
  `receive` (about 23k gas on mainnet), so pushes succeed and neither call should be needed.
- **Traders and front-ends**: an exact-input buy or exact-output sell with a price limit the swap reaches
  reverts with `PartialFill`. Use the extreme price limit with output-amount slippage, or the other swap type.
- **Anyone**: if `pendingClaims()` is non-zero (event `FeeDeferredAsClaim`, only expected on a PoolManager with
  no ETH), call `redeemClaims()`.
- **Monitoring**: `FeeCharged`, `PaidOut`, `PayoutCredited`, `FeeDeferredAsClaim`, `ClaimsRedeemed`,
  `LaunchFeeLowered`, `BaseFeeLowered`.

## Assumptions and deviations from the brief

- **Mainnet fork**: the brief asks for fork tests against the real PoolManager. The verifier runs offline with
  an empty environment, so the tests instead deploy the real PoolManager *code* from `lib/v4-core` locally and
  run every scenario against it. Behaviour is identical to the mainnet contract; the only difference is that
  the manager's ETH reserve is simulated (`vm.deal`) in the funded fixture and absent in the fresh one.
- **Fee base**: "0.5% of the swap's ETH amount" is read as 0.5% of the gross ETH leg as defined above, so the
  dev share is the same fraction on every swap type.
- **Dev share fixed**: the 0.5% dev share is a constant; only the two fees are owner-lowerable.
- **Bounded-gas pushes**: the security reference says never to hardcode gas limits. Here a bound is deliberate:
  a slow or malicious recipient could otherwise make every swap expensive, and the failure path (credit and
  pull with full gas) makes the bound harmless to an honest recipient.
- **Token**: the standard launch token, nothing else. Fees live in the hook, as the launch requires.
- **Pool-side ETH check**: `address(poolManager).balance >= fee` decides between direct payout and a claim.
  On mainnet this is always true in practice.

## Tests

```
forge build
forge test
forge fmt --check
```

67 tests in `test/`: exact-input and exact-output buys and sells with exact fee and split assertions; the fee
at t = 0, 900, 1800, 3599, 3600 and later; partial fills (price-limited and ETH-exhausted: refused for
exact-input buys and exact-output sells, charged on the executed amount for the other two types); a rejecting
and a gas-hungry recipient that do not block swaps and pull their credit, and `withdrawFor` delivering it from
any caller; the fresh-manager claim path and its redemption; owner fee limits (never raise, never below
the dev share, launch never below base), non-owner rejection, transfer and renounce; pool binding (second
initialization, wrong token, no ETH); callback access control; constructor and flag validation; the token's
supply, metadata and transfers; and the deploy helper. Fuzz tests cover ETH conservation on buys and sells and
the monotonic decay. Run with `FOUNDRY_FUZZ_SEED=0xe3a9b9d12858e84405e0db3c73b1df9b95429a90f9fe8213b83928a5fa7c8d87`
to reproduce the verifier's fuzz inputs.

Tests passing is not an audit. The hook holds fee ETH in flight and uses both swap return deltas; an
independent adversarial review is advised before launch.

## Dependencies

Vendored as plain files under `lib/` (no submodules): `forge-std`, `v4-core` (Uniswap, `src/` only),
`openzeppelin-contracts` v5.4.0 (`contracts/` only) and `solmate` (needed by v4-core's `ProtocolFees`).
