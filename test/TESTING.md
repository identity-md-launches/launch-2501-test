# TEST launch test coverage

This addition preserves the accepted implementation and existing tests. New source lives only under
`test/`. The first round reported two implementation findings. The implementation has since fixed the
first (fees on unfilled ETH: ETH-specified partial fills now revert with `PartialFill`), and this revision
tests that fix on the live PoolManager and inside the invariant campaign. The second (same-transaction
payout on an ETH-less manager) is unchanged and is re-reported in `.imd-findings.json` at low severity.

| Deliverable | Coverage |
| --- | --- |
| `LaunchHookFork.t.sol` | Ethereum block **26255649**, real PoolManager and specified fixed recipients; all four swap types at t=0, 1800, 3600 and 86400; partial fills at t=0 and t=3600 (price-limited exact-input buy and exact-output sell, and an exact-output sell beyond the pool's ETH, all refused with nothing moved; price-limited exact-output buy and exact-input sell charged on executed ETH only); rejecting-recipient recovery through `withdraw` and through `withdrawFor` by a stranger; owner restrictions; LP collection and full removal after renunciation |
| `LaunchHookIntegration.t.sol` | Offline real v4 PoolManager; four-direction matrix at t=0, 1, 1800, 3599, 3600 and 86400; 1,000 exact-output fuzz cases; multiple swap types in one unlock; rollback of a failed swap's transient state; zero-amount rejection |
| `LaunchHookPayouts.t.sol` | Both recipients rejecting, independent credits, replayed/failed withdrawals, claim redemption rollback, withdrawal and payout reentrancy, 64 KiB return/revert data, 1,000 fee-split properties and explicit rounding edges |
| `LaunchHookInvariant.t.sol` | Three trading actors, extreme-limit and price-limited trades of all four types (partial fills and `PartialFill` refusals both occur), two switchable recipients, withdrawals, `withdrawFor` deliveries by an outsider, claims, time, fee reductions, rejected fee increases, ownership transfers/renunciation, unauthorized calls and forced ETH/token donations |
| `LaunchTokenInvariant.t.sol` | Four holders, transfers, self-transfers, finite/infinite approvals, delegated spending, unauthorized spending, overdraws and attempted supply changes |
| `support/HookScenario.sol`, `support/SwapProbe.sol`, `support/PartialFillRevert.sol` | Shared fixtures, real-manager event oracle, flash-accounting assertions, a router whose entire unlock/callback/settlement runs in one external transaction, and a decoder that accepts only the PoolManager-wrapped `LaunchHook.PartialFill` from `afterSwap` |

The existing 53 tests retain their constructor, permission, single-pool binding, metadata, supply,
deployment-parameter and administrative coverage.

## Properties and test choices

The worker selected a test opening price of `2^96`, tick spacing 60 and LP fee 12500, consistent with the
existing fixture. The fixture supplies token-only liquidity `5e26` in `[-887220, 0]` and explicitly checks
that no ETH is deposited during seeding. These are concrete test parameters, not requester-approved
launch economics or a market quotation. Traders receive test funds; the fork's live PoolManager and real
recipients are never etched or funded with `deal`. Only new local fixture contracts are deployed.

Fork setup reads `vm.envOr("MAINNET_RPC_URL", string(""))` and passes it unchanged to
`vm.createSelectFork(url, 26255649)`. It skips only if the variable is empty. Every configured fork must
have chain ID 1, the exact pinned height, PoolManager code and research-vault code. No RPC address or key
is stored in the source. The PoolManager address is verified against the
[official Uniswap deployment list](https://developers.uniswap.org/docs/protocols/v4/deployments):
`0x000000000004444c5dc75cB358380D2e3dE08A90`. Block number remains pinned while local time advances to test
the schedule. Fixed recipient/owner addresses are the brief's addresses.

The fee oracle reads the **PoolManager Swap event**, before the hook changes the trader delta. It compares
that AMM delta against actual trader, manager, vault and dev balance changes. It does not use the hook's
`FeeCharged` event or its `splitFee` view to decide whether a swap paid the right fee. The rational fee
relation permits less than one wei of integer rounding, while the dev share is checked exactly. Token
deltas must equal the AMM's token delta; neither the hook nor a recipient may collect a token swap fee.

Each invariant campaign has inline settings of 256 runs, depth 64, and `fail-on-revert = true`. Explicit
selector lists target only the handler actions. The swap probe checks transient deltas inside its
`unlockCallback`, before the top-level transaction can clear them. Expected rejection paths use specific revert assertions;
unexpected failures cannot silently count as successful exploration.

| Invariant / postcondition | Basis |
| --- | --- |
| Hook ETH + ERC-6909 claims = both outstanding credits + forced ETH donations | Exact backing identity; distinguishes donations from fee liabilities |
| Independently measured accrued share = recipient receipts + alternate-address withdrawals + remaining credit | Each recipient is entitled to its full fee share exactly once |
| Manager ETH = measured pool ETH + unredeemed hook claims | Claims must remain backed without double-counting pool funds |
| All tracked ETH and token balances are conserved | Closed actor set, with no minting or balance edits after setup |
| Total token supply remains `1_000_000_000 ether` | Fixed-supply launch token requirement |
| Fee settings and the current rate never increase; base stays at least 50 bps | Owner can only lower fees and cannot reduce the fixed dev fraction |
| Initialization timestamp and pool ID never change | Single-pool initialization requirement |
| Manager relocks and all hook/trader deltas settle to zero | v4 flash-accounting requirement |
| Every outstanding credit can be paid at the end of a sequence | `afterInvariant` enables recipient acceptance, redeems claims, and checks full payment |

The hook invariant starts with an actual buy on a manager with zero ETH, ensuring that the claim path and
nonzero debt are exercised. Every trade goes through one execution path: a successful swap is charged
against the ETH the AMM actually executed, an ETH-specified swap that succeeds must have filled fully, and
the only acceptable revert is the hook's `PartialFill` on an ETH-specified swap, with no ETH moved.
Measured pool ETH includes LP fees the swap cannot pay out, so an exact-output sell sized from it can meet
an exhausted pool; the hook correctly refuses it. An extreme-limit sell past the TEST-only range parks the
price at the top bound, where the PoolManager itself rejects further sells, so the handler buys instead. Donations are tracked explicitly, so forcing ETH through
`SELFDESTRUCT` does not make a solvency assertion falsely demand that unsolicited funds become fee debt.
The donation helper is test-only and intentionally produces Solidity's selfdestruct deprecation warning.

## Reported defects

1. **High — fees on unfilled ETH (fixed in the implementation).** The first round showed a partial
   exact-input buy and exact-output sell charging the fee on ETH that was never swapped. The hook now
   compares the pool's executed ETH with the amount it sized the fee for and reverts with `PartialFill`.
   The fork and invariant tests above exercise the fix.
2. **Low (was medium) — same-transaction payout gap on an empty manager.** A successful first 1 ETH buy with
   token-only liquidity pays neither accepting recipient; `0.3 ETH` remains an ERC-6909 claim until a
   later redemption. Existing mainnet ETH makes the tested funded path work. The implementation's
   documented fallback preserves value, but does not satisfy the brief's unconditional same-transaction
   payout requirement. Claim-accounting tests verify recoverability, not compliance with that timing. On
   the mainnet PoolManager at the pinned block the manager holds ample ETH and every fork swap pays out
   directly, so the gap only matters on a manager holding less ETH than one fee.

No implementation fix is included in this tests-only task.

## Reproduction

```sh
export FOUNDRY_FUZZ_SEED=0xe3a9b9d12858e84405e0db3c73b1df9b95429a90f9fe8213b83928a5fa7c8d87
forge build
forge test
```

With the supplied `MAINNET_RPC_URL`, the ten fork tests execute against the pinned chain state. Without
that variable, those tests skip and the offline suites still run. No test changes the process environment.
All dependencies already exist as ordinary vendored files; this contribution adds no dependency or
configuration changes. Build artifacts, caches and scratch diagnostic output are not deliverables.

Final local validation on 2026-10-23 (revision): `forge build` succeeded; `forge test` reported **91 passed,
0 failed, 0 skipped**, including all ten pinned mainnet fork tests. The hook invariant campaign completed
16,384 handler calls with zero reverts, and its runs include both genuine partial fills and `PartialFill`
refusals. With `MAINNET_RPC_URL` empty the fork fixture skips (one skipped `setUp`).
