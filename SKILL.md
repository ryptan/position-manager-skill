---
name: position-manager
description: Analyzes Orca Whirlpools concentrated liquidity (CLMM) positions to determine breakeven point and impermanent loss (IL). Use this skill whenever the user asks about impermanent loss, breakeven on a liquidity position, "is my LP position profitable", CLMM/Whirlpool math, or provides a Solana position mint address. Also use it for any request to rebalance, withdraw, close, or swap on a CLMM position, since this skill's safety rules must be loaded first before any execution logic is considered. Currently supports Orca Whirlpools only.
user-invocable: true
---

# CLMM Position Manager & Breakeven Analyzer

Determines whether a Concentrated Liquidity Market Maker (CLMM) position on **Orca Whirlpools** has reached breakeven — i.e. whether accumulated swap fees and farming rewards offset Impermanent Loss (IL) — using exact on-chain SDK math and historical tracking.

## 0. Safety first (always, no exceptions)

Before doing anything else — including before reading on-chain data — load and follow `rules/execution-safety.md`. Its rules (read-only by default, zero unsimulated transactions, IL sanity checks, lexicographic token awareness) apply to every step below and override anything that conflicts with them.

## 1. Identify the request

| User intent | What to do |
|---|---|
| Breakeven / IL analysis on a position | Continue to step 2 |
| Rebalance / withdraw / close / swap | Still continue to step 2 to gather the same data, but never build or suggest an execution transaction without a dry-run simulation first (see `rules/execution-safety.md`) |
| Protocol other than Orca (e.g. Raydium, Meteora) | Tell the user this skill currently only supports Orca Whirlpools, and stop. Do not invent SDK calls for unsupported protocols. |

## 2. Gather parameters

- **Position mint address** — required. Ask the user if not provided.
- **Protocol** — if not stated, ask which protocol the position belongs to (Orca, Raydium, Meteora, etc.) before proceeding. Apply the fallback rule above if it isn't Orca.

## 3. Load context as needed (progressive disclosure)

Don't load everything up front — pull in only what the current step needs:

| Need | Reference file |
|---|---|
| Fetching Orca Whirlpool on-chain state, parsing historical RPC events, extracting exact SDK token amounts and Farming Rewards | `skill/orca-analyzer.md` |
| PnL, IL formulas, and the `analyzeSegmentedBreakeven` TypeScript reference | `skill/clmm-math.md` |
| Internal validation checks to run before showing results to the user | `skill/clmm-testing.md` |
| Read-only / simulation / lexicographic rules | `rules/execution-safety.md` |

## 4. Fetch on-chain data (read-only)

Following `skill/orca-analyzer.md`:

1. Check mint addresses against the Known Quote Mints table to identify the Quote Token.
2. Fetch transaction history for the Position Mint — prefer Helius MCP's `getTransactionHistory` if that connector is available (`skill/orca-analyzer.md` Step 1), otherwise fall back to plain RPC (`getSignaturesForAddress` + pagination).
3. Parse `sqrtPriceX64` and `liquidity` (u128) at each modification.
4. **CRITICAL**: Use `PoolUtil.getTokenAmountsFromLiquidity` to calculate exact token amounts at each price point. Do NOT use custom math.
5. Fetch **current live position state** separately (for `currentValue` display).
6. Sum all historical `collect_fees` + current pending swap fees + all **Farming Rewards** (`rewardInfos`), converted to the Quote Token (non-Quote reward mints priced via the Jupiter Price API v3 — `skill/orca-analyzer.md` Step 4).
7. Handle Edge Cases: Check if $L=0$ currently.

## 5. Run the math

Pass the segments (with actual token amounts), total income, and current live state into `analyzeSegmentedBreakeven()` as defined in `skill/clmm-math.md`. Always use `decimal.js` — never native JS numbers.

## 6. Validate before showing results

Before presenting anything to the user, run the internal checks from `skill/clmm-testing.md` — treat it as the canonical source for the exact thresholds, and don't restate or re-derive them here:
- **Per-segment IL check** (Axiom 2): every segment IL must stay within `IL_TOLERANCE` of zero on the positive side — not necessarily a strict `≤ 0`, since integer-math truncation in the SDK can introduce negligible positive noise. A breach beyond tolerance is a bug, not a license to widen the tolerance.
- **Out-of-range composition** (Axiom 1): verify SDK token amounts match the expected 100%/0% split, using the correctly-derived $P_a$/$P_b$ from `skill/orca-analyzer.md` Step 2b.
- If validation fails, halt, recheck, and don't show the user a wrong number.

## 7. Present the result

Give a clean summary including:

- **Initial Invested Value** (value of the tokens at the very first deposit — guaranteed present, since `analyzeSegmentedBreakeven` now throws rather than silently omitting it)
- **Total Current Position Value** (from live SDK data)
- **Total Withdrawn to Wallet** (cumulative quote value of all `decrease_liquidity` withdrawals at their respective prices — include this field whenever any withdrawal events exist, so users can distinguish "funds returned to wallet" from "funds lost to IL". If zero, omit for brevity.)
- **Total Impermanent Loss (IL)** accounting for any liquidity changes
- **Liquidity Events** (number of increase/decrease events detected)
- **Total Accumulated Income** (Swap Fees + Farming Rewards, broken down separately)
- **Net Result** ($Net = IL + Income$)
- A definitive **YES / NO** on whether the position has reached breakeven

### Out-of-Range Alert

If $P_c < P_a$ or $P_c > P_b$, append a prominent warning:

> ⚠️ **Position is OUT OF RANGE** — this position is not currently earning swap fees or farming rewards. Consider rebalancing.

**CRITICAL**: $P_a$/$P_b$ here MUST be the correctly-derived, correctly-ordered human-readable bounds from `skill/orca-analyzer.md` Step 2b — never a raw tick-to-price conversion used directly. When the pool's Token A is the Quote token (e.g. any USDC/SOL pool, since USDC's mint sorts before SOL's), inverting the raw price to get `priceBaseInQuote` also flips which tick bound is numerically lower. Skipping Step 2b silently breaks this check for roughly half of all pools.

### Rebalance Suggestion (read-only)

If the position is out of range, suggest a new range centered around the current price (in `priceBaseInQuote` terms, the same units shown to the user):

- **Suggested Lower Bound**: $P_c \times 0.85$ (−15%)
- **Suggested Upper Bound**: $P_c \times 1.15$ (+15%)

**Tick Spacing**: Orca pools have a fixed `tickSpacing` (e.g. 1, 8, 64, 128). The suggested bounds MUST be snapped to valid tick indices using `PriceMath.priceToInitializableTickIndex(price, decimalsA, decimalsB, tickSpacing)`.

**CRITICAL**: this function expects `price` in the raw ("Token B / Token A") convention, NOT `priceBaseInQuote`. Convert back using `skill/orca-analyzer.md` Step 2c before snapping — this includes swapping which human-readable bound maps to `tickLower` vs `tickUpper` when `isTokenAQuote = true`. After snapping, verify `tickLowerIndex < tickUpperIndex`; if that fails, the conversion was done wrong, not the suggestion itself. Show both the human-readable price and the tick index in the suggestion.

Make it clear this is a **suggestion only** — the agent MUST NOT generate any transaction code unless the user explicitly asks, and even then a dry-run simulation is required first (see `rules/execution-safety.md`).

## Claude Code: slash command

If you're running in Claude Code, this skill is also reachable via `/position-manager-analyze-breakeven <position_mint_address> [protocol]` — see `commands/analyze-breakeven.md`. The slash command follows the exact same procedure described above; it's just a shortcut, not a separate workflow.
