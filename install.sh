#!/bin/bash
#
# CLMM Position Manager - Installation Script
# Installs the position-manager skill (and, if present, its Claude Code
# slash command and rules) into the local .claude/ directory.

set -e

echo "Installing CLMM Position Manager & Breakeven Analyzer Skill..."

CLAUDE_DIR=".claude"
SKILLS_DIR="$CLAUDE_DIR/skills"
COMMANDS_DIR="$CLAUDE_DIR/commands"
RULES_DIR="$CLAUDE_DIR/rules"

mkdir -p "$SKILLS_DIR"
mkdir -p "$COMMANDS_DIR"
mkdir -p "$RULES_DIR"

# Copy the skill itself
if [ -f "SKILL.md" ] && [ -d "skill" ]; then
  # Create the skill directory inside position-manager
  mkdir -p "$SKILLS_DIR/position-manager/skill"
  cp SKILL.md "$SKILLS_DIR/position-manager/"
  cp skill/*.md "$SKILLS_DIR/position-manager/skill/"
  # Copy pinned dependency reference if present
  if [ -f "package.json.reference" ]; then
    cp package.json.reference "$SKILLS_DIR/position-manager/"
  fi
  echo "✅ Skill installed to $SKILLS_DIR/position-manager"
else
  echo "❌ Error: 'SKILL.md' or 'skill' directory not found."
  exit 1
fi

# Copy rules (namespaced to avoid collision with other skills in a shared kit)
if [ -d "rules" ]; then
  for f in rules/*.md; do
    filename=$(basename "$f")
    cp "$f" "$RULES_DIR/position-manager-${filename}"
  done
  echo "✅ Rules installed to $RULES_DIR (prefixed with 'position-manager-')"
fi

# Copy the optional Claude Code slash command (namespaced)
if [ -d "commands" ]; then
  for f in commands/*.md; do
    filename=$(basename "$f")
    cp "$f" "$COMMANDS_DIR/position-manager-${filename}"
  done
  echo "✅ Slash command installed to $COMMANDS_DIR (prefixed with 'position-manager-')"
fi

echo ""
echo "🎉 Installation complete!"
echo "In Claude Code, the skill triggers automatically based on its description,"
echo "or you can invoke it explicitly with '/position-manager-analyze-breakeven <position_mint_address>'."
echo ""
echo "To use this skill on claude.ai or Claude Cowork instead, zip the"
echo "files and upload them under Settings > Skills."
