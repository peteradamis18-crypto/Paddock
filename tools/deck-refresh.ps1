# deck-refresh.ps1 - rebuild the Stream Deck pages (LEAVE / MAIN / MORE from deck\layout.json) and prove Stream Deck kept them. Never while he drives.
# 2026-10-18: after build-deck.ps1 Stream Deck sometimes dropped the MAIN page at start ("import_profile ERROR ... failbit",
# then "Prune orphaned page"), leaving blank keys. It is intermittent, so this script checks the result and retries (up to 4 times).
# W3-4 review: the key pictures are made FIRST (build-deck.ps1 -Preview renders them in headless Chrome) while Stream Deck still runs; a render
# that fails stops here with Stream Deck untouched. Then each try builds with -NoRender and must print "built:" (and no "NOT DONE"), and the
# profile must list exactly the page ids that build wrote.
#   powershell -ExecutionPolicy Bypass -File tools\deck-refresh.ps1
#   -BuildDeck <script>  tests only (tests\deck-refresh-test.ps1): a pretend build-deck.ps1
param([string]$BuildDeck = '')
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\guard.ps1'); Assert-RigFree
if (-not $BuildDeck) { $BuildDeck = Join-Path $root 'build-deck.ps1' }

# 1. the pictures, before anything is stopped
$pv = & powershell -NoProfile -ExecutionPolicy Bypass -File $BuildDeck -Preview 2>&1 | ForEach-Object { "$_" }
$pvRc = $LASTEXITCODE
$pm = [regex]::Match(($pv -join "`n"), 'preview written to (\S+)')
if ($pvRc -ne 0 -or -not $pm.Success) { "the key pictures could not be made - Stream Deck was not touched: $($pv -join ' ')"; exit 1 }
if (Test-Path $pm.Groups[1].Value) { Remove-Item -LiteralPath $pm.Groups[1].Value -Recurse -Force -ErrorAction SilentlyContinue }

$sd = "$env:APPDATA\Elgato\StreamDeck"; $log = "$sd\logs\StreamDeck.log"
$prof = Get-ChildItem "$sd\ProfilesV3" -Directory | Where-Object { try { (Get-Content "$($_.FullName)\manifest.json" -Raw | ConvertFrom-Json).Name -eq 'iRacing GT3' } catch { $false } } | Select-Object -First 1
if (-not $prof) { 'no iRacing GT3 profile found'; exit 1 }
# the irdash watchdog restarts a closed Stream Deck after 10 s; that restart read a half-written MAIN and Stream Deck then deleted
# MAIN. dash\deck-build.lock (refreshed each try, removed at the end) keeps the watchdog away from close -> build -> start.
$buildLock = Join-Path $root 'dash\deck-build.lock'
$notDone = ''
try {
for ($try = 1; $try -le 4; $try++) {
  [IO.File]::WriteAllText($buildLock, (Get-Date).ToString('o'))
  Get-Process StreamDeck -ErrorAction SilentlyContinue | Stop-Process
  for ($i = 0; $i -lt 20 -and (Get-Process StreamDeck -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
  Start-Sleep 5
  $all = @(powershell -ExecutionPolicy Bypass -File $BuildDeck -NoRender 2>&1 | ForEach-Object { "$_" })
  $o = @($all | Where-Object { $_ -match 'built|error|throw|Close|NOT DONE|pages:' })
  "try ${try}: $($o -join ' | ')"
  $built = @($all | Where-Object { $_ -match '^built: ' }).Count -gt 0
  $nd = @($all | Where-Object { $_ -match '^NOT DONE' }); if ($nd.Count) { $notDone = $nd[0] }
  $ids = @(); $pl = @($all | Where-Object { $_ -match '^pages: ' }); if ($pl.Count) { $ids = @($pl[0].Substring(7).Trim() -split '\s+') }
  $want = @((Get-Content "$($prof.FullName)\manifest.json" -Raw | ConvertFrom-Json).Pages.Pages)
  Start-Sleep 8
  $mark = (Get-Content $log -Tail 1).Substring(0, 19)
  Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '"C:\Program Files\Elgato\StreamDeck\StreamDeck.exe" --runinbk' } | Out-Null
  Start-Sleep 18
  if (-not $built) { 'build-deck.ps1 did not build (no "built:" line): the old pages are back on the deck'; exit 1 }
  $sameIds = ($ids.Count -gt 0) -and ((($ids | ForEach-Object { $_.ToUpper() }) -join ',') -eq (($want | ForEach-Object { $_.ToUpper() }) -join ','))
  # every page the build wrote must still be there with one picture per key (MAIN 30, MORE 5, LEAVE 5 ... whatever the build made)
  $dirs = @($want | Where-Object { $d = Join-Path "$($prof.FullName)\Profiles" $_.ToUpper(); (Test-Path "$d\manifest.json") -and ((Get-ChildItem "$d\Images" -File -ErrorAction SilentlyContinue).Count -ge @((Get-Content "$d\manifest.json" -Raw | ConvertFrom-Json).Controllers[0].Actions.PSObject.Properties).Count) -and ((Get-ChildItem "$d\Images" -File -ErrorAction SilentlyContinue).Count -gt 0) })
  $pruned = @(Get-Content $log -Tail 600 | Select-String 'Prune orphaned|import_profile.*ERROR').Count
  "  pages kept whole: $($dirs.Count) of $($want.Count); the profile lists the new pages: $sameIds; import errors this start: $pruned"
  if ($sameIds -and $dirs.Count -eq $want.Count -and $want.Count -ge 2 -and $pruned -eq 0) {
    Remove-Item -LiteralPath $buildLock -Force -ErrorAction SilentlyContinue
    if ($notDone) { "deck rebuilt, but $notDone"; exit 1 }
    'deck is whole'; exit 0
  }
}
Remove-Item -LiteralPath $buildLock -Force -ErrorAction SilentlyContinue; 'the deck is NOT whole after 4 tries'; exit 1
} finally { Remove-Item -LiteralPath $buildLock -Force -ErrorAction SilentlyContinue }
