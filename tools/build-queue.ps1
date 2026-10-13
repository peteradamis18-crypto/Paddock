# Build cards one after another: DeepSeek V4.1 Flash builds (oc-card.ps1), then Codex reviews it read-only (cx-run.ps1).
#   build-queue.ps1 -Ids P0-04,P0-05,P0-03
# Each review lands in docs\tasks\log\cx\RV-<id>.last.md; the lead reads the verdicts. Stops if the rig gets busy.
param([Parameter(Mandatory)][string[]]$Ids, [string]$Model = 'deepseek/deepseek-v4.1-flash')
$root = Split-Path -Parent $PSScriptRoot; Set-Location $root
$Ids = @($Ids | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$log = Join-Path $root 'docs\tasks\log\build-queue.log'
foreach ($id in $Ids) {
  # never start a card while Peter is in a session (the card's own deploy would refuse anyway)
  while ((& .\irdeck-cli.exe state | Out-String) -match 'sim=True') { Start-Sleep 60 }
  Add-Content $log "$(Get-Date -Format s) build $id"
  & (Join-Path $PSScriptRoot 'oc-card.ps1') -Card "docs\cards\v4\$id.md" -Id $id -Model $Model
  $rv = Join-Path $root "docs\cards\RV-$id.md"
  $txt = "You are the independent reviewer for card $id of PADDOCK (read AGENTS.md and CLAUDE.md first). Do NOT edit anything.`r`n" +
    "The card: docs\cards\v4\$id.md. The builder's report: docs\tasks\log\$id.md (may be missing = the builder failed). Judge the current code against the card.`r`n" +
    "Check with file:line evidence: every Build step met/partly/missing; real bugs (threads, files deleted, wrong data, C# 5: no `$`"`", ?., nameof, =>, out var); " +
    "copy rules on visible text; whether the test would FAIL on broken code; anything that could hurt Peter (frame rate, acting while he drives, iRacing files).`r`n" +
    "Answer: a verdict line (ACCEPT / ACCEPT WITH FIXES / REJECT), then findings by severity with file:line and a concrete fix. Max 40 lines."
  [IO.File]::WriteAllText($rv, $txt, (New-Object Text.UTF8Encoding $false))
  & (Join-Path $PSScriptRoot 'cx-run.ps1') -Prompt "docs\cards\RV-$id.md" -Id "RV-$id"
  $v = (Get-Content (Join-Path $root "docs\tasks\log\cx\RV-$id.last.md") -TotalCount 3 -EA SilentlyContinue) -join ' '
  Add-Content $log "$(Get-Date -Format s) done $id | review: $($v.Substring(0, [Math]::Min(120, $v.Length)))"
  # not a clean ACCEPT -> Codex fixes the findings before the next card (the lead still judges the result)
  if ($v -notmatch '^\W*ACCEPT\W*(-|$|\s{2})' -or $v -match 'WITH FIXES|REJECT') {
    & (Join-Path $PSScriptRoot 'fix-from-review.ps1') -Ids $id
    Add-Content $log "$(Get-Date -Format s) fixed $id from review (see docs\tasks\log\$id-fix.md)"
  }
}
Add-Content $log "$(Get-Date -Format s) queue finished"
