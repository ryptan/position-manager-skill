---
description: Analyzes the breakeven point and impermanent loss for a CLMM position.
---

# /position-manager-analyze-breakeven

Usage: `/position-manager-analyze-breakeven <position_mint_address> [protocol]`

This command is a shortcut for the **position-manager** skill. Follow the full procedure described in the skill's `SKILL.md` exactly — safety rules first, then parameter validation, data fetching, math, validation, and output.

- `<position_mint_address>` — required. If missing, ask the user for it.
- `[protocol]` — optional. If missing, ask the user which protocol the position belongs to. Only Orca Whirlpools is currently supported; any other protocol triggers the safe fallback described in the skill.

Do not duplicate or reimplement the workflow here — always defer to the position-manager skill and its related files so the command and the skill never drift out of sync.
