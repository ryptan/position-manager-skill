# CLMM Position Manager: Execution & Safety Rules

These rules are strictly enforced whenever the AI agent interacts with a user's on-chain liquidity positions.

### 1. Zero Unsimulated Transactions

NEVER generate or suggest execution code (e.g., `TransactionBuilder.buildAndExecute()`) for withdrawing, rebalancing, or depositing funds without first providing a dry-run simulation.

**Rule**: Always use simulation endpoints or clearly log the exact mathematical expected output before asking the user for confirmation to proceed.

### 2. Read-Only Default State

Assume the user wants a read-only analysis unless they explicitly use words like "rebalance", "withdraw", "close", or "swap".

**Rule**: Default to RPC get methods (e.g., `getPosition`, `getPool`) rather than instruction builders.

### 3. Mathematical Sanity Check

Impermanent Loss (IL) is mathematically constrained. It is the loss incurred by providing liquidity versus holding the assets.

**Rule**: If your internal calculation of Impermanent Loss yields a positive number beyond a small tolerance for integer-math rounding noise — either for the total or for any individual segment — YOUR CALCULATION IS WRONG. (See `IL_TOLERANCE` in `skill/clmm-math.md` and Axiom 2 in `skill/clmm-testing.md` for the exact value and the full check — this file states the principle, those files are canonical for the threshold.) You likely swapped the decimals, the Base/Quote token order, or misconfigured `isTokenAQuote`. You MUST halt execution, recalculate, or inform the user of a data parsing error.

### 4. Lexicographic Awareness

Solana tokens in AMMs are sorted lexicographically by their mint addresses.

**Rule**: Do not assume "Token B" is the stablecoin or Quote token. You MUST verify the mint address against the Known Quote Mints table in `skill/orca-analyzer.md` to correctly denominate the total fee value. This awareness extends beyond valuation to price-comparison direction: when Token A is the Quote token (e.g. any USDC/SOL pool, since USDC's mint sorts before SOL's), the human-readable price is the *inverse* of the raw on-chain price, and inversion flips which range bound is numerically lower. Never compare against or snap range bounds without following `skill/orca-analyzer.md` Steps 2b/2c — this affects the out-of-range check and rebalance suggestions, not just fee totals.

### 5. No Hallucinated SDK Calls

If the user asks about a protocol that this skill does not explicitly support (e.g., Raydium, Meteora), do NOT invent or guess SDK method names. Instead, inform the user that the protocol is not yet supported and stop.

**Rule**: Only use SDK methods that are explicitly documented in `skill/orca-analyzer.md`.

### 6. Validate Addresses Before Any RPC Call

Any user-supplied address (position mint, wallet, pool) is untrusted input until checked. A malformed or truncated address sent straight into an RPC/SDK call can produce confusing downstream errors, or — worse — silently resolve to an unintended account if it happens to collide with a different valid key.

**Rule**: Before issuing any RPC, SDK, or Helius MCP call (`getPosition`, `getAccountInfo`, `heliusTransaction`, etc.) with a user-supplied address, validate it by constructing a `PublicKey` from it and catching the failure case explicitly, rather than relying on string length or regex matching:

```typescript
import { PublicKey } from "@solana/web3.js";

function validateAddress(input: string): PublicKey {
    try {
        return new PublicKey(input);
    } catch {
        throw new Error(
            `"${input}" is not a valid base58-encoded Solana address. Please double-check the position mint address.`
        );
    }
}
```

- `new PublicKey(...)` already enforces correct base58 encoding and the 32-byte length — there is no need to hand-roll a base58/length regex, and a hand-rolled regex is easy to get subtly wrong (e.g. accepting visually-similar but invalid characters).
- This check confirms the input is a *well-formed* address, not that it is the *correct* one (e.g. a wallet address passed where a position mint was expected). Downstream errors from `getPosition`/`getPool` (e.g. "account not found" or a deserialization failure) are still the signal for "right shape, wrong account" — surface those to the user rather than guessing.
- Run this validation once at the start of the routing flow in `skill/orca-analyzer.md` Agent Action Routing, before Step 1, so a malformed address fails fast instead of partway through a multi-step historical fetch.
