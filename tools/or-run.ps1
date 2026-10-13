# Paddock's cheap-model runner (OpenRouter). Claude (the lead) writes a card; a cheap model does the work here.
#   Code mode:  or-run.ps1 -Card docs\cards\X.md -Files a.cs,b.js [-Test "powershell -File tests\x-test.ps1"] [-Model ...] [-Rounds 4]
#               the model answers with SEARCH/REPLACE blocks; they are applied (originals backed up), the test runs, failures
#               go back to the model, up to -Rounds times.
#   Ask mode:   or-run.ps1 -Ask docs\cards\review-1.md -Files <many> [-Out docs\review\x.md]   (text answer only, no edits)
# Key: Peter's user environment variable OPENROUTER_API_KEY (tools\openrouter-key.cmd) - never printed or logged.
# Every run is logged to docs\tasks\log\or\ with the model, tokens and cost OpenRouter reports.
param(
  [string]$Card, [string]$Ask, [string[]]$Files = @(), [string]$FileList = '', [string]$Test = '', [string]$Out = '',
  [string]$Model = 'deepseek/deepseek-v4.1-flash', [int]$Rounds = 4, [int]$MaxOutTokens = 32000, [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$logDir = Join-Path $root 'docs\tasks\log\or'; New-Item -ItemType Directory -Force $logDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$name = [IO.Path]::GetFileNameWithoutExtension($(if ($Card) { $Card } else { $Ask }))
$log = Join-Path $logDir "$name-$stamp.md"
function L($t) { Add-Content $log $t -Encoding UTF8; Write-Host $t }
function Rel($p) { $f = [IO.Path]::GetFullPath((Join-Path $root $p)); if (-not $f.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "outside the project: $p" }; if ($f -match '(?i)\\(Documents|OneDrive\\Documents)\\iRacing|Program Files') { throw "iRacing files are off limits: $p" }; return $f }

# -FileList: one path per line (or comma separated) - the safe way to pass many files through another powershell
if ($FileList) { $Files = @((Get-Content (Join-Path $root $FileList) -Raw) -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
# a single string with spaces means the list was flattened on the way in (2026-10-11: a review ran on NO code)
$Files = @($Files | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$missing = @($Files | Where-Object { -not (Test-Path (Join-Path $root $_)) })
if ($Ask -and $missing.Count) { Write-Host ("These files do not exist - nothing sent: " + ($missing -join ', ')); exit 3 }

$key = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User')
if (-not $key) { $key = $env:OPENROUTER_API_KEY }
if (-not $key -and -not $DryRun) { Write-Host 'No OpenRouter key on this PC: Peter runs tools\openrouter-key.cmd once.'; exit 2 }

$rules = @'
You are a careful senior engineer working on PADDOCK, an iRacing sim-rig app on Windows (C# 5 compiled by Windows' own
csc - NO $"", ?., nameof, expression-bodied members, out var; no NuGet, no libraries; plain JS/HTML/CSS, no frameworks;
PowerShell 5.1 tests). Premium black/gold look, every visible word must carry information (docs\COPY-RULES.md).
Never touch iRacing's own files. Keep changes minimal and exactly on the card; do not reformat unrelated code.
'@
$editFormat = @'
Answer ONLY with edit blocks, nothing else. For each change:
FILE: relative\path\to\file.ext
<<<<<<< SEARCH
exact existing lines (copied character for character, enough to be unique)
=======
replacement lines
>>>>>>> REPLACE
To create a new file use an empty SEARCH section. Several blocks per file are fine. When the card is fully done and
nothing more is needed, answer exactly: DONE
'@

function FilesText() {
  $sb = New-Object Text.StringBuilder
  foreach ($f in $Files) { $p = Rel $f; if (Test-Path $p) { [void]$sb.AppendLine("=== FILE: $f ==="); [void]$sb.AppendLine([IO.File]::ReadAllText($p)) } else { [void]$sb.AppendLine("=== FILE: $f (does not exist yet) ===") } }
  return $sb.ToString()
}

$script:spent = 0.0
function Call($messages) {
  $body = @{ model = $Model; messages = $messages; max_tokens = $MaxOutTokens; temperature = 0.2; usage = @{ include = $true } } | ConvertTo-Json -Depth 8 -Compress
  if ($DryRun) { L "  (dry run: $([math]::Round($body.Length/4/1000))k tokens would be sent to $Model)"; return 'DONE' }
  $bytes = [Text.Encoding]::UTF8.GetBytes($body)
  for ($try = 1; $try -le 3; $try++) {
    try {
      $r = Invoke-RestMethod 'https://openrouter.ai/api/v1/chat/completions' -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 900 -Headers @{ Authorization = "Bearer $key"; 'HTTP-Referer' = 'https://paddock.local'; 'X-Title' = 'Paddock' }
      $u = $r.usage; $c = 0.0; if ($u -and $u.cost) { $c = [double]$u.cost }; $script:spent += $c
      $sent = [int]($body.Length / 4)
      if ($u -and $u.prompt_tokens -lt $sent / 3) { L "  WARNING: the model saw $($u.prompt_tokens) tokens but about $sent were sent - its answer cannot be trusted" }
      L ("  model {0}: {1} in / {2} out tokens, cost `${3:N4} (run total `${4:N4})" -f $r.model, $u.prompt_tokens, $u.completion_tokens, $c, $script:spent)
      return [string]$r.choices[0].message.content
    } catch { L "  call failed (try $try): $($_.Exception.Message)"; if ($_.Exception.Message -match '402') { throw 'OpenRouter credit or key limit reached (402)' }; Start-Sleep -Seconds (5 * $try) }
  }
  throw 'OpenRouter call failed 3 times'
}

function Apply($text) {
  $problems = @(); $applied = 0
  $pattern = '(?ms)^FILE:\s*(?<f>[^\r\n]+)\r?\n<<<<<<< SEARCH\r?\n(?<s>.*?)^=======\r?\n(?<r>.*?)^>>>>>>> REPLACE'
  $ms = [regex]::Matches($text, $pattern)
  if ($ms.Count -eq 0) { return @{ n = 0; problems = @('no edit blocks found in the answer') } }
  $bk = Join-Path $root "backup\or\$stamp"
  foreach ($m in $ms) {
    $f = $m.Groups['f'].Value.Trim(); $s = $m.Groups['s'].Value; $r = $m.Groups['r'].Value
    try { $p = Rel $f } catch { $problems += $_.Exception.Message; continue }
    if (Test-Path $p) {
      $b = Join-Path $bk $f; if (-not (Test-Path $b)) { New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null; Copy-Item $p $b }
      $raw = [IO.File]::ReadAllText($p); $bom = ([IO.File]::ReadAllBytes($p) | Select-Object -First 3) -join ',' -eq '239,187,191'
      $nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
      $s2 = ($s -replace "`r`n", "`n") -replace "`n", $nl; $r2 = ($r -replace "`r`n", "`n") -replace "`n", $nl
      if ($s2.Length -eq 0) { $problems += "$f exists: an empty SEARCH would overwrite it - use a real SEARCH"; continue }
      $i = $raw.IndexOf($s2, [StringComparison]::Ordinal)
      if ($i -lt 0) { $problems += "$f : SEARCH text not found (copy it exactly from the file)"; continue }
      if ($raw.IndexOf($s2, $i + 1, [StringComparison]::Ordinal) -ge 0) { $problems += "$f : SEARCH text is not unique (add more lines)"; continue }
      $new = $raw.Substring(0, $i) + $r2 + $raw.Substring($i + $s2.Length)
      [IO.File]::WriteAllText($p, $new, (New-Object Text.UTF8Encoding $bom)); $applied++
      L "  edited $f"
    } else {
      if ($s.Trim().Length -gt 0) { $problems += "$f does not exist: use an empty SEARCH to create it"; continue }
      New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
      [IO.File]::WriteAllText($p, $r, (New-Object Text.UTF8Encoding $false)); $applied++
      L "  created $f"
    }
  }
  return @{ n = $applied; problems = $problems }
}

function SimBusy { try { return ((& (Join-Path $root 'irdeck-cli.exe') state 2>$null) -join ' ') -match 'sim=True|telemetry=on' } catch { return $false } }

L "# or-run $name $stamp"
L "model $Model; files: $($Files -join ', '); test: $Test"
if ($Ask) {
  $q = [IO.File]::ReadAllText((Rel $Ask))
  $ft = FilesText
  L ("  sending {0} files, about {1}k tokens of code" -f $Files.Count, [int]($ft.Length / 4 / 1000))
  $msgs = @(@{ role = 'system'; content = $rules }, @{ role = 'user'; content = $q + "`n`n" + $ft })
  $ans = Call $msgs
  $dest = if ($Out) { Rel $Out } else { Join-Path $logDir "$name-$stamp.answer.md" }
  New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
  [IO.File]::WriteAllText($dest, $ans, (New-Object Text.UTF8Encoding $false))
  L "answer written to $dest"
  L ("TOTAL cost `${0:N4}" -f $script:spent); exit 0
}

$cardText = [IO.File]::ReadAllText((Rel $Card))
$msgs = New-Object System.Collections.ArrayList
[void]$msgs.Add(@{ role = 'system'; content = $rules + "`n" + $editFormat })
[void]$msgs.Add(@{ role = 'user'; content = "CARD:`n$cardText`n`nCURRENT FILES:`n$(FilesText)" })
$result = 'not finished'
for ($round = 1; $round -le $Rounds; $round++) {
  L "## round $round"
  $ans = Call $msgs
  [void]$msgs.Add(@{ role = 'assistant'; content = $ans })
  if ($ans.Trim() -eq 'DONE') { $result = 'model says DONE'; break }
  $a = Apply $ans
  $feedback = @()
  if ($a.problems.Count) { $feedback += "These edits were NOT applied:`n- " + ($a.problems -join "`n- ") }
  if ($Test -and $a.n -gt 0) {
    if (SimBusy) { L '  Peter is in the sim: test not run (edits kept)'; $result = 'edits applied, test postponed (sim running)'; break }
    L "  test: $Test"
    $out = (cmd /c $Test 2>&1 | Out-String); $code = $LASTEXITCODE
    $tail = ($out -split "`r?`n" | Where-Object { $_ -match 'FAIL|passed|failed|error|Error' } | Select-Object -Last 40) -join "`n"
    L "  test exit $code; $((($out -split "`r?`n") | Where-Object { $_ -match '\d+ passed, \d+ failed' } | Select-Object -Last 1))"
    if ($code -eq 0 -and $out -match ' 0 failed') { if (-not $a.problems.Count) { $result = 'test passed'; break } }
    else { $feedback += "The test failed (exit $code). Relevant lines:`n$tail" }
  } elseif (-not $Test -and $a.n -gt 0 -and -not $a.problems.Count) { $result = 'edits applied (no test given)'; break }
  if (-not $feedback.Count) { $feedback += 'Continue. If the card is fully done, answer DONE.' }
  [void]$msgs.Add(@{ role = 'user'; content = ($feedback -join "`n`n") + "`n`nCURRENT FILES:`n$(FilesText)" })
}
L "RESULT: $result"
L ("TOTAL cost `${0:N4}; backups in backup\or\$stamp" -f $script:spent)
