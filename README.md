# NovaSynth Protocol — Synthetic Assets & Multi-Pool Governance

> **Category**: Synthetic Assets · DeFi · Composite Oracle & Governance  
> **Difficulty**: Hard  
> **Solidity**: `^0.8.20` · **Framework**: Foundry  
> **Total Findings to Discover**: 5 (1 Critical · 3 High · 1 Medium)  
> **Lab Type**: Intentionally Vulnerable — Educational  
> **Benchmark ID**: `defi_economic_invariant_8`  
> **nSLOC**: ~680  
> **Contracts**: 5  
> **Chain**: Ethereum Mainnet (simulated)

---

## 1. Protocol Overview

**NovaSynth** is a synthetic asset protocol powered by chained oracle feeds, snapshot-based governance, and multi-pool staking infrastructure. Users mint synthetic assets backed by collateral valued through a composite oracle, participate in governance with snapshot-based voting power, and earn rewards across multiple configurable staking pools.

The protocol is designed so that:
- **Composite oracle** (`SynthOracle`) reads from both an AMM TWAP and an external Chainlink feed, averaging them
- **Governance** (`SynthGovernor`) uses snapshotted token balances at proposal creation time for voting power
- **Multi-pool rewards** (`MultiPoolRewards`) distributes SYNTH tokens across N independently configurable pools
- **Snapshotted token** (`SynthToken`) records historical balances for governance lookups
- **External feed** (`ChainlinkMock`) simulates a Chainlink AggregatorV3 price oracle

The combination of oracle composition, block-based snapshots, and multi-pool dynamics creates interaction patterns that are individually well-known but produce novel vulnerabilities when combined.

---

## 2. Architecture

```
                    ┌────────────────────────────────────┐
                    │          User / Frontend            │
                    └───┬──────────┬──────────┬──────────┘
                        │          │          │
           ┌────────────▼──────┐   │   ┌──────▼──────────────┐
           │   SynthGovernor   │   │   │  MultiPoolRewards   │
           │  (snapshot-based  │   │   │  (N pools, each     │
           │   governance)     │   │   │   separate rate)    │
           └────────┬──────────┘   │   └──────┬──────────────┘
                    │              │           │
           ┌────────▼──────────┐   │   ┌──────▼──────────────┐
           │   SynthToken      │   │   │   SynthOracle       │
           │  (ERC20 + balance │   │   │  (AMM TWAP +        │
           │   snapshots)      │   │   │   Chainlink avg)    │
           └───────────────────┘   │   └──────┬──────────────┘
                                   │          │
                            ┌──────▼──────────▼──┐
                            │   ChainlinkMock    │
                            │  (external price   │
                            │   feed simulator)  │
                            └────────────────────┘
```

### Oracle Dependency Chain
```
ChainlinkMock ──► SynthOracle.getPrice() ◄── AMM TWAP
                        │
                        ▼
              Composite Price = average(AMM_TWAP, Chainlink)
              (no staleness check on either source)
```

---

## 3. Contracts

| Contract | File | nSLOC | Description |
|----------|------|-------|-------------|
| `SynthToken` | `SynthToken.sol` | ~70 | ERC20 with snapshotted balances for governance lookups |
| `ChainlinkMock` | `ChainlinkMock.sol` | ~60 | Mock Chainlink AggregatorV3 with configurable price/timestamp |
| `SynthOracle` | `SynthOracle.sol` | ~130 | Composite oracle averaging AMM TWAP + Chainlink feed (no staleness check) |
| `SynthGovernor` | `SynthGovernor.sol` | ~200 | Governance with snapshot-at-proposal voting and quorum |
| `MultiPoolRewards` | `MultiPoolRewards.sol` | ~220 | Multi-pool staking with separate reward rates and mass update |

**Total nSLOC**: ~680

---

## 4. Scope & Focus

All 5 contracts are in scope. This benchmark tests **temporal and compositional vulnerability patterns**:
- Chained oracle staleness propagation across multiple feeds
- Snapshot-based governance manipulation via cross-block timing
- Reward accounting gaps when multi-pool parameters change
- Resource exhaustion via unbounded data structures
- Accumulator precision degradation over time

Out of scope: Gas optimization, code style, informational findings.

---

## 5. Known Vulnerabilities (Post-Audit Disclosure)

The following 5 vulnerabilities were confirmed during the audit. They are disclosed here for educational purposes.

---

### V-01: Chained Oracle Staleness — Propagated Stale Price

| Field | Value |
|-------|-------|
| **Severity** | Critical |
| **Impact** | Incorrect Pricing → Undercollateralized Minting/Liquidation |
| **Likelihood** | High (triggers whenever either feed goes stale) |
| **File** | `SynthOracle.sol` |
| **Location** | `getPrice()` — averages AMM TWAP + Chainlink with no freshness check |
| **Difficulty** | Hard |

**Description**: `SynthOracle.getPrice()` computes a composite price by reading two sources — an internal AMM TWAP feed and an external Chainlink feed — and averaging them. However, there is **NO staleness check** on either source. If the Chainlink feed hasn't been updated for hours (or the mock returns a hardcoded price), and the AMM TWAP is manipulated within its window, the "average" produces a completely wrong price.

The staleness **compounds** across the chain: if the AMM TWAP is 30 minutes old and Chainlink is 3 hours old, the composite price reflects a weighted average of two stale data points — neither of which represents current reality. The averaging creates a false sense of security ("we use multiple sources") while actually increasing attack surface.

**Key Difference from BM1**: BM1 tested a single TWAP window being too short. This tests **chained/composite** oracle staleness across multiple independent feeds that compound the problem.

**Exploit Path**:
1. Chainlink feed hasn't updated for 4 hours (ETH price moved from $3,000 to $2,500)
2. Attacker manipulates AMM reserves to push TWAP to $4,000
3. Composite price = average($4,000, $3,000) = $3,500
4. Real price is $2,500 → composite is 40% too high
5. Attacker mints synthetic assets against collateral valued at $3,500 instead of $2,500
6. Attacker's position is under-collateralized from inception → profit on mint, loss to protocol

**Recommendation**: Add per-feed staleness checks: `require(block.timestamp - lastUpdateTime < MAX_STALENESS, "Stale feed")`. Check each feed independently BEFORE averaging.

---

### V-02: Governance Snapshot Gap Attack

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Governance Manipulation — attacker acquires voting power without long-term commitment |
| **Likelihood** | Medium (requires mempool monitoring) |
| **File** | `SynthGovernor.sol` |
| **Location** | `propose()` records `snapshotBlock = block.number`; `castVote()` reads `balanceOfAt(voter, snapshotBlock)` |
| **Difficulty** | Medium |

**Description**: When a proposal is created, `propose()` records the current `block.number` as the `snapshotBlock`. Voting power is determined by the voter's token balance at that specific block via `SynthToken.balanceOfAt(voter, snapshotBlock)`. The vulnerability: the snapshot is taken at proposal creation time, and tokens can be purchased/transferred BEFORE the proposal is created to influence the snapshot.

An attacker monitoring the mempool can see a `propose()` transaction and front-run it with a large token purchase. Since the purchase is mined in the same or preceding block, the attacker's balance at `snapshotBlock` includes the purchased tokens. After voting, the attacker sells the tokens — having influenced governance without any long-term commitment.

**Key Difference from BM2**: BM2 tested flash mint governance manipulation (same-block). This tests cross-block snapshot timing manipulation via pre-purchase.

**Exploit Path**:
1. Attacker monitors mempool for pending `propose()` transactions
2. Attacker front-runs: buys 1M SYNTH tokens → included in block N
3. `propose()` is mined in block N → `snapshotBlock = N` → attacker has 1M SYNTH at block N
4. Attacker calls `castVote(proposalId, true)` → voting power = 1M SYNTH
5. Proposal passes with attacker's overwhelming vote
6. Attacker sells 1M SYNTH → no ongoing commitment, governance influence achieved
7. Malicious proposal executes (parameter changes, fund extraction, etc.)

**Recommendation**: Use `block.number - 1` (or a configurable lookback) for snapshot to prevent same-block manipulation, and add a voting delay period during which votes cannot be cast.

---

### V-03: Multi-Pool Reward Rate Change Drops Pending Rewards

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Permanent Loss of Staker Rewards in Affected Pool |
| **Likelihood** | High (triggers on normal admin operations) |
| **File** | `MultiPoolRewards.sol` |
| **Location** | `setPoolRewardRate()` changes rate without calling `_updatePool()` first |
| **Difficulty** | Easy |

**Description**: When admin calls `setPoolRewardRate(poolId, newRate)` to adjust a specific pool's reward emission, the function does NOT call `_updatePool(poolId)` before changing the rate. All pending but undistributed rewards in that pool since the last interaction are retroactively recalculated using the NEW rate.

This is similar to BM7 V-03 (single pool rate change) but amplified by the **multi-pool context**: changing one pool's rate can cascade to other pools if `massUpdatePools()` is called afterward, since the total reward budget may be shared. Stakers in the affected pool lose earned rewards or receive windfalls depending on rate direction.

**Exploit Path**:
1. Pool A: rate = 100 SYNTH/block, 5 stakers, 1,000 blocks since last update
2. Pending rewards = 100 × 1,000 = 100,000 SYNTH (to be split among stakers)
3. Admin calls `setPoolRewardRate(poolA, 1)` (99% reduction)
4. `_updatePool(poolA)` NOT called → `accRewardPerShare` NOT updated
5. Next staker interaction triggers `_updatePool()` → computes rewards at NEW rate
6. Pending rewards = 1 × 1,000 = 1,000 SYNTH (99% of earned rewards lost)
7. **99,000 SYNTH permanently lost** — never minted, never claimable

**Recommendation**: Enforce `_updatePool(poolId)` as the first operation in `setPoolRewardRate()` to settle all pending rewards at the old rate.

---

### V-04: Unbounded Array Gas Griefing — Protocol DOS

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | User Fund Lock — staking contract becomes non-functional |
| **Likelihood** | Medium (requires many pools to be created) |
| **File** | `MultiPoolRewards.sol` |
| **Location** | `addPool()` pushes to unbounded `pools[]`; `massUpdatePools()` iterates ALL |
| **Difficulty** | Medium |

**Description**: `addPool()` pushes new entries to an unbounded `pools[]` array. `massUpdatePools()` iterates ALL pools to accrue pending rewards. As the array grows, `massUpdatePools()` consumes more gas. Since `stake()` and `unstake()` call `massUpdatePools()` internally, once the array exceeds a critical size (~500+ pools depending on gas limit), ALL staking operations revert with out-of-gas.

At that point, user funds are permanently locked — they cannot `unstake()` because the transaction runs out of gas in the `massUpdatePools()` loop.

**Exploit Path**:
1. Admin (or permissionless path) creates pools over time: 10, 50, 100, 200, 500...
2. At 500+ pools, `massUpdatePools()` costs > 30M gas (block limit)
3. User calls `unstake(100 SYNTH)` → internally calls `massUpdatePools()` → reverts (out of gas)
4. User calls `stake()` → same revert
5. All user funds in all pools are permanently locked
6. No admin function can fix this without contract upgrade (which may not exist)

**Recommendation**: Remove `massUpdatePools()` from `stake()`/`unstake()` hot paths. Update only the specific pool being interacted with. Or implement lazy per-pool updates.

---

### V-05: Accumulator Precision Loss Over Time

| Field | Value |
|-------|-------|
| **Severity** | Medium |
| **Impact** | Gradual Reward Loss for Frequent Claimers |
| **Likelihood** | Medium (compounds over weeks/months of operation) |
| **Files** | `SynthOracle.sol` (cumulative price) + `MultiPoolRewards.sol` (accRewardPerShare) |
| **Location** | Accumulator variables grow monotonically; delta precision decreases over time |
| **Difficulty** | Hard |

**Description**: Accumulator variables (like `accRewardPerShare` and `cumulativePrice`) grow monotonically over time. When computing user rewards, the delta is calculated as `currentAcc - userSnapshot`. As the accumulator grows large (after months of operation), the absolute precision of the delta decreases due to fixed-point arithmetic constraints.

Specifically: if `accRewardPerShare = 1e30` and a single-block increment adds `1e12`, the delta for a user who last claimed at `1e30 - 1e12` is `1e12`. But if `accRewardPerShare = 1e36`, a single-block increment of `1e12` may be lost to truncation when the delta is computed — the precision of `1e36 - (1e36 - 1e12)` depends on the compiler/EVM arithmetic being exact (which it is for uint256, but the intermediate calculations that PRODUCE the accumulator value may truncate).

Users who claim frequently (every block) accumulate less total reward than users who claim rarely (once per week), because per-block increments below the precision threshold are silently dropped.

**Exploit Path**:
1. Protocol has been running for 6 months, `accRewardPerShare = 1e30`
2. Alice stakes and claims every block → per-block delta may truncate to 0
3. Bob stakes same amount but claims weekly → weekly delta is large enough to maintain precision
4. Over 1 month: Alice receives 90% of expected rewards, Bob receives 100%
5. The 10% difference is permanently lost — never distributed, not recoverable

**Recommendation**: Use higher-precision accumulators (e.g., 1e36 scaling instead of 1e18), or implement a minimum claim interval to batch small increments.

---

## 6. Vulnerability Summary

| ID | Name | Severity | Impact | Difficulty | Primary Contract |
|----|------|----------|--------|------------|-----------------|
| V-01 | Chained Oracle Staleness | **Critical** | Incorrect pricing | Hard | SynthOracle |
| V-02 | Snapshot Gap Attack | **High** | Governance manipulation | Medium | SynthGovernor |
| V-03 | Multi-Pool Rate Change Loss | **High** | Permanent reward loss | Easy | MultiPoolRewards |
| V-04 | Unbounded Array DOS | **High** | User fund lock | Medium | MultiPoolRewards |
| V-05 | Accumulator Precision Loss | **Medium** | Gradual reward loss | Hard | SynthOracle + MultiPoolRewards |

**Severity Distribution**: 1 Critical, 3 High, 1 Medium

---

## 7. Key Differences from Previous Benchmarks

| Aspect | Key Distinction |
|--------|----------------|
| **V-01 (Oracle)** | Chained composite staleness across 2 feeds (BM1 tested single TWAP window) |
| **V-02 (Governance)** | Cross-block snapshot timing manipulation (BM2 tested same-block flash mint) |
| **V-03 (Rewards)** | Multi-pool rate change (BM7 tested single pool; here pool interactions amplify) |
| **V-04 (DOS)** | Unbounded array resource exhaustion (first DOS pattern in benchmark suite) |
| **V-05 (Precision)** | Accumulator degradation over time (BM2 tested cumulative P-product loss) |

---

## 8. Design Philosophy

This benchmark tests SolGuard's ability to detect **temporal and compositional vulnerabilities**:

1. **Chained oracle composition** (V-01): Multiple stale sources averaging to wrong price
2. **Block-level timing** (V-02): Snapshot manipulation via transaction ordering
3. **Multi-pool parameter dynamics** (V-03): Admin operations with unsettled cross-pool state
4. **Resource exhaustion** (V-04): Growth-based denial of service via unbounded iteration
5. **Long-term precision** (V-05): Accumulator math degrading over operational lifetime

---

## 9. Build & Test

```bash
cd server/examples/defi_economic_invariant_8
forge build
```
