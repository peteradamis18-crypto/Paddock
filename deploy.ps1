# Waits until no iRacing session is running, then rebuilds the Stream Deck profile and restarts Stream Deck
# in the background (no window). Progress goes to deploy.log.
$d = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $d 'deploy.log'
function W($m) { Add-Content -LiteralPath $log ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }
W 'waiting for the sim session to end'
$deadline = (Get-Date).AddHours(3)
while ((Get-Date) -lt $deadline) {
  $s = & "$d\irdeck-cli.exe" state | Select-Object -Last 1
  if ($s -notmatch 'telemetry=on') { break }
  Start-Sleep -Seconds 15
}
if ((Get-Date) -ge $deadline) { W 'gave up waiting after 3 hours'; exit 1 }
W 'no session running - deploying'
Stop-Process -Name StreamDeck -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $d 'build-deck.ps1') 2>&1
$out | ForEach-Object { W "build: $_" }
Start-Process 'C:\Program Files\Elgato\StreamDeck\StreamDeck.exe' -ArgumentList '--runinbk'
Start-Sleep -Seconds 12
W ('Stream Deck running: ' + [bool](Get-Process StreamDeck -ErrorAction SilentlyContinue))
