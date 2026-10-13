# What Grok has done, what it is doing, and anything that needs Peter - written to a text file and opened in Notepad.
#   powershell -ExecutionPolicy Bypass -File tools\grok-progress.ps1 [-NoNotepad]
param([switch]$NoNotepad)
$r = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\tasks\log'
$o = Join-Path $env:TEMP 'paddock-progress.txt'
$run = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'grok-run\.ps1' } | ForEach-Object {
  if ($_.CommandLine -match '-Idea') { 'writing a new idea card' } elseif ($_.CommandLine -match '-Card (C-\d+)( -Review)?') { $Matches[1] + $(if ($Matches[2]) { ' (review)' } else { '' }) } })
$queue = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'grok-queue\.ps1' }).Count -gt 0
$lines = New-Object Collections.Generic.List[string]
$lines.Add('PADDOCK - GROK PROGRESS   ' + (Get-Date -Format 'ddd d MMM HH:mm'))
$lines.Add('')
$lines.Add('Working on now: ' + $(if ($run) { $run -join ', ' } else { 'nothing' }) + $(if ($queue) { '   (more tasks queued)' } elseif (-not $run) { '   - double-click "Grok - Build all" to start' } else { '' }))
if (Test-Path (Join-Path (Split-Path $r) 'STOP')) { $lines.Add('A stop was requested: Grok stops after the current task.') }
$lines.Add('')
$lines.Add('RESULTS   (NEEDS PETER = something only you can do)')
foreach ($f in Get-ChildItem $r -Filter 'C-*.md' | Where-Object { $_.Name -notmatch 'review' } | Sort-Object Name) {
  $c = $f.BaseName
  $res = (Select-String -Path $f.FullName -Pattern '^RESULT:' | Select-Object -First 1).Line
  $np = (Select-String -Path $f.FullName -Pattern '^NEEDS PETER:' | Select-Object -First 1).Line
  $rv = Join-Path $r "$c.review.md"
  $v = if (Test-Path $rv) { (Select-String -Path $rv -Pattern '^VERDICT:' | Select-Object -First 1).Line } else { 'not reviewed yet' }
  $lines.Add("  $c   $res   |   $v")
  if ($np -and $np -notmatch 'NEEDS PETER:\s*(none|-)?\s*$') { $lines.Add("        $np") }
}
$lines.Add('')
$lines.Add('LAST QUEUE LINES')
if (Test-Path (Join-Path $r 'queue.txt')) { Get-Content (Join-Path $r 'queue.txt') -Tail 10 | ForEach-Object { $lines.Add($_) } }
$lines | Set-Content $o -Encoding UTF8
if (-not $NoNotepad) { Start-Process notepad.exe $o } else { $lines }
