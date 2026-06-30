# CLMM Position Manager - PowerShell Installation Script
# Installs the position-manager skill (and, if present, its Claude Code
# slash command and rules) into the local .claude\ directory.

$ErrorActionPreference = "Stop"

Write-Host "Installing CLMM Position Manager & Breakeven Analyzer Skill..." -ForegroundColor Cyan

$ClaudeDir = "$env:USERPROFILE/.claude"
$SkillsDir = "$ClaudeDir/skills"
$CommandsDir = "$ClaudeDir/commands"
$RulesDir = "$ClaudeDir/rules"

# Create directories if they do not exist
New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null
New-Item -ItemType Directory -Force -Path $CommandsDir | Out-Null
New-Item -ItemType Directory -Force -Path $RulesDir | Out-Null

# Copy the skill itself (skill/ already contains SKILL.md as its entry point,
# matching the reference solana-game-skill / solana-dev-skill layout)
if (Test-Path "skill/SKILL.md") {
    $DestSkillDir = "$SkillsDir/position-manager"
    New-Item -ItemType Directory -Force -Path $DestSkillDir | Out-Null
    Copy-Item "skill/*.md" $DestSkillDir -Force
    # Copy pinned dependency reference if present
    if (Test-Path "package.json.reference") {
        Copy-Item "package.json.reference" $DestSkillDir -Force
    }
    Write-Host "✅ Skill installed to $DestSkillDir" -ForegroundColor Green
} else {
    Write-Error "❌ Error: 'skill/SKILL.md' not found."
    Exit 1
}

# Copy rules (namespaced to avoid collision with other skills in a shared kit)
if (Test-Path "rules") {
    Get-ChildItem "rules\*.md" | ForEach-Object {
        Copy-Item $_.FullName "$RulesDir/position-manager-$($_.Name)" -Force
    }
    Write-Host "✅ Rules installed to $RulesDir (prefixed with 'position-manager-')" -ForegroundColor Green
}

# Copy slash commands (namespaced)
if (Test-Path "commands") {
    Get-ChildItem "commands\*.md" | ForEach-Object {
        Copy-Item $_.FullName "$CommandsDir/position-manager-$($_.Name)" -Force
    }
    Write-Host "✅ Slash command installed to $CommandsDir (prefixed with 'position-manager-')" -ForegroundColor Green
}

Write-Host ""
Write-Host "🎉 Installation complete!" -ForegroundColor Green
Write-Host "In Claude Code, the skill triggers automatically based on its description,"
Write-Host "or you can invoke it explicitly with '/position-manager-analyze-breakeven <position_mint_address>'."
Write-Host ""
Write-Host "To use this skill on claude.ai or Claude Cowork instead, zip the"
Write-Host "files and upload them under Settings > Skills."
