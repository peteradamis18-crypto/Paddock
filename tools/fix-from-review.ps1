# Send a card's review findings back to Codex to fix (Peter's Pro plan): fix-from-review.ps1 -Ids P0-05,P0-04
# Uses docs\tasks\log\cx\RV-<id>.last.md; writes docs\tasks\log\<id>-fix.md; never deploys while the sim runs.
param([Parameter(Mandatory)][string[]]$Ids)
$root = Split-Path -Parent $PSScriptRoot; Set-Location $root
foreach ($id in @($Ids | ForEach-Object { $_ -split ',' } | Where-Object { $_ })) {
  $card = if (Test-Path "docs\cards\v4\$id.md") { "docs\cards\v4\$id.md" } else { "docs\cards\$id.md" }
  $txt = "# FIX $id from its review`r`nRead AGENTS.md, CLAUDE.md, the card $card, the builder's report docs\tasks\log\$id.md and the review docs\tasks\log\cx\RV-$id.last.md. " +
    "Fix EVERY finding in the review (critical and high first), in the card's files only (smallest edit elsewhere, reported). Add or strengthen the tests the review calls weak so they FAIL on the broken behaviour. C# 5 only. " +
    "Compile with powershell -ExecutionPolicy Bypass -File dash\build.ps1 -NoDeploy (irdeck: build-irdeck.ps1 -NoDeploy). Deploy and run the card's tests ONLY if .\irdeck-cli.exe state shows sim=False (exit 2 = stop). " +
    "Report in AGENTS.md format to docs\tasks\log\$id-fix.md: each finding -> fixed how (file:line) or why not."
  [IO.File]::WriteAllText((Join-Path $root "docs\cards\FIX-$id.md"), $txt, (New-Object Text.UTF8Encoding $false))
  & (Join-Path $PSScriptRoot 'cx-run.ps1') -Prompt "docs\cards\FIX-$id.md" -Id "FIX-$id" -Sandbox workspace-write
}
