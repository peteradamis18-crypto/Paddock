# Runs task cards one after another with tools\grok-run.ps1 until the list is done or the Grok usage limit is reached.
#   powershell -ExecutionPolicy Bypass -File tools\grok-queue.ps1 -Cards C-01,C-02,C-04
# Progress: docs\tasks\log\queue.txt (one line per card). Only one queue runs at a time.
#   powershell -ExecutionPolicy Bypass -File tools\grok-queue.ps1 -AllOpen     (every card whose Status starts with 'open', in file order)
param([string[]]$Cards, [switch]$AllOpen)
$root = Split-Path -Parent $PSScriptRoot
$Cards = @($Cards | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($AllOpen) {
  $txt = [IO.File]::ReadAllText((Join-Path $root 'docs\TASKS.md'))
  $Cards = @([regex]::Matches($txt, '(?m)^## (C-\d+) .*\r?\nStatus: open(?! \(after)') | ForEach-Object { $_.Groups[1].Value })
  # cards waiting on others ('open (after C-xx)') follow once nothing else is open
  $Cards += @([regex]::Matches($txt, '(?m)^## (C-\d+) .*\r?\nStatus: open \(after') | ForEach-Object { $_.Groups[1].Value })
}
$mx = New-Object Threading.Mutex($false, 'Local\paddock-grok-queue'); if (-not $mx.WaitOne(0)) { 'a grok queue is already running'; exit 0 }
$q = Join-Path $root 'docs\tasks\log\queue.txt'; New-Item -ItemType Directory -Force (Split-Path $q) | Out-Null
"queue start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $($Cards -join ', ')" | Add-Content $q -Encoding UTF8
foreach ($c in $Cards) {
  # one Grok card at a time: wait while a card started elsewhere (an older queue, or by hand) is still running
  while (@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'grok-run\.ps1' }).Count -gt 0) { Start-Sleep -Seconds 30 }
  if (Test-Path (Join-Path $root 'docs\tasks\STOP')) { "queue stopped: STOP file (Grok - Stop)" | Add-Content $q -Encoding UTF8; break }
  # skip cards finished meanwhile (re-read: Grok or the lead may have changed the Status line)
  $now = [IO.File]::ReadAllText((Join-Path $root 'docs\TASKS.md'))
  $sm = [regex]::Match($now, "(?m)^## $([regex]::Escape($c)) .*\r?\nStatus: (.*)$")
  if ($sm.Success -and $sm.Groups[1].Value -notmatch '^open') { "  $c skipped ($($sm.Groups[1].Value.Substring(0, [Math]::Min(40, $sm.Groups[1].Value.Length))))" | Add-Content $q -Encoding UTF8; continue }
  "  $c start $(Get-Date -Format 'HH:mm:ss')" | Add-Content $q -Encoding UTF8
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'grok-run.ps1') -Card $c
  $rc = $LASTEXITCODE
  $res = Join-Path $root "docs\tasks\log\$c.md"
  $line = if (Test-Path $res) { (Select-String -Path $res -Pattern '^RESULT:' | Select-Object -First 1).Line } else { 'no report' }
  "  $c end $(Get-Date -Format 'HH:mm:ss') exit $rc $line" | Add-Content $q -Encoding UTF8
  if ($rc -eq 9) { "queue stopped: Grok usage limit reached" | Add-Content $q -Encoding UTF8; break }
  if (Test-Path (Join-Path $root 'docs\tasks\STOP')) { "queue stopped: STOP file (Grok - Stop)" | Add-Content $q -Encoding UTF8; break }
  # the strong model reviews (and fixes small things in) the work just done
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'grok-run.ps1') -Card $c -Review
  $rrc = $LASTEXITCODE
  $rv = Join-Path $root "docs\tasks\log\$c.review.md"
  $vline = if (Test-Path $rv) { (Select-String -Path $rv -Pattern '^VERDICT:' | Select-Object -First 1).Line } else { 'no review' }
  "  $c review exit $rrc $vline" | Add-Content $q -Encoding UTF8
  if ($rrc -eq 9) { "queue stopped: Grok usage limit reached" | Add-Content $q -Encoding UTF8; break }
  if (Test-Path (Join-Path $root 'docs\tasks\STOP')) { "queue stopped: STOP file (Grok - Stop)" | Add-Content $q -Encoding UTF8; break }
}
"queue end $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Add-Content $q -Encoding UTF8
