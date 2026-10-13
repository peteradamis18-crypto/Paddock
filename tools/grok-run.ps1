# Runs ONE task card from docs\TASKS.md with Grok Build in headless mode (Peter's subscription, no API key).
#   powershell -ExecutionPolicy Bypass -File tools\grok-run.ps1 -Card C-02            (build the card)
#   powershell -ExecutionPolicy Bypass -File tools\grok-run.ps1 -Card C-02 -Review    (strong model checks that work)
#   powershell -ExecutionPolicy Bypass -File tools\grok-run.ps1 -Idea "text"          (turn an idea into a new card)
# The card's title '— fast' / '— strong' picks the model unless -Model is given. Output: docs\tasks\log\<card>[.review].out.txt,
# reports: docs\tasks\log\<card>.md and <card>.review.md. Exit 0 = finished, 9 = usage limit reached, 1 = other failure.
param([string]$Card, [switch]$Review, [string]$Idea, [string]$Model, [string]$Effort = 'high', [int]$MaxTurns = 250)
$root = Split-Path -Parent $PSScriptRoot
$grok = Join-Path $env:USERPROFILE '.grok\bin\grok.exe'
$log = Join-Path $root 'docs\tasks\log'; New-Item -ItemType Directory -Force $log | Out-Null
$common = "Obey every safety rule in AGENTS.md: never act while Peter is driving (tests\guard.ps1), never write iRacing's own files, no downloads/installs/credentials unless the card says they are approved, never run deck-intro\install.ps1 or build-deck.ps1, deploy irdash only with dash\build.ps1. Be economical: read only what you need, no subagents. Never sit idle waiting."

if ($Idea) {
  $name = 'idea-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
  if (-not $Model) { $Model = 'grok-4.7' }
  $prompt = "Peter has a new idea for PADDOCK: $Idea`nTurn it into ONE new task card at the end of docs/TASKS.md, numbered after the highest C-number, in exactly the same format as the other cards (title with fast or strong and live/away/offline, Status: open, goal, files, gate, do-not), and add a short entry to the right phase in docs/ROADMAP.md. Read AGENTS.md, docs/ROADMAP.md (principles, decisions, what exists) and the related code first so the card is accurate, realistic and premium (Peter must never have to think; no popups while driving). If the idea is impossible as asked, write the closest great alternative in the card and say why in one line. Do not build anything. Print the new card as your last message. $common"
} elseif ($Card) {
  $tasks = [IO.File]::ReadAllText((Join-Path $root 'docs\TASKS.md'))
  $m = [regex]::Match($tasks, "(?m)^## $([regex]::Escape($Card)) (.+)$")
  if (-not $m.Success) { "no card $Card in docs\TASKS.md"; exit 1 }
  $title = $m.Groups[1].Value
  if ($Review) {
    $name = "$Card.review"
    if (-not $Model) { $Model = 'grok-4.7' }
    $prompt = "You are the REVIEWER for task card $Card ($title) in docs/TASKS.md on PADDOCK (this folder). Another agent just built it. Read AGENTS.md, the card, docs\tasks\log\$Card.md (its report and FILES list) and the changed files. Check: does it meet the card's goal and gate; any rule broken (safety, iRacing files, popups while driving, focus, C# 5, plain-English UI, premium look); bugs; tests that were weakened or skipped. Run the card's tests (guarded) if the rig allows. Fix small, clear problems yourself; leave big ones described. Write docs\tasks\log\$Card.review.md with: VERDICT: PASS | FIXED | NEEDS LEAD, then at most 8 lines (what you checked, what you fixed, what is left). If the verdict is not PASS, also append a line under the card in docs/TASKS.md. Print the review as your last message. $common"
  } else {
    $name = $Card
    # every card on the strong model (lead 2026-10-10: build-fast was not cheaper per card and quality matters more)
    if (-not $Model) { $Model = 'grok-4.7' }
    $prompt = "You are a coding agent on PADDOCK (this folder). Do exactly task card $Card ($title) from docs/TASKS.md - nothing else. First read AGENTS.md (rules, report format), then CLAUDE.md, the card, the ROADMAP/SPEC sections it points to, and the code you will touch. Run the card's tests. Write a first draft of docs\tasks\log\$Card.md early (RESULT: in progress) and keep it updated, so a cut-off run still leaves a report. Finish with the report exactly as AGENTS.md describes, written to docs\tasks\log\$Card.md and printed as your last message, and update the card's Status line in docs/TASKS.md. $common"
  }
} else { 'give -Card C-xx [-Review] or -Idea "text"'; exit 1 }

# Windows PowerShell 5.1 breaks native arguments that contain double quotes: keep the prompt free of them
$prompt = $prompt.Replace('"', "'")
$out = Join-Path $log "$name.out.txt"
"=== $name | model $Model | effort $Effort | start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Set-Content $out -Encoding UTF8
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
$ErrorActionPreference = 'Continue'
& $grok -p $prompt -m $Model --effort $Effort --cwd $root --always-approve --max-turns $MaxTurns --output-format plain --disallowed-tools 'Agent' 2>&1 |
  ForEach-Object { "$_" } | Out-File -FilePath $out -Append -Encoding utf8
$rc = $LASTEXITCODE
"=== end $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') exit $rc" | Add-Content $out -Encoding UTF8
$tail = (Get-Content $out -Tail 40) -join "`n"
if ($tail -match '(?i)usage limit|rate.?limit|quota|too many requests|limit reached|exceeded your|balance exhausted|payment required|status 402') { exit 9 }   # 2026-10-10: 'usage balance exhausted' (HTTP 402) was missed
if ($rc -ne 0) { exit 1 }
exit 0
