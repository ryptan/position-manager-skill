# CLMM Position Manager & Breakeven Analyzer Skill

A Claude Code Skill that mathematically analyzes Concentrated Liquidity Market Maker (CLMM) positions to determine the exact moment a position becomes profitable — i.e. whether accumulated fees and farming emissions have offset Impermanent Loss (IL).

## 🎯 The Problem

DeFi builders and liquidity providers struggle to calculate exact impermanent loss within concentrated ranges, especially when liquidity has been modified over time (added/removed) or when pools emit additional farming rewards. Off-the-shelf tools give rough estimates; AI agents without protocol-specific guardrails hallucinate SDK calls or, worse, execute unsimulated transactions.

## 💡 Scope

This release focuses on a precise math engine plus the Orca Whirlpools integration. It fully supports segmented liquidity tracking (calculating true IL across multiple events), farming reward emissions, out-of-range alerts, and read-only rebalance suggestions. Other protocols (Raydium, Meteora) hit a safe, explicit fallback rather than hallucinated API calls.

## Key Features

- **Zero AI hallucinations** — strict routing in `SKILL.md`; unsupported protocols get a clear fallback instead of invented SDK calls.
- **Flawless math** — Delegates complex Q64.64 invariant math to the official Orca SDK, while handling strict financial PnL (HODL vs Current) with an isolated `decimal.js` instance (`Decimal.clone()`, not the global default) using Banker's rounding (`ROUND_HALF_EVEN`). Per-segment IL validation uses a tight tolerance for individual segments, and a scaled tolerance (×`numSegments`) for the total, catching both real bugs and accumulated rounding noise correctly.
- **Open-segment closure (critical fix)** — The currently-open segment (from the last liquidity event to *right now*) is always explicitly closed with live-state values before the math runs. Without this step, single-deposit positions produce `totalIL = 0` silently regardless of price movement.
- **Variable Liquidity Support** — IL is calculated in segments, accurately reflecting historical liquidity changes.
- **Farming Rewards Support** — Automatically parses and evaluates standard swap fees + up to 3 farming reward emissions, converting everything to a unified quote currency at current spot price (consistent with how IL itself is valued).
- **Withdrawn-vs-Lost transparency** — The final report includes a "Total Withdrawn to Wallet" field whenever partial withdrawals have occurred, so users can distinguish funds returned to their wallet from funds lost to IL.
- **Out-of-Range Alerts** — Warns the user when a position is no longer earning fees and suggests a rebalance range, using correctly inverted/reordered range bounds regardless of whether Token A or Token B is the Quote token.
- **Lexicographic awareness** — automatically identifies the Quote token using a built-in Known Quote Mints lookup (USDC, USDT, SOL, PYUSD, USDH — mainnet and devnet), with a Token-2022 caveat for newer stablecoins. Propagates that awareness to price comparisons and tick math, not just fee totals.
- **Automated entry-price discovery** — looks up the position's transaction history via RPC to deduce the exact $P_0$ without flawed $y_0 / x_0$ estimates.
- **Namespace-safe installation** — rules and slash commands are installed with a `position-manager-` prefix, preventing silent overwrites when co-installed with other skills in the Solana AI Kit.
- **Execution safety** — read-only by default; any execution logic requires a dry-run simulation first.
- **Input validation** — every user-supplied address is run through `PublicKey` construction before any RPC/MCP call, failing fast on malformed input instead of surfacing a confusing downstream error.
- **Ecosystem integrations (optional, auto-detected)** — if the Helius MCP connector is present, transaction history fetching prefers its `getTransactionHistory` tool over manual `getSignaturesForAddress` pagination; non-Quote farming reward tokens (e.g. ORCA, JTO) are priced via the Jupiter Price API v3. Both are optional — the skill works with plain RPC and falls back cleanly if either isn't available.

## 📂 Architecture

This skill follows the official Solana AI Kit structure for Claude Code skills:

```
.
├── SKILL.md                       # router: triggering description + main workflow
├── skill/                         # The core skill module
│   ├── clmm-math.md               # segmented IL/breakeven formulas + TypeScript reference
│   ├── clmm-testing.md            # internal validation checks (axioms)
│   └── orca-analyzer.md           # Orca Whirlpools SDK & RPC fetching patterns
├── rules/
│   └── execution-safety.md        # read-only & simulation rules loaded by default
├── commands/
│   └── analyze-breakeven.md       # optional Claude Code slash command (thin wrapper)
├── install.sh                     # Claude Code installer (macOS/Linux)
├── install.ps1                    # Claude Code installer (Windows)
├── package.json.reference         # pinned SDK dependency versions for scratch scripts
└── LICENSE                        # MIT License
```

## 🚀 Installation

### Claude Code

**On macOS/Linux:**
```bash
chmod +x install.sh
./install.sh
```

**On Windows (PowerShell):**
```powershell
./install.ps1
```

This copies the `SKILL.md` and `skill/` folder into `.claude/skills/position-manager`, the rule into `.claude/rules/` (as `position-manager-execution-safety.md`), and the slash command into `.claude/commands/` (as `position-manager-analyze-breakeven.md`). The namespace prefix prevents silent overwrites when co-installed with other Solana AI Kit skills.

The skill triggers automatically based on its description, or you can invoke it explicitly:

```
/position-manager-analyze-breakeven <position_mint_address> [protocol]
```

## 📄 License

MIT — see [LICENSE](LICENSE).
