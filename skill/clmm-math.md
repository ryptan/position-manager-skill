# CLMM Mathematics & Breakeven Analysis

This document provides the core mathematical formulas and reference TypeScript implementations for calculating Impermanent Loss (IL) and Breakeven points for Concentrated Liquidity Market Maker (CLMM) positions.

## Core Financial PnL Logic

Unlike AMMs where $X$ and $Y$ can be derived easily from human-readable prices, CLMM token derivations require Q64.64 invariant math. Therefore, **this module expects exact token amounts ($X$ and $Y$) to be provided by the SDK**, focusing purely on the financial calculation of Impermanent Loss and Net Result.

### Impermanent Loss (IL) with Variable Liquidity

Because CLMM positions allow for increasing or decreasing liquidity without closing the position (the NFT remains the same), calculating IL from a single entry price is incorrect. We must calculate IL in **segments** between liquidity modification events.

For each segment $i$ where liquidity was constant:
- Let $V_{end}$ be the value of the token amounts at the end of the segment, evaluated at the end price.
- Let $V_{hold}$ be the value of the initial deposited tokens at the start of the segment, evaluated at the end price.

$$IL_i = V_{end,i} - V_{hold,i}$$

Total $IL = \sum IL_i$

**Invariant**: $IL_i \le 0$ for every individual segment, within a small tolerance (`IL_TOLERANCE`, see below) for integer-math rounding noise. A per-segment IL that exceeds this tolerance indicates a data extraction bug (token decimal or Quote/Base mixup) — see Axiom 2 in `clmm-testing.md`.

## TypeScript Implementation Reference

**CRITICAL RULE**: Never use native JavaScript `number` for financial calculations. Always use `decimal.js` to prevent precision loss.

```typescript
import Decimal from 'decimal.js';

// Use a dedicated, cloned Decimal constructor instead of mutating the global
// default with Decimal.set(). This skill is meant to be installed inside a
// larger agent kit alongside other skills that may also import decimal.js
// with different settings — Decimal.set() would leak across all of them
// silently. ROUND_HALF_EVEN (banker's rounding) is standard for finance.
export const D = Decimal.clone({ precision: 40, rounding: Decimal.ROUND_HALF_EVEN });

// Tolerance for the per-segment IL sanity check (see Axiom 2 in clmm-testing.md).
// Raw on-chain integer math (u128 liquidity, sqrtPriceX64) can introduce
// negligible positive noise from truncation when converted through the SDK.
// This is NOT a license to hide real bugs — keep it tight. Expressed as an
// absolute amount in Quote-token units; tighten or loosen per the Quote
// token's typical position size if needed.
export const IL_TOLERANCE = new D("0.000001");

// Tolerance for the SUM of all segment ILs. Per-segment truncation error is
// bounded and small (IL_TOLERANCE), but a position with many liquidity
// events (many segments) can legitimately accumulate up to ~IL_TOLERANCE of
// noise PER segment — comparing the sum against the same per-segment value
// is too strict and produces false failures on otherwise-correct data.
// Centralized here (rather than recomputed inline in clmm-testing.md) so the
// scaling rule can't silently drift between the two checks that use it.
export function totalILTolerance(segmentCount: number): Decimal {
    return IL_TOLERANCE.mul(Math.max(1, segmentCount));
}

export interface LiquiditySegment {
    // Token amounts exactly at the start of this segment (derived via SDK)
    tokenA_Start: Decimal;
    tokenB_Start: Decimal;
    
    // Token amounts exactly at the end of this segment (derived via SDK)
    tokenA_End: Decimal;
    tokenB_End: Decimal;
    
    // Price of the Base token (non-quote) denominated in the Quote token, at end of segment.
    // Example: if Quote = USDC and Base = SOL, this is "SOL price in USDC" (e.g. 150).
    priceBaseInQuote_End: Decimal;
    
    // Price of the Base token at the start of the segment.
    // Optional for segments after the first one (display context only).
    // REQUIRED for segments[0] — analyzeSegmentedBreakeven() throws if it's
    // missing there, because it's the only source for `initialInvestedValue`.
    priceBaseInQuote_Start?: Decimal;
}

export interface SegmentedMathConfig {
    segments: LiquiditySegment[];
    swapFeesIncome: Decimal;       // Swap fees only (denominated in Quote token)
    farmingRewardsIncome: Decimal;  // Farming rewards only (denominated in Quote token)
    isTokenAQuote: boolean; // Tells the math engine which token is the Quote
    
    // Current live token amounts for the position (from SDK, for display purposes).
    // These are independent of segmentation and represent the NFT's actual holdings right now.
    currentTokenA: Decimal;
    currentTokenB: Decimal;
    currentPriceBaseInQuote: Decimal;
}

export interface BreakevenResult {
    totalImpermanentLoss: Decimal;
    segmentILs: Decimal[];  // IL for each individual segment (for per-segment validation)
    totalIncome: Decimal;   // swapFeesIncome + farmingRewardsIncome
    netResult: Decimal;
    isBreakeven: boolean;
    currentValue: Decimal;  // Actual current position value from live SDK data
    initialInvestedValue?: Decimal; // Value of the position at the time of the very first deposit
}

/**
 * Calculates the value of token amounts in Quote terms.
 */
export function valueInQuote(
    tokenA: Decimal,
    tokenB: Decimal,
    priceBaseInQuote: Decimal,
    isTokenAQuote: boolean
): Decimal {
    if (isTokenAQuote) {
        // Token A is Quote (e.g. USDC). Token B is Base.
        // Value = A_amount + B_amount * priceOfBInA
        return tokenA.plus(tokenB.mul(priceBaseInQuote));
    } else {
        // Token B is Quote. Token A is Base.
        // Value = B_amount + A_amount * priceOfAInB
        return tokenB.plus(tokenA.mul(priceBaseInQuote));
    }
}

/**
 * Executes full breakeven analysis for a CLMM position, supporting variable liquidity.
 * Assumes all token amounts have already been derived correctly by the protocol SDK.
 *
 * @throws if segments[0].priceBaseInQuote_Start is missing — it is required, not optional,
 * for the first segment, since it's the only source for `initialInvestedValue`.
 */
export function analyzeSegmentedBreakeven(config: SegmentedMathConfig): BreakevenResult {
    if (config.segments.length > 0 && !config.segments[0].priceBaseInQuote_Start) {
        throw new Error(
            "analyzeSegmentedBreakeven: segments[0].priceBaseInQuote_Start is missing. " +
            "It is REQUIRED for the first segment (unlike later segments, where it's optional " +
            "display context) because it's the only source for `initialInvestedValue`. " +
            "The calling agent must always populate it for the position's very first deposit."
        );
    }

    let totalIL = new D(0);
    const segmentILs: Decimal[] = [];
    
    for (const segment of config.segments) {
        const valEnd = valueInQuote(
            segment.tokenA_End, segment.tokenB_End,
            segment.priceBaseInQuote_End, config.isTokenAQuote
        );
        
        const valStartHODLedAtEnd = valueInQuote(
            segment.tokenA_Start, segment.tokenB_Start,
            segment.priceBaseInQuote_End, config.isTokenAQuote
        );

        const segmentIL = valEnd.minus(valStartHODLedAtEnd);
        segmentILs.push(segmentIL);
        totalIL = totalIL.plus(segmentIL);
    }

    const totalIncome = config.swapFeesIncome.plus(config.farmingRewardsIncome);
    const netResult = totalIL.plus(totalIncome);
    
    // Current value is calculated independently from live SDK data, NOT from segments.
    const currentValue = valueInQuote(
        config.currentTokenA, config.currentTokenB,
        config.currentPriceBaseInQuote, config.isTokenAQuote
    );

    // priceBaseInQuote_Start on segments[0] is guaranteed present by the check above.
    let initialInvestedValue: Decimal | undefined = undefined;
    if (config.segments.length > 0) {
        initialInvestedValue = valueInQuote(
            config.segments[0].tokenA_Start, config.segments[0].tokenB_Start,
            config.segments[0].priceBaseInQuote_Start!, config.isTokenAQuote
        );
    }

    return {
        totalImpermanentLoss: totalIL,
        segmentILs,
        totalIncome,
        netResult,
        isBreakeven: netResult.gte(0),
        currentValue,
        initialInvestedValue
    };
}
```