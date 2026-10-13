# Codex queue: build each card (full access, Chrome tests, deploys via broker), then a read-only review, then fix-from-review if needed.
#   cx-queue.ps1 -Ids T-01,T-02 -Lane tv
param([Parameter(Mandatory)][string[]]$Ids, [string]$Lane = 'a')
$root = Split-Path -Parent $PSScriptRoot; Set-Location $root
$log = Join-Path $root "docs\tasks\log\cx-queue-$Lane.log"
foreach ($id in @($Ids | ForEach-Object { $_ -split ',' } | Where-Object { $_ })) {
  # work continues while Peter races (CLAUDE.md rule 8): low priority, 2 cores; deploys/live tests refuse by themselves
  try { $me = Get-Process -Id $PID; $me.PriorityClass = 'BelowNormal'; $me.ProcessorAffinity = [IntPtr]0xC000 } catch { }
  Add-Content $log "$(Get-Date -Format s) build $id"
  $card = "docs\cards\v4\$id.md"
  $wrap = "docs\cards\CXB-$id.md"
  [IO.File]::WriteAllText((Join-Path $root $wrap), ("Do the card $card completely. Follow AGENTS.md and CLAUDE.md. Iterate: compile (dash\build.ps1 -NoDeploy / build-irdeck.ps1 -NoDeploy), deploy with dash\build.ps1 (it goes through the deploy broker), run the card's tests (Chrome works in your session) until 0 FAIL (if irdeck-cli.exe state shows sim=True: compile and run the offline/fixture tests only, note 'live check owed' in the report - the deploy and guarded tests refuse by themselves). Real data and behaviour tests, never string-grep tests. Report in AGENTS.md format to docs\tasks\log\$id.md."), (New-Object Text.UTF8Encoding $false))
  & (Join-Path $PSScriptRoot 'cx-run.ps1') -Prompt $wrap -Id "B-$id" -Sandbox workspace-write
  $rv = "docs\cards\RV-$id.md"
  [IO.File]::WriteAllText((Join-Path $root $rv), ("You are the independent reviewer for card $id of PADDOCK (read AGENTS.md, CLAUDE.md, docs\COPY-RULES.md). Do NOT edit anything. Card: $card. Report: docs\tasks\log\$id.md. Judge the code and its tests: every Build step met/partly/missing; real bugs; copy rules on visible text; would the tests FAIL on broken code; anything that could hurt Peter. Verdict line (ACCEPT / ACCEPT WITH FIXES / REJECT), then findings with file:line and a fix. Max 40 lines."), (New-Object Text.UTF8Encoding $false))
  & (Join-Path $PSScriptRoot 'cx-run.ps1') -Prompt $rv -Id "RV-$id"
  $v = (Get-Content (Join-Path $root "docs\tasks\log\cx\RV-$id.last.md") -TotalCount 3 -ErrorAction SilentlyContinue) -join ' '
  Add-Content $log "$(Get-Date -Format s) done $id | $($v.Substring(0, [Math]::Min(100, $v.Length)))"
  if ($v -notmatch '^\W*ACCEPT\W*(-|$|\s{2})' -or $v -match 'WITH FIXES|REJECT') { & (Join-Path $PSScriptRoot 'fix-from-review.ps1') -Ids $id; Add-Content $log "$(Get-Date -Format s) fixed $id" }
}
Add-Content $log "$(Get-Date -Format s) lane finished"