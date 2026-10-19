# deck-refresh.ps1 - rebuild the Stream Deck MAIN/MORE pages and prove Stream Deck kept them. Never while he drives.
# 2026-10-18: after build-deck.ps1 Stream Deck sometimes dropped the MAIN page at start ("import_profile ERROR ... failbit",
# then "Prune orphaned page"), leaving blank keys. It is intermittent, so this script checks the result and retries (up to 4 times).
#   powershell -ExecutionPolicy Bypass -File tools\deck-refresh.ps1
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\guard.ps1'); Assert-RigFree
$sd = "$env:APPDATA\Elgato\StreamDeck"; $log = "$sd\logs\StreamDeck.log"
$prof = Get-ChildItem "$sd\ProfilesV3" -Directory | Where-Object { try { (Get-Content "$($_.FullName)\manifest.json" -Raw | ConvertFrom-Json).Name -eq 'iRacing GT3' } catch { $false } } | Select-Object -First 1
if (-not $prof) { 'no iRacing GT3 profile found'; exit 1 }
for ($try = 1; $try -le 4; $try++) {
  Get-Process StreamDeck -ErrorAction SilentlyContinue | Stop-Process
  for ($i = 0; $i -lt 20 -and (Get-Process StreamDeck -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
  Start-Sleep 5
  $o = powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-deck.ps1') 2>&1 | Select-String 'built|error|throw|Close' | ForEach-Object { $_.Line }
  "try ${try}: $o"
  $want = @((Get-Content "$($prof.FullName)\manifest.json" -Raw | ConvertFrom-Json).Pages.Pages)
  Start-Sleep 8
  $mark = (Get-Content $log -Tail 1).Substring(0, 19)
  Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '"C:\Program Files\Elgato\StreamDeck\StreamDeck.exe" --runinbk' } | Out-Null
  Start-Sleep 18
  $dirs = @(Get-ChildItem "$($prof.FullName)\Profiles" -Directory | Where-Object { (Get-ChildItem "$($_.FullName)\Images" -File -ErrorAction SilentlyContinue).Count -ge 20 })
  $pruned = @(Get-Content $log -Tail 600 | Select-String 'Prune orphaned|import_profile.*ERROR').Count
  "  pages with pictures: $($dirs.Count) of 2; import errors this start: $pruned"
  if ($dirs.Count -ge 2 -and $pruned -eq 0) { 'deck is whole'; exit 0 }
}
'the deck is NOT whole after 4 tries'; exit 1
