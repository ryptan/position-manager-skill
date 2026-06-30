# CLMM Mathematical Testing Protocol

Before the AI agent returns final Breakeven or Impermanent Loss calculations to the user, it MUST internally validate its logic against edge cases to ensure `decimal.js` precision is maintained and logic holds true.

## Agent Validation Requirements

If requested to process a user's on-chain CLMM position, perform a "dry-run" sanity check on the numbers using these axioms:

### Axiom 1: Out-of-Range Composition

If Current Price ($P_c$) is below the lower boundary ($P_a$): The position must be composed of exactly 100% Asset X (Base token) and 0% Asset Y (Quote token).

If Current Price ($P_c$) is above the upper boundary ($P_b$): The position must be composed of exactly 0% Asset X and 100% Asset Y.

*(The agent should trust the SDK's `PoolUtil.getTokenAmountsFromLiquidity` for these bounds, but must verify the output).*

**Dependency**: $P_a$ and $P_b$ here must be the human-readable bounds derived via `orca-analyzer.md` Step 2b — the inversion-and-reorder logic for when Token A is the Quote token (e.g. any USDC/SOL pool). Feeding raw tick-to-price conversions into this axiom directly, without that step, will misclassify the position for roughly half of all pools and make this check unreliable rather than protective.

### Axiom 2: IL Negativity Constraint (Per-Segment)

Impermanent Loss (IL) for **each individual segment** must always be $\le 0$, within `IL_TOLERANCE` (exported from `clmm-math.md`) to absorb negligible integer-math rounding noise from the SDK's u128/sqrtPriceX64 conversions.

The `analyzeSegmentedBreakeven` function returns a `segmentILs: Decimal[]` array. The agent MUST verify two separate thresholds:

```typescript
import { IL_TOLERANCE, totalILTolerance } from './clmm-math';

// Check 1: Each individual segment IL must stay within IL_TOLERANCE.
// Per-segment truncation error is bounded and small — IL_TOLERANCE is tight enough here.
const allWithinTolerance = result.segmentILs.every(il => il.lte(IL_TOLERANCE));
if (!allWithinTolerance) {
    throw new Error("Sanity Check Failed: a per-segment IL exceeds the allowed tolerance.");
}

// Check 2: Total IL uses totalILTolerance(segmentCount) (exported from clmm-math.md)
// because truncation noise accumulates linearly with the number of segments.
// A position with 50 increase/decrease events can accumulate ~50× the per-segment
// rounding noise without any of them being a real bug.
const scaledTolerance = totalILTolerance(result.segmentILs.length);
if (result.totalImpermanentLoss.gt(scaledTolerance)) {
    throw new Error(
        `Sanity Check Failed: Total IL (${result.totalImpermanentLoss}) exceeds ` +
        `scaled tolerance (${scaledTolerance} = IL_TOLERANCE × ${result.segmentILs.length} segments).`
    );
}
```

If any single segment has IL beyond tolerance, the agent's logic is flawed (likely confusing Base and Quote token decimals, or setting `isTokenAQuote` incorrectly, or misnaming `priceBaseInQuote`). The tolerance exists to absorb rounding dust, not to mask real bugs — don't widen it to make a failing check pass.

Stop execution and warn the user. Do NOT rely solely on `totalImpermanentLoss` — a negative total can mask a positive individual segment.

### Axiom 3: Reversibility (Segmented)

If within a single segment, the user deposits at $P_0$ and the price drops to $P_1$, then rises exactly back to $P_0$, the Impermanent Loss for that segment must equal exactly $0$. 

*Note: This only holds true if Liquidity ($L$) remains constant. If $L$ changes while the price is at $P_1$, the IL will be locked in and will NOT return to 0 when the price returns to $P_0$.*

## Testing Template (TypeScript)

The agent should use this test template internally to verify the `analyzeSegmentedBreakeven` function (from `clmm-math.md`). Note the use of `D` (the cloned Decimal constructor) and `IL_TOLERANCE`, both exported from `clmm-math.md` — never construct test values with a bare `new Decimal(...)`.

```typescript
import { analyzeSegmentedBreakeven, SegmentedMathConfig, D, IL_TOLERANCE, totalILTolerance } from './clmm-math';

function runSanityCheck() {
    // Mock Config: SOL/USDC pool, Token B is Quote (USDC), Token A is Base (SOL)
    const mockConfig: SegmentedMathConfig = {
        segments: [
            {
                tokenA_Start: new D("10"),    // 10 SOL at entry
                tokenB_Start: new D("1500"),  // 1500 USDC at entry
                tokenA_End: new D("12"),      // 12 SOL after price drop
                tokenB_End: new D("1200"),    // 1200 USDC after price drop
                priceBaseInQuote_End: new D("100"), // SOL = $100 at end
                priceBaseInQuote_Start: new D("150") // SOL = $150 at start
            }
        ],
        swapFeesIncome: new D("0"),
        farmingRewardsIncome: new D("0"),
        isTokenAQuote: false,
        currentTokenA: new D("12"),
        currentTokenB: new D("1200"),
        currentPriceBaseInQuote: new D("100")
    };

    const result = analyzeSegmentedBreakeven(mockConfig);

    // Test 1: Per-segment IL must be <= IL_TOLERANCE (tight, per segment)
    const allWithinTolerance = result.segmentILs.every(il => il.lte(IL_TOLERANCE));
    if (!allWithinTolerance) {
        throw new Error("Sanity Check Failed: a per-segment IL exceeds tolerance.");
    }

    // Test 2: Total IL uses totalILTolerance(numSegments) (exported from clmm-math.md)
    // because rounding noise accumulates linearly across segments.
    const scaledTolerance = totalILTolerance(result.segmentILs.length);
    if (result.totalImpermanentLoss.gt(scaledTolerance)) {
        throw new Error(
            `Sanity Check Failed: Total IL (${result.totalImpermanentLoss}) exceeds ` +
            `scaled tolerance (${scaledTolerance}).`
        );
    }
    
    // Test 3: Net result identity
    const expectedNet = result.totalImpermanentLoss.plus(mockConfig.swapFeesIncome).plus(mockConfig.farmingRewardsIncome);
    if (!result.netResult.eq(expectedNet)) {
        throw new Error("Sanity Check Failed: Net result does not match IL + Income.");
    }

    // Test 4: Initial invested value check
    if (!result.initialInvestedValue?.eq(new D("3000"))) { // 1500 + 10 * 150 = 3000
        throw new Error(`Sanity Check Failed: initialInvestedValue should be 3000 but got ${result.initialInvestedValue?.toString()}`);
    }

    console.log(`Math validation passed. IL: ${result.totalImpermanentLoss.toString()}`);
    console.log(`Per-segment ILs: [${result.segmentILs.map(il => il.toString()).join(', ')}]`);
}

/**
 * Mirror of runSanityCheck(), but with isTokenAQuote = true (Token A = USDC = Quote,
 * Token B = SOL = Base) — the common case for any USDC/SOL pool, since USDC's mint
 * sorts lexicographically before SOL's. This must produce the SAME economic result
 * as runSanityCheck() above, just with token amounts swapped between A and B.
 * If this test fails while runSanityCheck() passes, the isTokenAQuote branch in
 * valueInQuote() (clmm-math.md) is broken.
 */
function runQuoteOnTokenACheck() {
    const mockConfig: SegmentedMathConfig = {
        segments: [
            {
                tokenA_Start: new D("1500"),  // 1500 USDC at entry (Token A = Quote)
                tokenB_Start: new D("10"),     // 10 SOL at entry (Token B = Base)
                tokenA_End: new D("1200"),
                tokenB_End: new D("12"),
                priceBaseInQuote_End: new D("100"),
                priceBaseInQuote_Start: new D("150")
            }
        ],
        swapFeesIncome: new D("0"),
        farmingRewardsIncome: new D("0"),
        isTokenAQuote: true,
        currentTokenA: new D("1200"),
        currentTokenB: new D("12"),
        currentPriceBaseInQuote: new D("100")
    };

    const result = analyzeSegmentedBreakeven(mockConfig);

    if (result.segmentILs.some(il => il.gt(IL_TOLERANCE))) {
        throw new Error("Sanity Check Failed (isTokenAQuote=true): a per-segment IL exceeds tolerance.");
    }
    if (!result.currentValue.eq(new D("2400"))) { // 1200 + 12*100
        throw new Error(`isTokenAQuote=true currentValue mismatch: got ${result.currentValue.toString()}`);
    }

    console.log("isTokenAQuote=true check passed — value calc is symmetric across A/B.");
}

/**
 * Axiom 3 Validation: if price returns to entry within a single segment, IL must be exactly 0.
 */
function runReversibilityCheck() {
    // SOL drops from 150 → 100 → back to 150, but we only see the net effect (start=150, end=150).
    // With constant L, token amounts at start and end are identical, so IL = 0.
    const mockConfig: SegmentedMathConfig = {
        segments: [
            {
                tokenA_Start: new D("10"),
                tokenB_Start: new D("1500"),
                tokenA_End: new D("10"),    // Same amounts — price returned to origin
                tokenB_End: new D("1500"),
                priceBaseInQuote_End: new D("150"),
                priceBaseInQuote_Start: new D("150")
            }
        ],
        swapFeesIncome: new D("0"),
        farmingRewardsIncome: new D("0"),
        isTokenAQuote: false,
        currentTokenA: new D("10"),
        currentTokenB: new D("1500"),
        currentPriceBaseInQuote: new D("150")
    };

    const result = analyzeSegmentedBreakeven(mockConfig);

    if (!result.totalImpermanentLoss.eq(0)) {
        throw new Error(`Reversibility Check Failed: IL should be 0 but got ${result.totalImpermanentLoss.toString()}`);
    }

    console.log("Reversibility check passed. IL = 0 when price returns to origin.");
}

/**
 * Guard-rail check: analyzeSegmentedBreakeven must throw if priceBaseInQuote_Start
 * is missing on segments[0] — it must never silently omit initialInvestedValue.
 */
function runMissingStartPriceGuardCheck() {
    const mockConfig: SegmentedMathConfig = {
        segments: [
            {
                tokenA_Start: new D("10"),
                tokenB_Start: new D("1500"),
                tokenA_End: new D("10"),
                tokenB_End: new D("1500"),
                priceBaseInQuote_End: new D("150")
                // priceBaseInQuote_Start intentionally omitted
            }
        ],
        swapFeesIncome: new D("0"),
        farmingRewardsIncome: new D("0"),
        isTokenAQuote: false,
        currentTokenA: new D("10"),
        currentTokenB: new D("1500"),
        currentPriceBaseInQuote: new D("150")
    };

    let threw = false;
    try {
        analyzeSegmentedBreakeven(mockConfig);
    } catch {
        threw = true;
    }
    if (!threw) {
        throw new Error("Guard-rail Check Failed: missing priceBaseInQuote_Start on segments[0] should throw.");
    }

    console.log("Guard-rail check passed — missing priceBaseInQuote_Start on segments[0] threw as expected.");
}

/**
 * Multi-segment tolerance scaling check: with several segments, each carrying
 * a small amount of rounding noise just under IL_TOLERANCE individually, the
 * SUM can legitimately exceed a flat IL_TOLERANCE without any single segment
 * being a bug. totalILTolerance(segmentCount) must accept this; a flat,
 * unscaled IL_TOLERANCE check on the total would incorrectly fail it.
 */
function runMultiSegmentToleranceScalingCheck() {
    // Five segments, each with the SAME tiny truncation-noise IL just under
    // IL_TOLERANCE (1e-6). A flat per-total IL_TOLERANCE check would fail
    // here (5 * ~9e-7 > 1e-6), but totalILTolerance(5) = 5e-6 must pass it.
    const noisePerSegment = IL_TOLERANCE.mul("0.9"); // ~9e-7, just under IL_TOLERANCE
    const segments: any[] = [];
    let prevEnd = new D("100"); // shared price chain across segments, for realism

    for (let i = 0; i < 5; i++) {
        // tokenB_End is bumped by noisePerSegment above what HODLing tokenB_Start
        // at the end price would give, simulating accumulated truncation dust.
        segments.push({
            tokenA_Start: new D("10"),
            tokenB_Start: new D("1000"),
            tokenA_End: new D("10"),
            tokenB_End: new D("1000").plus(noisePerSegment),
            priceBaseInQuote_End: prevEnd,
            priceBaseInQuote_Start: i === 0 ? prevEnd : undefined
        });
    }

    const mockConfig: SegmentedMathConfig = {
        segments,
        swapFeesIncome: new D("0"),
        farmingRewardsIncome: new D("0"),
        isTokenAQuote: false,
        currentTokenA: new D("10"),
        currentTokenB: new D("1000").plus(noisePerSegment),
        currentPriceBaseInQuote: prevEnd
    };

    const result = analyzeSegmentedBreakeven(mockConfig);

    // Each individual segment IL is within IL_TOLERANCE (the per-segment check passes).
    if (result.segmentILs.some(il => il.gt(IL_TOLERANCE))) {
        throw new Error("Multi-Segment Check Failed: an individual segment exceeded IL_TOLERANCE unexpectedly.");
    }

    // The SUM (5 * ~9e-7 ≈ 4.5e-6) exceeds a flat IL_TOLERANCE (1e-6) — this is
    // the exact scenario totalILTolerance(segmentCount) exists to handle correctly.
    if (result.totalImpermanentLoss.lte(IL_TOLERANCE)) {
        throw new Error(
            "Multi-Segment Check Setup Failed: this test is supposed to produce a total " +
            "that exceeds the flat IL_TOLERANCE, to prove the scaled check is actually needed. " +
            "If this throws, the test's noise values need adjusting."
        );
    }

    // The scaled tolerance must accept it.
    const scaledTolerance = totalILTolerance(result.segmentILs.length);
    if (result.totalImpermanentLoss.gt(scaledTolerance)) {
        throw new Error(
            `Multi-Segment Check Failed: Total IL (${result.totalImpermanentLoss.toString()}) ` +
            `exceeds scaled tolerance (${scaledTolerance.toString()}) even though each segment ` +
            `individually passed — totalILTolerance(segmentCount) scaling is broken.`
        );
    }

    console.log(`Multi-segment tolerance scaling check passed — total IL ${result.totalImpermanentLoss.toString()} accepted under scaled tolerance ${scaledTolerance.toString()} across ${segments.length} segments.`);
}

/**
 * Axiom 1 Validation: if price is below lower bound, position is 100% Base / 0% Quote.
 * If price is above upper bound, position is 0% Base / 100% Quote.
 * Note: This check does not call `analyzeSegmentedBreakeven`, but serves as a self-contained
 * conceptual proof that validates the math principle of Axiom 1 inline.
 */
function runOutofRangeCompositionCheck() {
    // Mock: Pc = 90, Pa = 100, Pb = 200. Pc < Pa.
    // Token B = Quote (USDC), Token A = Base (SOL).
    // Composition must be 100% Base (A > 0) and 0% Quote (B = 0).
    const currentTokenA = new D("10"); // Base
    const currentTokenB = new D("0");  // Quote
    const Pc = new D("90");
    const Pa = new D("100");
    const Pb = new D("200");
    const isTokenAQuote = false;

    const isBelowLower = Pc.lt(Pa);
    const isAboveUpper = Pc.gt(Pb);
    const baseAmount = isTokenAQuote ? currentTokenB : currentTokenA;
    const quoteAmount = isTokenAQuote ? currentTokenA : currentTokenB;

    if (isBelowLower) {
        if (!quoteAmount.eq(0) || baseAmount.lte(0)) {
            throw new Error(`Axiom 1 Failed: Price ${Pc.toString()} is below lower bound ${Pa.toString()}, but composition is not 100% Base / 0% Quote.`);
        }
    } else if (isAboveUpper) {
        if (!baseAmount.eq(0) || quoteAmount.lte(0)) {
            throw new Error(`Axiom 1 Failed: Price ${Pc.toString()} is above upper bound ${Pb.toString()}, but composition is not 0% Base / 100% Quote.`);
        }
    }
    
    console.log("Out-of-range composition check passed.");
}
```

Run all six checks (`runSanityCheck`, `runQuoteOnTokenACheck`, `runReversibilityCheck`, `runMissingStartPriceGuardCheck`, `runMultiSegmentToleranceScalingCheck`, `runOutofRangeCompositionCheck`) before trusting the module for a real position — each one exercises a different failure mode.