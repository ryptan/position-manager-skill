# Orca Whirlpools Integration Pattern

This document provides the standard operating procedures for the AI agent to fetch and analyze concentrated liquidity positions on the Orca Whirlpools protocol.

## Core Rules for Agent Execution

**Read-Only Operations First**: When analyzing a position, NEVER generate transaction code unless explicitly asked to rebalance or withdraw. Default to fetching state.

**Precision Management**: On-chain data is stored in raw integer formats (e.g., u64, u128). You MUST convert these to human-readable decimals using the respective token mint decimals *only after* performing invariant math via the SDK.

**Lexicographic Sorting Awareness (CRITICAL)**: Solana CLMMs sort token pairs lexicographically by their mint addresses. Token A is not always the Base token, and Token B is not always the Quote token (e.g., USDC). You MUST identify which token is the stable/quote asset before calculating total fee values.

**SDK Standard**: Always use the official `@orca-so/whirlpools-sdk` alongside `@solana/web3.js`, `@coral-xyz/anchor`, and `decimal.js`. This is the legacy-but-still-supported, officially-recommended Whirlpools SDK for projects on Solana Web3.js v1 (as opposed to `@orca-so/whirlpools` v2, which targets `@solana/kit`/Web3.js v2 — do not mix the two). If you need to write a temporary Node.js/TypeScript script to execute this math, install these pinned dependencies (see `package.json.reference` at the repo root for the exact versions this skill was validated against) rather than installing unpinned `latest`, since the SDK has had breaking changes across major versions:

```
@orca-so/whirlpools-sdk@^0.13
@orca-so/common-sdk@^0.6
@coral-xyz/anchor@0.31.1
@solana/web3.js@^1.95
decimal.js@^10.4
```

> **SDK version note**: `^0.13` in npm semver only allows patch updates within 0.13.x — it will NOT automatically pick up 0.14 through 0.20. The latest published version as of this writing is 0.20.x. The 0.13.x pin is deliberate: `PoolUtil.getTokenAmountsFromLiquidity` and `PriceMath` have been stable across this range, but if you need to upgrade, **verify** those two APIs haven't changed before widening the range. If you are starting a new project (not patching an existing one), widening to `^0.13.0 || >=0.14.0 <1.0.0` is reasonable after running the test suite in `skill/clmm-testing.md`.

## Known Quote Token Mints

Use this lookup to determine the Quote token in any pool. The Quote token is the one used to denominate all values (IL, fees, net result).

> **Token-2022 caveat**: some newer stablecoins (e.g. PYUSD) are minted under the Token-2022 program, not the classic SPL Token program. The mint addresses below are correct for identifying the Quote token; however, when fetching balances or constructing instructions for Token-2022 mints, use the `TOKEN_2022_PROGRAM_ID` constant from `@solana/spl-token` rather than the classic `TOKEN_PROGRAM_ID`. Confusing the two produces "invalid program id" errors at transaction time but does NOT affect read-only analysis.

### Mainnet

| Symbol | Mint Address | Notes |
|---|---|---|
| USDC | `EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v` | Classic SPL Token |
| USDT | `Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB` | Classic SPL Token |
| SOL (wrapped) | `So11111111111111111111111111111111111111112` | Classic SPL Token |
| PYUSD | `2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo` | Token-2022 — use `TOKEN_2022_PROGRAM_ID` |
| USDH | `USDH1SM1ojwWUga67PGrgFWUHibbjqMvuMaDkRJTgkX` | Classic SPL Token |

### Devnet

| Symbol | Mint Address |
|---|---|
| USDC (devnet) | `4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU` |
| SOL (wrapped) | `So11111111111111111111111111111111111111112` |

If the RPC endpoint/cluster being queried is devnet, match against this table instead of mainnet. Devnet mint addresses are test tokens, not official assets, and are not guaranteed to stay stable forever — if a lookup against both tables fails, fall through to the "ask user" rule below rather than guessing.

**Priority**: If one token is USDC, use USDC as Quote. If not, try USDT. If neither, try SOL. If **both** tokens are stablecoins (e.g. USDC/USDT pool), use USDC as Quote. If none of the above are present, ask the user which token they want as the denomination unit.

> **Cluster detection**: To determine whether to use the mainnet or devnet table, inspect the RPC endpoint URL (e.g. `api.devnet.solana.com` implies devnet) or query the genesis hash if the URL is ambiguous (e.g. a generic Helius/QuickNode RPC).

## 1. Fetching Historical State & Fees

To evaluate a true breakeven point, looking only at the *current* state is mathematically insufficient. The agent MUST parse the transaction history to account for variable liquidity ($L$) and previously collected fees + farming rewards.

### Step 1: Historical RPC Parsing (Helius / Solana RPC)
Instead of just fetching current pending fees, the agent must fetch all transactions for the Position Mint Address.

```typescript
// Agent Logic Pattern for Historical Parsing (fallback path — plain RPC, no Helius MCP):
// 1. Fetch all signatures for the Position Mint Address using `getSignaturesForAddress`
//    ⚠️ PAGINATION: this RPC method returns max 1000 signatures per call.
//    If the position is old or active, you MUST paginate using the `before` parameter
//    until no more signatures are returned.
// 2. Fetch parsed transactions for those signatures
// 3. Filter for Whirlpool instructions:
//    - `open_position` — creates the NFT with L=0. Does NOT add liquidity itself.
//      Use it to record the position creation timestamp and the sqrtPriceX64 at that
//      moment (needed for priceBaseInQuote_Start on the first segment).
//      The actual initial deposit is the first `increase_liquidity` (often in the same tx).
//    - `increase_liquidity`, `decrease_liquidity` — these are the real liquidity events.
//      Each one is a segment boundary.
//    - `collect_fees`, `collect_reward` — fee/reward collection events.
// 4. Construct a chronological timeline of these events (oldest first)
```

#### Integration with Helius MCP (optional, preferred when available)

If the Helius MCP server is connected (router tools such as `heliusTransaction` are visible in the tool list), prefer it over the manual `getSignaturesForAddress` loop above — it removes the hand-rolled pagination, which is the most fragile part of this step.

```typescript
// Preferred path — Helius MCP available:
// heliusTransaction({ action: "getTransactionHistory", address: positionMintAddress, mode: "parsed", limit: 100 })
// Then page forward with the returned `paginationToken` until it comes back empty/absent.
// "parsed" mode returns human-readable transactions (type, transfers, programs) directly —
// no separate getTransaction + manual decoding step is needed.
//
// If you already have a specific signature and only need to (re-)parse it, use:
// heliusTransaction({ action: "parseTransactions", transactions: [signature] })
```

- **Mode choice**: use `mode: "parsed"` for this skill — Helius has built-in decoders for many DeFi programs including Orca Whirlpools, so `open_position`, `increase_liquidity`, `decrease_liquidity`, `collect_fees`, and `collect_reward` instructions should come back with decoded fields rather than raw instruction bytes. If the decoded output does not contain the expected fields (e.g. `liquidity`, `sqrtPrice`), fall back to raw instruction parsing or the plain RPC path — do not guess the field layout.
- **Pagination**: Helius's `getTransactionHistory` uses a `paginationToken`, not the RPC `before` signature cursor — do not mix the two pagination styles.
- **Detection, not assumption**: check whether the Helius MCP tool is actually present in the current tool list before relying on it. Never claim to have used it if it is not available — fall back to the manual `getSignaturesForAddress` pattern above and say so if asked.
- **Fallback rule**: if Helius MCP is not connected, or a call to it errors (e.g. missing API key), fall back to the plain RPC pagination pattern above rather than failing the whole analysis.

### Step 2: Deriving Token Amounts (CRITICAL SDK MATH)
**DO NOT ATTEMPT TO RE-IMPLEMENT CLMM MATH USING $L$ AND HUMAN-READABLE PRICES.** 
Liquidity ($L$) in Solana is a raw `u128` scalar tied to Q64.64 prices. 
Instead, at every historical segment boundary, use the official SDK to derive the exact token amounts.

```typescript
import { PoolUtil, PriceMath } from "@orca-so/whirlpools-sdk";
import { DecimalUtil } from "@orca-so/common-sdk";
import { TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID } from "@solana/spl-token";
import { D } from "./clmm-math";

// Agent must extract the raw sqrtPriceX64 from the event logs at the time of the transaction.
// Then use the SDK to get the exact token amounts that liquidity represented at that price:
const amountsRaw = PoolUtil.getTokenAmountsFromLiquidity(
    liquidity, // The raw u128 L from the event
    sqrtPriceCurrentX64, // The raw Q64.64 price from the event
    sqrtPriceLowerX64,
    sqrtPriceUpperX64,
    true
);

// ONLY AFTER getting amountsRaw, convert them to human-readable decimals:
const tokenA_Amount = DecimalUtil.fromBN(amountsRaw.tokenA, tokenADecimals);
const tokenB_Amount = DecimalUtil.fromBN(amountsRaw.tokenB, tokenBDecimals);

// Derive the human-readable price for the math module.
// IMPORTANT: sqrtPriceX64ToPrice returns Token B / Token A (the Uniswap V3 convention).
// The math module expects "priceBaseInQuote" = price of the Base token in Quote units.
const rawPrice = PriceMath.sqrtPriceX64ToPrice(
    sqrtPriceCurrentX64, tokenADecimals, tokenBDecimals
);
// rawPrice = Token B / Token A.
//
// Case: isTokenAQuote = true → A is Quote (e.g. USDC), B is Base (e.g. SOL)
//   rawPrice = SOL / USDC = 0.00666...
//   priceBaseInQuote = "SOL in USDC" = 150 = 1 / rawPrice → INVERT
//
// Case: isTokenAQuote = false → B is Quote (e.g. USDC), A is Base (e.g. SOL)
//   rawPrice = USDC / SOL = 150
//   priceBaseInQuote = "SOL in USDC" = 150 = rawPrice → DIRECT
const priceBaseInQuote = isTokenAQuote
    ? new D(1).div(rawPrice)          // Invert: rawPrice is B/A = Base/Quote, we need Quote/Base
    : rawPrice;                              // Direct: rawPrice is B/A = Quote/Base = priceBaseInQuote
```

### Step 2b: Deriving the Human-Readable Range Bounds ($P_a$, $P_b$) — Critical Inversion Rule

**This step is mandatory and is the #1 source of silent bugs in this skill.** The position's range is defined on-chain by `tickLowerIndex` / `tickUpperIndex`, which map to **raw prices** — the same "Token B / Token A" convention used by `sqrtPriceX64ToPrice` above — NOT directly to `priceBaseInQuote`. Raw price increases monotonically with tick index, by definition of how ticks work.

This means the inversion rule above applies to the range bounds too, with one extra consequence: **inverting reverses the ordering**.

```typescript
const rawPriceLower = PriceMath.tickIndexToPrice(positionData.tickLowerIndex, tokenADecimals, tokenBDecimals);
const rawPriceUpper = PriceMath.tickIndexToPrice(positionData.tickUpperIndex, tokenADecimals, tokenBDecimals);

let Pa: Decimal; // human-readable LOWER bound, in priceBaseInQuote terms
let Pb: Decimal; // human-readable UPPER bound, in priceBaseInQuote terms

if (isTokenAQuote) {
    // Inversion flips the order: the tick-UPPER raw price becomes the human-LOWER bound,
    // and the tick-LOWER raw price becomes the human-UPPER bound.
    Pa = new D(1).div(rawPriceUpper);
    Pb = new D(1).div(rawPriceLower);
} else {
    // No inversion needed, order is preserved.
    Pa = rawPriceLower;
    Pb = rawPriceUpper;
}
```

**Why this matters concretely**: in any USDC/SOL pool, USDC's mint address (`EPjF...`) sorts lexicographically before SOL's (`So11...`), so Token A = USDC = Quote — meaning `isTokenAQuote = true` is the *normal* case for this pair, not an edge case. Reusing `rawPriceLower`/`rawPriceUpper` directly as `Pa`/`Pb` (or inverting them without swapping) silently produces a backwards range for roughly half of all pools.

Always derive `Pa`/`Pb` with the snippet above before using them for:
- The **Out-of-Range Alert** check in `SKILL.md` ($P_c < P_a$ or $P_c > P_b$)
- The **Axiom 1** composition check in `skill/clmm-testing.md`
- The **Rebalance Suggestion** in `SKILL.md` (see Step 2c below for the reverse conversion)

### Step 2c: Converting a Human-Readable Suggested Price Back to Raw, for Tick Snapping

`PriceMath.priceToInitializableTickIndex(price, decimalsA, decimalsB, tickSpacing)` expects `price` in the **raw** ("Token B / Token A") convention — the same one ticks are defined in — NOT `priceBaseInQuote`. Before snapping a human-readable suggested price (e.g. $P_c \times 0.85$, computed in `priceBaseInQuote`) to a tick, convert it back, swapping lower/upper when `isTokenAQuote = true`:

```typescript
function toRawPrice(priceBaseInQuote: Decimal, isTokenAQuote: boolean): Decimal {
    return isTokenAQuote ? new D(1).div(priceBaseInQuote) : priceBaseInQuote;
}

// suggestedLowerInQuote / suggestedUpperInQuote are Pc*0.85 / Pc*1.15, in priceBaseInQuote terms.
// Note the swap below — it mirrors Step 2b and is required for the same reason.
const rawForTickLower = isTokenAQuote ? toRawPrice(suggestedUpperInQuote, true) : toRawPrice(suggestedLowerInQuote, false);
const rawForTickUpper = isTokenAQuote ? toRawPrice(suggestedLowerInQuote, true) : toRawPrice(suggestedUpperInQuote, false);

const tickLower = PriceMath.priceToInitializableTickIndex(rawForTickLower, tokenADecimals, tokenBDecimals, tickSpacing);
const tickUpper = PriceMath.priceToInitializableTickIndex(rawForTickUpper, tokenADecimals, tokenBDecimals, tickSpacing);

// Sanity check — if this fails, the conversion was done wrong, not the suggestion itself.
if (tickLower >= tickUpper) {
    throw new Error("Rebalance tick derivation produced an inverted or degenerate range — check isTokenAQuote handling.");
}
```

### Step 3: Segmenting Liquidity
Group the history into segments of constant liquidity.
Whenever an `increase_liquidity` or `decrease_liquidity` event occurs, the previous segment ends at the current price, and a new segment begins.
**CRITICAL L-BOUNDARY RULE**: 
At the timestamp of a liquidity modification event (price $P_1$):
- The `tokenA_End` / `tokenB_End` of the **closing** segment MUST be calculated using the **old** liquidity $L_{old}$ (before the event) and price $P_1$.
- The `tokenA_Start` / `tokenB_Start` of the **new** segment MUST be calculated using the **new** liquidity $L_{new}$ (after the event) and price $P_1$.
- **Price continuity**: The new segment's `priceBaseInQuote_Start` equals the closing segment's `priceBaseInQuote_End` — they share the same boundary event at the same price $P_1$.

If a position is fully withdrawn ($L_{new} = 0$), the position is closed.

```typescript
// Example of how the agent should structure the historical data for the math module:
// Note: priceBaseInQuote is ALWAYS "Base token price in Quote token" regardless of which is A/B.
const historicalSegments = [
    {
        tokenA_Start: new Decimal("10.5"),
        tokenB_Start: new Decimal("1500.0"),
        tokenA_End: new Decimal("12.0"),
        tokenB_End: new Decimal("1300.0"),
        priceBaseInQuote_End: new Decimal("108.33"),
        priceBaseInQuote_Start: new Decimal("142.86")  // Optional for segments after the first; MANDATORY if this is segments[0]
    }
];
```

### Step 3b: Close the Currently-Open Segment (CRITICAL — most common omission)

After building the chronological list of closed segments from on-chain events, there is always one more segment: **the one that is still open right now**, spanning from the last `increase_liquidity` / `decrease_liquidity` event up to the present moment. This segment covers the most recent — and typically the most significant — period of price movement, and it must be explicitly closed before passing `segments[]` to `analyzeSegmentedBreakeven`.

**Rule**: If `L_current > 0` (position is still active), append one final segment whose end values come **directly from the live state fetched in Step 5** — the same `currentTokenA`, `currentTokenB`, and `currentPriceBaseInQuote` values passed into `SegmentedMathConfig`. Do NOT issue a second RPC call here; reuse the exact same values to guarantee that `currentValue` (computed from live state) and the last `segmentIL` (computed from the same live state) are internally consistent.

```typescript
// After building all closed segments from on-chain events:
if (positionData.liquidity.gtn(0)) {
    // currentAmountsRaw and currentSqrtPrice come from Step 5 — do not re-fetch.
    const lastEventL = lastLiquidityEventLiquidity; // u128 from the last increase/decrease event
    const lastEventSqrtPrice = lastLiquidityEventSqrtPrice; // Q64.64 from the last event

    const lastEventAmounts = PoolUtil.getTokenAmountsFromLiquidity(
        lastEventL,
        lastEventSqrtPrice,
        PriceMath.tickIndexToSqrtPriceX64(positionData.tickLowerIndex),
        PriceMath.tickIndexToSqrtPriceX64(positionData.tickUpperIndex),
        true
    );

    segments.push({
        tokenA_Start: DecimalUtil.fromBN(lastEventAmounts.tokenA, tokenADecimals),
        tokenB_Start: DecimalUtil.fromBN(lastEventAmounts.tokenB, tokenBDecimals),
        // End values: reuse the EXACT live-state variables from Step 5.
        // Never derive them independently here — a second RPC call may return
        // a slightly different sqrtPrice, creating a split-second discrepancy
        // between currentValue and the last segmentIL.
        tokenA_End: currentTokenA,       // from Step 5
        tokenB_End: currentTokenB,       // from Step 5
        priceBaseInQuote_End: currentPriceBaseInQuote,  // from Step 5
        // priceBaseInQuote_Start: optional if appending to existing closed segments;
        // REQUIRED if this is the only segment (segments.length === 0 before push)
    });
}
// Edge case: single-deposit position (one `open_position` + one `increase_liquidity`,
// no further increase/decrease events). In this case, `lastLiquidityEventL` is the
// liquidity from that single `increase_liquidity`, and `lastLiquidityEventSqrtPrice`
// is the sqrtPrice at the time of that event (NOT from `open_position`, which has L=0).
// There are no closed segments yet, so this Step 3b append creates the ONLY segment
// in the array — its Start comes from the initial increase_liquidity, its End from Step 5.
```

**Why this matters**: for a position that was deposited once and never modified, the entire `segments[]` array would be empty if this step is skipped — causing `totalIL = 0` regardless of how much the price has moved. That is the worst-case silent failure: no error, just a completely wrong result.

### Step 4: Total Fees & Farming Rewards Calculation
Profitability on Orca comes from two sources: Swap Fees and Farming Rewards.

1. **Swap Fees**: Sum all historical `collect_fees` transfers + current pending fees (using SDK's `getCollectFeesQuote` or equivalent).
2. **Farming Rewards**: A Whirlpool can have up to 3 reward emissions (`poolData.rewardInfos`). Sum all historical `collect_reward` transfers + current pending rewards (using SDK's `getCollectRewardQuote` or equivalent).
3. **Conversion**: Convert all collected and pending fees/rewards to the Quote token using the **current spot price** (the same `currentPriceBaseInQuote` / market price used at evaluation time) — NOT the historical price at each individual collection event. This is a deliberate choice, not an oversight: `analyzeSegmentedBreakeven` always values Impermanent Loss at the end-of-segment (i.e. current) price, so income must be valued on the same basis to keep `netResult = IL + income` financially consistent. Mixing then-dollars (historical fee value) with now-dollars (current-price IL) would silently distort the breakeven verdict.

   For non-Quote reward tokens (e.g., ORCA, JTO) — i.e. any reward mint that is not already one of the Quote candidates in the table above — fetch the current price via the **Jupiter Price API v3**:

   ```typescript
   // GET https://api.jup.ag/price/v3?ids=<mint1>,<mint2>,... (comma-separated, max 50 mints/call)
   const res = await fetch(`https://api.jup.ag/price/v3?ids=${rewardMint}`);
   const data = await res.json();
   const usdPrice = data.data[rewardMint]?.price;
   ```

   - The response is keyed under `data`; each entry exposes `price` (plus `id`, `type`, etc.). There is no separate "quote currency" parameter — V3 always prices in USD.
   - **Fail closed, do not assume a price of 0 or skip silently**: tokens with unreliable pricing are simply *omitted* from the response (no error, no `null` placeholder). If `data.data[rewardMint]` is missing, treat the reward value for that mint as **unknown** — report it to the user as "value not priced" rather than folding it into `netResult` as if it were worth nothing.
   - If the Quote token in this analysis is USDC, `usdPrice` can be used directly as the Quote-denominated price (USDC ≈ $1). For any other Quote token (USDT, SOL, etc.), also fetch that Quote mint's `usdPrice` in the same call and divide: `priceInQuote = usdPrice(rewardMint) / usdPrice(quoteMint)`.
   - This is the same API used for routine "what's this token worth" checks; it is not Whirlpool-specific tooling, so no SDK dependency is added by using it — a plain `fetch` is sufficient and keeps this skill's dependency surface unchanged from the pinned list in the Core Rules section above.


### Step 4b: Track Total Withdrawn to Wallet (for UX clarity)

While iterating through `decrease_liquidity` events to close segments, also accumulate the total value of liquidity that was withdrawn and returned to the user's wallet. This value must be tracked separately and presented in the final report (see `SKILL.md` Step 7) to prevent users from misreading a low `currentValue` as "lost" when part of it was simply withdrawn.

```typescript
// valueInQuote is exported from skill/clmm-math.md
let totalWithdrawnQuote = new D(0);

// For every decrease_liquidity event, record the withdrawn token amounts
// at the price at the time of the event (priceBaseInQuote at that transaction):
for (const decreaseEvent of decreaseLiquidityEvents) {
    const withdrawnAmounts = PoolUtil.getTokenAmountsFromLiquidity(
        decreaseEvent.deltaLiquidity,  // liquidity REMOVED (L_old - L_new)
        decreaseEvent.sqrtPriceX64,
        sqrtPriceLower,
        sqrtPriceUpper,
        true
    );
    const withdrawnA = DecimalUtil.fromBN(withdrawnAmounts.tokenA, tokenADecimals);
    const withdrawnB = DecimalUtil.fromBN(withdrawnAmounts.tokenB, tokenBDecimals);
    // Value at the price of the withdrawal event, not current price
    totalWithdrawnQuote = totalWithdrawnQuote.plus(
        valueInQuote(withdrawnA, withdrawnB, decreaseEvent.priceBaseInQuote, isTokenAQuote)
    );
}
```

Pass `totalWithdrawnQuote` into the final report alongside `currentValue` and `initialInvestedValue`.

> **Valuation note**: Unlike fees/rewards (valued at *current spot* to stay consistent with IL — see Step 4), withdrawals are valued at the *historical* price when they occurred. This is correct because `totalWithdrawnQuote` is an informational UX field ("how much did I take out?"), not a term in the `netResult = IL + income` formula. Users want to know what their withdrawal was worth *when they withdrew it*.

### Step 5: Current Position State (for `currentValue`)
Independently of the historical segmentation, fetch the **live** current state of the position:

```typescript
// These values go into SegmentedMathConfig.currentTokenA, currentTokenB, currentPriceBaseInQuote
const currentAmounts = PoolUtil.getTokenAmountsFromLiquidity(
    positionData.liquidity,
    poolData.sqrtPrice,
    PriceMath.tickIndexToSqrtPriceX64(positionData.tickLowerIndex),
    PriceMath.tickIndexToSqrtPriceX64(positionData.tickUpperIndex),
    true
);
```

## 2. Empty or Fully Withdrawn Positions

**Edge Case ($L=0$)**: If $L_{current} = 0$, the position has been emptied (but perhaps the NFT is not yet burned).
The agent MUST detect this and halt standard Breakeven projections.

**Response Template**: *"This position currently has 0 liquidity. A live breakeven point cannot be calculated, but the historical Total Profit/Loss is: [Net Result]."*

## Agent Action Routing

When a user asks to `/analyze-breakeven <position_mint_address>` for an Orca position:

0. **Validate the Address** (`rules/execution-safety.md` Rule 6 — **DO NOT SKIP**): Construct a `PublicKey` from the supplied position mint address before any RPC/SDK/MCP call. Fail fast with a clear message if it is not valid base58/32-byte input.
1. **Verify Quote Token**: Check mint addresses against the Known Quote Mints table above (mainnet or devnet, depending on cluster).
2. **Historical Extraction**: Fetch transaction history for the Position Mint — prefer Helius MCP's `getTransactionHistory` (Step 1) if connected, otherwise fall back to `getSignaturesForAddress` + pagination.
3. **Build Closed Segments via SDK**: Parse `sqrtPriceX64` and `liquidity` at each `increase_liquidity`/`decrease_liquidity` event (these are the segment boundaries — `open_position` is NOT a segment boundary since it has L=0, but its `sqrtPriceX64` provides the `priceBaseInQuote_Start` for the first segment). Use `PoolUtil.getTokenAmountsFromLiquidity` to build `LiquiditySegment[]` with `priceBaseInQuote_End` and — for `segments[0]` specifically — the mandatory `priceBaseInQuote_Start` (Step 2).
3b. **Close the Open Segment** (Step 3b — **DO NOT SKIP**): If `L_current > 0`, append the currently-open segment using the live state values from Step 5 as the End values. This is the most important segment for active positions; skipping it silently produces `totalIL = 0` for single-deposit positions.
4. **Derive Range Bounds**: Compute $P_a$/$P_b$ with the correct inversion-and-reorder logic (Step 2b) — required before any out-of-range or rebalance logic touches them.
4b. **Track Total Withdrawn** (Step 4b): Accumulate the quote-denominated value of every `decrease_liquidity` withdrawal, for display in the final report so users can distinguish "withdrawn to wallet" from "lost to IL".
5. **Fetch Current State**: Get live token amounts and price for `currentValue` calculation (fetch this first if possible, so Step 3b can reuse the same values without a second RPC call).
6. **Aggregate Income**: Sum all historical + pending swap fees AND farming rewards, valued at current spot price (non-Quote reward tokens priced via Jupiter Price API v3, Step 4). Convert to Quote token.
7. **Handle Edge Cases**: Check if $L=0$ currently.
8. **Calculate PnL**: Pass the segments, total income, and current state into `analyzeSegmentedBreakeven` from `clmm-math.md`.
9. **Validate**: Run the internal validation checks defined in `clmm-testing.md`, including per-segment IL checks (with tolerance) and out-of-range composition checks.
10. **Rebalance (if applicable)**: If out of range, derive the suggestion using Step 2c before snapping to ticks.
11. **Output**: Present the results to the user as described in `SKILL.md` Step 7.