# hud-flag.ps1 - hides or brings back iRacing's own on-screen flag panel ("GO GO GO!!! Green Flag"). Peter 2026-11-02: the lights and Paddock are the flag.
# The panel is taken to be iRacing's Priority Message Box, so its other messages (pit limiter, damage) go with it.
# Only with the sim closed: the sim keeps this file in memory and writes it back. A backup is kept beside the file.
#   powershell -ExecutionPolicy Bypass -File tools\hud-flag.ps1 -Off      (-On brings it back)
param([switch]$Off, [switch]$On, [string]$File = '', [switch]$NoSimCheck)
if ($Off -eq $On) { 'say -Off or -On'; exit 1 }
if (-not $File) {
  $File = Join-Path $env:USERPROFILE 'OneDrive\Documents\iRacing\profiles\hud\Baseline.ini'
  if (-not (Test-Path -LiteralPath $File)) { $File = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\profiles\hud\Baseline.ini' }
}
if (-not (Test-Path -LiteralPath $File)) { "not found: $File"; exit 1 }
if (-not $NoSimCheck -and (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue)) { 'the sim is running: nothing changed'; exit 2 }
$text = [IO.File]::ReadAllText($File)
$nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
$m = [regex]::Match($text, '(?ms)^\[Drive_PriorityMessageBox\][^\r\n]*\r?\n(.*?)(?=^\[|\z)')
if (-not $m.Success) { 'no [Drive_PriorityMessageBox] section: nothing changed'; exit 1 }
$body = $m.Groups[1].Value
$clean = [regex]::Replace($body, '(?m)^visibility=[^\r\n]*\r?\n', '')
$new = if ($Off) { "visibility=0$nl$clean" } else { $clean }
if ($new -ceq $body) { 'already that way: nothing changed'; exit 0 }
$bak = $File + '.bak-flag-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item -LiteralPath $File -Destination $bak
$g = $m.Groups[1]
[IO.File]::WriteAllText($File, $text.Substring(0, $g.Index) + $new + $text.Substring($g.Index + $g.Length), (New-Object Text.UTF8Encoding $false))
if ($Off) { "iRacing's on-screen flag is off (backup: $bak)" } else { "iRacing's on-screen flag is back on (backup: $bak)" }
