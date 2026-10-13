# How fast the Stream Deck add-on (deck-intro\plugin.html) opens its screens and reacts, before and after the 2026-10-09 speed-up.
#   powershell -ExecutionPolicy Bypass -File tests\deck-speed-test.ps1            harness run: old add-on (1.4.0.0) and new, in a hidden Chrome tab
#   ... -Long                                                                      also: hidden for 5+ minutes, where Chrome slows timers to once a minute (takes ~7 min)
#   ... -Live                                                                      the real deck: asks the installed add-on to open each screen once and reads its timing lines
#   ... -Log                                                                       print the timing lines the installed add-on has written so far (your own presses)
#   ... -Boot                                                                      Windows start -> Stream Deck keys usable, from the Stream Deck and irdeck logs
# The harness runs the real plugin page inside Chrome with a pretend Stream Deck app (tests\deck-mock.js). The pretend app
# takes 150 ms to show a profile after being asked: that number is an ASSUMPTION (the real app's time is not known; -Live
# and -Log read it from the real deck). The plugin page is put in a background tab, which is how the Stream Deck app
# keeps it, so Chrome slows its setTimeout/setInterval exactly like it does there. Nothing here touches the real deck.
param([switch]$Long, [switch]$Live, [switch]$Log, [switch]$Boot)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\deck-harness.ps1')
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = 'http://localhost:8199'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function J($p) { $r = Invoke-WebRequest -UseBasicParsing "$api$p" -TimeoutSec 8; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
$spLog = Join-Path $env:APPDATA 'Elgato\StreamDeck\logs\com.peter.rigintro0.log'

if ($Boot) {
  'Windows start -> Stream Deck keys usable (from the logs; the newest Windows start in them)'
  $os = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  "  Windows started          $($os.ToString('HH:mm:ss'))"
  $rig = @(Get-Content (Join-Path $root 'irdeck.log') | Where-Object { $_ -match '> rigon --boot|rigon: (started StreamDeck|Stream Deck is ready|Stream Deck not ready|iRacing UI is on)' })
  $stamp = { param($l) [datetime]::ParseExact($l.Substring(0, 23), 'yyyy-MM-dd HH:mm:ss.fff', $null) }
  $mine = @($rig | Where-Object { (& $stamp $_) -ge $os } | Select-Object -First 8)
  foreach ($l in $mine) { $t = & $stamp $l; "  {0}   +{1,5:0.0} s  {2}" -f $t.ToString('HH:mm:ss'), ($t - $os).TotalSeconds, $l.Substring(25).Trim() }
  # the Stream Deck log of the app instance that started first after Windows did (the one rigon started)
  $best = $null
  foreach ($f in Get-ChildItem (Join-Path $env:APPDATA 'Elgato\StreamDeck\logs') -Filter 'StreamDeck*.log') {
    $lines = @(Get-Content $f.FullName | Where-Object { $_ -match 'device attached|\[com\.peter\.rigintro\] Plugin connected|Application event loop start' })
    if (-not $lines) { continue }
    $t0 = [datetimeoffset]::Parse($lines[0].Substring(0, 29)).LocalDateTime
    if ($t0 -ge $os -and (-not $best -or $t0 -lt $best.t0)) { $best = [pscustomobject]@{ t0 = $t0; lines = $lines } }
  }
  if ($best) { foreach ($l in $best.lines | Select-Object -First 3) { $t = [datetimeoffset]::Parse($l.Substring(0, 29)).LocalDateTime; "  {0}   +{1,5:0.0} s  {2}" -f $t.ToString('HH:mm:ss'), ($t - $os).TotalSeconds, (($l.Substring(29) -replace '\s{2,}', ' ').Trim() -replace '^.*?(inf|war) ', '') } }
  else { '  (no Stream Deck log since Windows started)' }
  return
}

if ($Log) {
  "Timing lines the installed add-on wrote ($spLog)"
  if (Test-Path $spLog) { Get-Content $spLog | Where-Object { $_ -match 'perf |speedtest' } | Select-Object -Last 30 } else { '  no log yet' }
  return
}

if ($Live) {
  'Live deck test: the installed add-on opens each screen once and times it. The deck flips to the screen for about 6 seconds and back.'
  $st = & (Join-Path $root 'irdeck-cli.exe') state
  if ($st -match 'onTrack=True') { 'You are in the car - not now.'; exit 1 }
  foreach ($which in 'friends', 'overlays', 'mydrive') {
    $n0 = if (Test-Path $spLog) { @(Get-Content $spLog).Count } else { 0 }
    try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/do?c=mdspeedtest&a=$which" -TimeoutSec 5 } catch { Check "$which test was accepted by irdash (is the new irdash running?)" $false; continue }
    $got = @()
    for ($i = 0; $i -lt 40 -and $got.Count -lt 1; $i++) { Start-Sleep -Milliseconds 500; if (Test-Path $spLog) { $got = @(Get-Content $spLog | Select-Object -Skip $n0 | Where-Object { $_ -match "perf $which open" }) } }
    Check "$which opened on the real deck and was timed" ($got.Count -ge 1)
    $got | ForEach-Object { "        $_" }
    Start-Sleep -Seconds 8
  }
  "$pass passed, $fail failed"
  return
}

# ---------------- harness run ----------------
if ((& (Join-Path $root 'irdeck-cli.exe') state) -match 'onTrack=True') { 'You are in the car - run this out of the car.'; exit 1 }
$plugins = [ordered]@{ 'old 1.4.0.0' = (Join-Path $root 'tests\deck-speed-baseline\plugin-1.4.0.0.html'); 'new' = (Join-Path $root 'deck-intro\plugin.html') }
$fx = @{ '/guest' = (J '/guest'); '/overlays' = (J '/overlays'); '/showcase' = @{ seq = 0; play = $false; driving = $false } }
$fx['/guest'].wheel = 'light'; $fx['/guest'].session = $false; $fx['/guest'].active = $false
. (Join-Path $root 'tests\deck-fixtures.ps1')
$fx['/mydrive'] = New-MyDriveFixture

function Run-Scenarios($name, $pluginPath, [switch]$Visible) {
  $html = Join-Path $env:TEMP ('deck-speed-' + ($name -replace '\W', '') + '.html')
  $url = Build-DeckHarness $pluginPath $html
  $b = Start-DeckBrowser
  try {
    $page = New-DeckPage $b $url -Hidden:(-not $Visible)
    Start-Sleep -Milliseconds 600
    Start-DeckAddon $page $fx
    Start-Sleep -Seconds 4.5
    $r = [ordered]@{ name = $name; visibility = (Invoke-DeckJs $page '__sd.visibility()') }
    foreach ($which in 'friends', 'overlays', 'mydrive') {
      if ($which -eq 'mydrive' -and $name -like 'old*') { continue }
      $m = Invoke-DeckJs $page "__sd.measureOpen('$which')"
      $r["$which-open"] = $m
      Start-Sleep -Milliseconds 600
      # idle on the screen for 8 s: how often it looks again, and how much picture work it does
      $idle = Invoke-DeckJs $page "(async () => { __sd.pngCalls = 0; __sd.pngMs = 0; const t0 = performance.now(); const i0 = __sd.imgLog.length; await __sd.sleep(8000); return { png: __sd.pngCalls, pngMs: Math.round(__sd.pngMs), pictures: __sd.imgLog.length - i0, guest: __sd.fetchTimes('/guest', t0), overlays: __sd.fetchTimes('/overlays', t0), mydrive: __sd.fetchTimes('/mydrive', t0) }; })()"
      $r["$which-idle"] = $idle
      if ($which -eq 'friends') {
        # press FULL (wheel): how fast the press shows, when the white flash ends, when the choice shows gold
        $null = Invoke-DeckJs $page "(() => { const g = __sd.fx['/guest']; g.wheel = 'light'; __sd.onApi = p => { if (p.includes('c=wheel')) __sd.later(150, () => { g.wheel = 'full'; }); }; return 1; })()"
        $tl = Invoke-DeckJs $page "(async () => { const t0 = performance.now(); __sd.pressTile(7, 2); await __sd.sleep(5000); return await __sd.timeline(__sd.tileCtx(7, 2), t0); })()"
        $r['friends-press'] = @($tl)
        $null = Invoke-DeckJs $page "(() => { __sd.fx['/guest'].wheel = 'light'; return 1; })()"
      }
      if ($which -eq 'mydrive') { $null = Save-DeckSheet $page (Join-Path $shots ("speed-mydrive-" + ($name -replace '\W', '') + ".png")) }
      if ($which -eq 'friends') { $null = Save-DeckSheet $page (Join-Path $shots ("speed-friends-" + ($name -replace '\W', '') + ".png")) }
      # back to the home page: EXIT is at (7,0) on friends, (7,3) on overlays and mydrive
      $null = Invoke-DeckJs $page "(async () => { __sd.pressTile(7, $(if ($which -eq 'friends') { 0 } else { 3 })); await __sd.sleep(700); return __sd.cur; })()"
      Start-Sleep -Milliseconds 400
    }
    return $r
  }
  finally { Stop-DeckBrowser $b }
}

function Gaps($times) { $t = @($times); if ($t.Count -lt 2) { return 0 }; $m = 0; for ($i = 1; $i -lt $t.Count; $i++) { $m = [math]::Max($m, $t[$i] - $t[$i - 1]) }; [math]::Round($m) }
function Flash($tl) {
  $t = @($tl); $w = @($t | Where-Object { $_.look -eq 'white' })[0]; $g = @($t | Where-Object { $_.look -eq 'gold' })[0]
  $e = if ($w) { @($t | Where-Object { $_.ms -gt $w.ms -and $_.look -ne 'white' })[0] } else { $null }
  @{ first = $(if ($t.Count) { $t[0].ms } else { -1 }); white = $(if ($w) { $w.ms } else { -1 }); end = $(if ($e) { $e.ms } else { -1 }); gold = $(if ($g) { $g.ms } else { -1 }) }
}
function Ms($v) { if ($v -lt 0) { 'never' } else { $v } }

'Deck speed test (hidden background tab, pretend Stream Deck app that takes 150 ms to show a profile)'
$res = @{}
foreach ($k in $plugins.Keys) { "  running the $k add-on ..."; $res[$k] = Run-Scenarios $k $plugins[$k] }
''
'                                          old 1.4.0.0       new'
function Row($label, $o, $n) { '  {0,-38} {1,12}  {2,12}' -f $label, $o, $n }
$o = $res['old 1.4.0.0']; $n = $res['new']
Row 'page is in the background' $o.visibility $n.visibility
foreach ($w in 'friends', 'overlays') {
  Row "$w : press -> profile switch asked (ms)" ([math]::Round($o["$w-open"].switchSentMs)) ([math]::Round($n["$w-open"].switchSentMs))
  Row "$w : press -> first picture (ms)" ([math]::Round($o["$w-open"].firstPictureMs)) ([math]::Round($n["$w-open"].firstPictureMs))
  Row "$w : press -> all 32 pictures (ms)" ([math]::Round($o["$w-open"].allPicturesMs)) ([math]::Round($n["$w-open"].allPicturesMs))
  Row "$w : looks again, per 8 s open" (@($o["$w-idle"].$(if ($w -eq 'friends') { 'guest' } else { 'overlays' })).Count) (@($n["$w-idle"].$(if ($w -eq 'friends') { 'guest' } else { 'overlays' })).Count)
  Row "$w : biggest gap between looks (ms)" (Gaps $o["$w-idle"].$(if ($w -eq 'friends') { 'guest' } else { 'overlays' })) (Gaps $n["$w-idle"].$(if ($w -eq 'friends') { 'guest' } else { 'overlays' }))
  Row "$w : PNG pictures made per 8 s open" $o["$w-idle"].png $n["$w-idle"].png
  Row "$w : key pictures sent per 8 s open" $o["$w-idle"].pictures $n["$w-idle"].pictures
}
$fo = Flash $o['friends-press']; $fn = Flash $n['friends-press']
Row 'friends : press first changes the key (ms)' (Ms $fo.first) (Ms $fn.first)
Row 'friends : white press flash shows (ms)' (Ms $fo.white) (Ms $fn.white)
Row 'friends : flash ends (ms)' (Ms $fo.end) (Ms $fn.end)
Row 'friends : chosen wheel turns gold (ms)' (Ms $fo.gold) (Ms $fn.gold)
Row 'my drive : press -> all 32 pictures (ms)' '-' ([math]::Round($n['mydrive-open'].allPicturesMs))
''
Check 'new: FRIENDS shows all 32 keys within 40 ms of the deck being ready' ($n['friends-open'].allPicturesMs - $n['friends-open'].firstAppearMs -lt 40 -and $n['friends-open'].allPicturesMs -gt 0)
Check 'new: OVERLAYS shows all 32 keys within 40 ms of the deck being ready' ($n['overlays-open'].allPicturesMs - $n['overlays-open'].firstAppearMs -lt 40 -and $n['overlays-open'].allPicturesMs -gt 0)
Check 'new: MY DRIVE shows all 32 keys within 40 ms of the deck being ready' ($n['mydrive-open'].allPicturesMs - $n['mydrive-open'].firstAppearMs -lt 40 -and $n['mydrive-open'].allPicturesMs -gt 0)
Check 'new: the press flash ends within 450 ms in a background page (old: needs a throttled timer)' ($fn.end -gt 0 -and $fn.end -lt 450)
Check 'new: the chosen wheel shows gold within 450 ms (old waits for the next slow look)' ($fn.gold -gt 0 -and $fn.gold -lt 450)
Check 'new: an open screen looks again about every 0.7 s, never slower than 1.2 s' (@($n['friends-idle'].guest).Count -ge 9 -and (Gaps $n['friends-idle'].guest) -lt 1200)
Check 'new: an unchanged screen makes almost no PNG pictures (cached)' ($n['friends-idle'].png -le 6 -and $n['overlays-idle'].png -le 6)
Check 'new: no key picture is re-sent while nothing changes' ($n['overlays-idle'].pictures -le 4)
$src = [IO.File]::ReadAllText($plugins['new'])
$timers = [regex]::Matches($src, '\b(setTimeout|setInterval)\(').Count
Check 'new: no page timer in the add-on: only the worker''s own timer and the fallback inside sleep() (setTimeout/setInterval calls = 2)' ($timers -eq 2)
Check 'new: the press shows on the key at once (white flash within 50 ms; the old add-on never showed it)' ($fn.white -ge 0 -and $fn.white -lt 50)
Check 'new: opening a screen writes a timing line to the plugin log' (@($n['friends-open']).Count -gt 0)

if ($Long) {
  ''
  'Long run: both add-ons in background tabs for 5.5 minutes, then FRIENDS press -> chosen (Chrome slows a long-hidden page to one timer a minute)'
  $bL = Start-DeckBrowser 9353
  try {
    $pages = @{}
    foreach ($k in $plugins.Keys) {
      $html = Join-Path $env:TEMP ('deck-speed-long-' + ($k -replace '\W', '') + '.html')
      $pages[$k] = New-DeckPage $bL (Build-DeckHarness $plugins[$k] $html) -Hidden
      Start-Sleep -Milliseconds 500
      Start-DeckAddon $pages[$k] $fx
    }
    Start-Sleep -Seconds 330
    foreach ($k in $plugins.Keys) {
      $pg = $pages[$k]
      $null = Invoke-DeckJs $pg "(async () => { await __sd.measureOpen('friends'); await __sd.sleep(800); const g = __sd.fx['/guest']; g.wheel = 'light'; __sd.onApi = p => { if (p.includes('c=wheel')) __sd.later(150, () => { g.wheel = 'full'; }); }; return 1; })()"
      $tl = Invoke-DeckJs $pg "(async () => { const t0 = performance.now(); __sd.pressTile(7, 2); await __sd.sleep(70000); return await __sd.timeline(__sd.tileCtx(7, 2), t0); })()"
      $f = Flash $tl
      "  {0,-12} white flash {1} ms, flash ends {2} ms, chosen turns gold {3} ms" -f $k, $f.white, $f.end, $f.gold
      $res["long-$k"] = $f
    }
    $fl = $res['long-new']
    Check 'new: after 5+ minutes in the background the press still shows within 450 ms' ($fl.gold -gt 0 -and $fl.gold -lt 450)
  }
  finally { Stop-DeckBrowser $bL }
}
''
"$pass passed, $fail failed. Pictures in $shots"
