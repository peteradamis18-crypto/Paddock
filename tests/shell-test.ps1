# shell-test.ps1 - offline (W3-1): the top screen's shell (dash\www\app\index.html, shell.js, shell.css, pages\*.js) in headless Chrome
# against the pretend irdash (tests\tools\pretend-irdash.exe) on 8341 (control 8342; never 8199, and clear of the 8297-8312 other tests use):
#   1. the four doors mount their page, one at a time; RACES shows the W1-4 grid; Esc (also inside REVIEW's and RIG's frames) and
#      CLOSE go HOME; the deck's nav push opens a page; /api/nav?to=home is sent on close; the hash follows (and leads)
#   2. offline: the banner says the exact sentence and the doors still switch; back online it clears within 5 s;
#      kids, tow, a key message and the page's own line take the one banner in that order
#   3. driving: rig.driving + fresh frames -> the race screen, the page unmounted (listeners counted); a replay, stale frames or
#      no frames do not; 5 s after driving ends HOME is mounted; the stream asks for the race set
#   4. request rate: HOME idle <= 2 / s, driving <= 1 / s besides the stream
#   5-7. ?page= / ?race=1; Friends mode (its layer, pages closed while a guest drives, the clean-lap call); the start-up (never on a
#      window opened while he drives, stopped with its tones when he gets in). Echoes, the deck's HOME, stale messages and Esc in an
#      open session are in 1; every move is checked against Shell.log (which push or message did it).
# Pictures: tests\shots\rework\shell-<state>.png. Frames are made in the page (data.emit): no .ibt and no iRacing needed.
#   powershell -ExecutionPolicy Bypass -File tests\shell-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root 'tests\tools'
. (Join-Path $tools 'cdp-lib.ps1')
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what $why" } }
function Section($t) { Assert-RigFree -Where $t; $t }
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
Remove-Item (Join-Path $shots 'shell-*.png') -ErrorAction SilentlyContinue
$tmp = Join-Path $env:TEMP ('shell-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$fx = Join-Path $tmp 'fixtures'; Copy-Item -Recurse (Join-Path $root 'tests\fixtures\irdash') $fx
$exe = Join-Path $tools 'bin\pretend-irdash.exe'
$PORT = 8341; $CTL = $PORT + 1; $CDP = 9441
$OFFLINE = 'Paddock is not running. Press HOME on the deck.'
'SHELL test (W3-1)'

# three races for the RACES door (the W1-4 list as library.cs sends it)
$now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$races = @(1, 2, 3) | ForEach-Object { '{"id":"s' + $_ + '","track":"' + @('Road Atlanta', 'Lime Rock Park', 'Watkins Glen International')[$_ - 1] + '","config":"Full Course","car":"Toyota GR86","type":"Race","isRace":true,"startMs":' + ($now - $_ * 86400000) + ',"sec":1268,"laps":10,"counted":7,"best":93.832,"bestLap":9,"mb":1101,"kept":false,"thumb":false,"state":{"kind":"none"},"markers":[]}' }
[IO.File]::WriteAllText((Join-Path $fx 'api_library.json'), '{"storage":{"usedGb":412,"freeGb":280,"trashGb":0,"moreRaces":38,"lowSpace":false},"youtube":{"signedIn":true,"privacy":"private","template":1},"titles":[],"races":[' + ($races -join ',') + '],"trash":[]}', (New-Object Text.UTF8Encoding($false)))

function Get-J($url) { try { return Invoke-RestMethod -Uri $url -TimeoutSec 5 } catch { return $null } }
function Push($part, $json) { $null = Get-J ("http://localhost:$CTL/__push?part=$part&json=" + [uri]::EscapeDataString($json)) }
function Key($k = 'Escape', $vk = 27) {
  $null = Cdp 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = $k; code = $k; windowsVirtualKeyCode = $vk; nativeVirtualKeyCode = $vk }
  $null = Cdp 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = $k; code = $k; windowsVirtualKeyCode = $vk; nativeVirtualKeyCode = $vk }
}
function Door($d) { $null = Cdp-Eval "(() => { document.querySelector('.door[data-door=$d]').click(); return 1; })()" }
function Rate() {
  $null = Get-J "http://localhost:$CTL/__reset"
  Start-Sleep -Seconds 20
  $s = Get-J "http://localhost:$CTL/__stats"
  $n = 0; $by = @(); foreach ($p in $s.routes.PSObject.Properties) { if ($p.Name -eq '/stream') { continue }; $n += $p.Value.count; $by += "$($p.Name) x$($p.Value.count)" }
  $opens = $(if ($s.routes.'/stream') { $s.routes.'/stream'.count } else { 0 }); $n += $opens
  [pscustomobject]@{ rate = [math]::Round($n / 20, 2); n = $n; routes = ($by -join ', '); streams = $s.streams; opens = $opens }
}
$one = '(document.getElementById("page").children.length === 1)'
$listeners = '(Object.keys(data.ls).reduce((a, k) => a + data.ls[k].length, 0))'

& (Join-Path $tools 'pretend-irdash.ps1') -Port $PORT -Stop | Out-Null
$null = & (Join-Path $tools 'pretend-irdash.ps1') -Port $PORT -Www (Join-Path $root 'dash\www'); & (Join-Path $tools 'pretend-irdash.ps1') -Port $PORT -Stop | Out-Null   # builds it when its source is newer
$pret = Start-Process -FilePath $exe -ArgumentList @("$PORT", '--fixtures', "`"$fx`"", '--www', "`"$(Join-Path $root 'dash\www')`"") -WindowStyle Hidden -PassThru
try { $pret.PriorityClass = 'BelowNormal' } catch { }
for ($i = 0; $i -lt 40 -and -not (Get-J "http://localhost:$CTL/__stats"); $i++) { Start-Sleep -Milliseconds 150 }
try {
  # ------------------------------------------------------------------ 1. the doors
  Section '1. the four doors, one page at a time, Esc and CLOSE, the deck, the hash'
  Cdp-Open "http://localhost:$PORT/app/index.html?intro=0" -Port $CDP
  ok 'the shell is up on HOME (the placeholder), connected' (Wait-Until 'window.Shell && Shell.cur === "home" && data.online && /HOME is being rebuilt/.test(document.getElementById("page").textContent)' 12)
  $null = Cdp-Eval '(() => { window.__errs = []; addEventListener("error", e => __errs.push(e.message)); addEventListener("unhandledrejection", e => __errs.push(String(e.reason))); return 1; })()'
  $h = Cdp-Json '({ hash: location.hash, on: [...document.querySelectorAll(".door.on")].map(b => b.dataset.door).join(), close: getComputedStyle(document.getElementById("shellClose")).visibility, title: document.title, date: document.getElementById("shellDate").textContent, fs: getComputedStyle(document.querySelector(".door")).fontSize })'
  ok "HOME: hash #/home, the HOME door gold, no CLOSE ($($h.hash) / $($h.on) / $($h.close))" ($h.hash -eq '#/home' -and $h.on -eq 'home' -and $h.close -eq 'hidden')
  ok "the header: the local date ('$($h.date)'), the doors in the type scale ($($h.fs)), the window title irdash looks for ('$($h.title)')" ($h.date -match '^[A-Z][a-z]{2} \d{1,2} [A-Z][a-z]{2}$' -and $h.fs -eq '36px' -and $h.title -eq 'iRacing Dash')
  $base = [int](Cdp-Eval $listeners)
  Cdp-Shot (Join-Path $shots 'shell-home.png')
  Door 'races'
  ok 'RACES: the W1-4 grid (three cards), one page in the page area' (Wait-Until "Shell.cur === 'races' && document.querySelectorAll('#page .rc .card').length === 3 && $one" 8)
  $h = Cdp-Json '({ hash: location.hash, on: [...document.querySelectorAll(".door.on")].map(b => b.dataset.door).join(), close: getComputedStyle(document.getElementById("shellClose")).visibility, told: Shell.told.slice(-1)[0], home: !!document.querySelector("#page .shell-msg") })'
  ok "the hash follows (#/races), the RACES door is gold, CLOSE shows, HOME's placeholder is gone" ($h.hash -eq '#/races' -and $h.on -eq 'races' -and $h.close -eq 'visible' -and -not $h.home)
  ok "irdash is told: $($h.told)" ($h.told -eq '/api/nav?to=races')
  Cdp-Shot (Join-Path $shots 'shell-races.png')
  $null = Cdp-Eval '(() => { document.querySelector("#page .card [data-act=open]").click(); return 1; })()'
  ok 'a race opened on RACES' (Wait-Until '!document.getElementById("open").hidden' 3)
  Key
  ok 'Esc first closes the open race (the page used it): still RACES' (Wait-Until 'document.getElementById("open").hidden && Shell.cur === "races"' 3)
  Key
  ok 'Esc again goes HOME' (Wait-Until 'Shell.cur === "home" && location.hash === "#/home"' 3)
  ok "on close irdash is told /api/nav?to=home ($(Cdp-Eval 'Shell.told.slice(-1)[0]'))" ((Cdp-Eval 'Shell.told.slice(-1)[0]') -eq '/api/nav?to=home')
  ok "RACES left no listener behind ($(Cdp-Eval $listeners) now, $base on HOME before)" ([int](Cdp-Eval $listeners) -eq $base)
  Door 'races'; $null = Wait-Until "Shell.cur === 'races'" 3
  $null = Cdp-Eval '(() => { document.getElementById("shellClose").click(); return 1; })()'
  ok 'CLOSE goes HOME' (Wait-Until 'Shell.cur === "home"' 3)
  Door 'review'
  ok 'REVIEW: the Sessions page in its frame (v2/sessions.html?embed=1)' (Wait-Until "Shell.cur === 'review' && $one && /v2\/sessions\.html\?embed=1/.test((document.querySelector('#page iframe') || {}).src || '') && !!document.querySelector('#page iframe').contentDocument.body && document.querySelector('#page iframe').contentDocument.readyState === 'complete'" 10)
  ok 'its document forwards Esc (hooked)' (Wait-Until '!!document.querySelector("#page iframe").contentDocument.__paddockEsc' 5)
  Start-Sleep -Milliseconds 800
  Cdp-Shot (Join-Path $shots 'shell-review.png')
  $null = Cdp-Eval '(() => { Shell.msgs.length = 0; const f = document.querySelector("#page iframe"); f.focus(); f.contentWindow.focus(); return 1; })()'
  Key
  $r = (Wait-Until 'Shell.cur === "home"' 3) -and ((Cdp-Eval 'Shell.msgs.includes("esc")') -eq $true)
  $r = (Wait-Until 'Shell.cur === "home" && /^home:press:(sessions-close|esc-frame)$/.test(Shell.log.slice(-1)[0])' 3)
  ok "Esc pressed inside REVIEW's frame goes HOME (messages: $(Cdp-Eval 'Shell.msgs.join()'); moves: $(Cdp-Eval 'Shell.log.slice(-2).join(" | ")'))" $r
  Door 'rig'
  ok "RIG: the Performance page in its frame (v2/perf.html?embed=1)" (Wait-Until "Shell.cur === 'rig' && $one && /v2\/perf\.html\?embed=1/.test((document.querySelector('#page iframe') || {}).src || '') && document.querySelector('#page iframe').contentDocument.readyState === 'complete'" 15) "(moves: $(Cdp-Eval 'Shell.log.join(" ")'))"
  Start-Sleep -Milliseconds 800
  Cdp-Shot (Join-Path $shots 'shell-rig.png')
  # inside a frame in the frame (Sessions' nested Analysis is one): Esc still reaches the shell
  $null = Cdp-Eval '(() => { Shell.msgs.length = 0; const d = document.querySelector("#page iframe").contentDocument; const n = d.createElement("iframe"); n.id = "nested"; n.srcdoc = "<p>nested</p>"; d.body.appendChild(n); return 1; })()'
  $null = Wait-Until '(() => { const n = document.querySelector("#page iframe").contentDocument.getElementById("nested"); return !!(n && n.contentDocument && n.contentDocument.readyState === "complete" && n.contentDocument.__paddockEsc); })()' 5
  $null = Cdp-Eval '(() => { const n = document.querySelector("#page iframe").contentDocument.getElementById("nested"); n.contentWindow.document.dispatchEvent(new n.contentWindow.KeyboardEvent("keydown", { key: "Escape", bubbles: true })); return 1; })()'
  $r = (Wait-Until 'Shell.cur === "home"' 3) -and ((Cdp-Eval 'Shell.msgs.includes("esc")') -eq $true)
  ok "Esc inside a frame inside RIG's frame goes HOME too (messages: $(Cdp-Eval 'Shell.msgs.join()'))" $r
  ok "after REVIEW and RIG: still $base listeners (their frames' subscriptions ended)" ([int](Cdp-Eval $listeners) -eq $base) (Cdp-Eval $listeners)
  $told0 = [int](Cdp-Eval 'Shell.told.length')
  Push 'nav' '{"to":"races","seq":50,"driving":false}'
  ok 'the deck asks RACES (nav push, seq rising): RACES opens' (Wait-Until "Shell.cur === 'races' && location.hash === '#/races' && $one" 5)
  ok "the log says which push opened it ($(Cdp-Eval 'Shell.log.slice(-1)[0]'))" ((Cdp-Eval 'Shell.log.slice(-1)[0]') -eq 'races:nav:nav#50')
  ok 'a page irdash asked for is not told back to irdash' ([int](Cdp-Eval 'Shell.told.length') -eq $told0)
  Push 'nav' '{"to":"coach","seq":51,"driving":false}'
  ok 'the old DEBRIEF request (to=coach) opens REVIEW' (Wait-Until "Shell.cur === 'review'" 5)
  Push 'nav' '{"to":"","seq":52,"driving":false}'
  ok 'irdash ends the request (to="", 30 min or a drive): HOME' (Wait-Until "Shell.cur === 'home'" 5)
  ok "the log names that push ($(Cdp-Eval 'Shell.log.slice(-1)[0]'))" ((Cdp-Eval 'Shell.log.slice(-1)[0]') -eq 'home:nav:nav#52')
  Push 'perfNav' '{"to":"perf","seq":9,"driving":false}'
  ok 'the old PERFORMANCE request (perfNav) opens RIG' (Wait-Until "Shell.cur === 'rig'" 5)
  $null = Cdp-Eval '(() => { document.getElementById("shellClose").click(); return 1; })()'
  $null = Wait-Until "Shell.cur === 'home'" 3
  ok "closing it tells irdash both: $(Cdp-Eval 'Shell.told.slice(-2).join(" + ")')" ((Cdp-Eval 'Shell.told.slice(-2).join(" ")') -eq '/api/nav?to=home /api/do?c=perfclose')
  $null = Cdp-Eval '(() => { location.hash = "#/review"; return 1; })()'
  ok 'the hash leads too: #/review mounts REVIEW' (Wait-Until "Shell.cur === 'review' && $one" 5)
  $null = Cdp-Eval '(() => { location.hash = "#/nothing"; return 1; })()'
  ok 'an unknown door is HOME' (Wait-Until "Shell.cur === 'home' && location.hash === '#/home'" 5)

  # the echo: irdash says back what this page told it; that is not a new request. A real deck press right after is.
  # (irdash answers /api/nav with the seq it made, data.cs; the pretend answers these two from fixtures)
  $u8 = New-Object Text.UTF8Encoding($false)
  [IO.File]::WriteAllText((Join-Path $fx 'api_nav~to=races.json'), '{"ok":true,"seq":70}', $u8)
  [IO.File]::WriteAllText((Join-Path $fx 'api_nav~to=home.json'), '{"ok":true,"seq":71}', $u8)
  Door 'races'; $null = Wait-Until "Shell.cur === 'races'" 3
  $null = Cdp-Eval '(() => { document.getElementById("shellClose").click(); return 1; })()'
  $null = Wait-Until "Shell.cur === 'home'" 3
  Push 'nav' '{"to":"races","seq":70,"driving":false}'      # the echo of the RACES press (irdash is slower than this page)
  Push 'nav' '{"to":"home","seq":71,"driving":false}'       # the echo of CLOSE
  Start-Sleep -Milliseconds 500
  ok "the echoes of RACES and CLOSE move nothing ($(Cdp-Eval 'Shell.log.slice(-2).join(" | ")'))" ((Cdp-Eval "Shell.cur === 'home' && Shell.log.slice(-2).join('|') === 'echo races:nav#70|echo home:nav#71'") -eq $true)
  Remove-Item (Join-Path $fx 'api_nav~to=*.json')
  Push 'nav' '{"to":"review","seq":72,"driving":false}'     # the deck's REVIEW, less than 3 s after CLOSE
  ok "a deck press within 3 s of CLOSE opens its page ($(Cdp-Eval 'Shell.log.slice(-1)[0]'))" (Wait-Until "Shell.cur === 'review' && Shell.log.slice(-1)[0] === 'review:nav:nav#72'" 4)
  Push 'nav' '{"to":"home","seq":73,"driving":false}'
  ok "the deck's HOME (to:home) closes it ($(Cdp-Eval 'Shell.log.slice(-1)[0]'))" (Wait-Until "Shell.cur === 'home' && Shell.log.slice(-1)[0] === 'home:nav:nav#73'" 4)
  $null = Cdp-Eval 'Shell.echo.length = 0; 1'
  Door 'rig'; $null = Wait-Until "Shell.cur === 'rig'" 3
  $null = Cdp-Eval 'Shell.echo.length = 0; 1'
  Push 'nav' '{"to":"home","seq":74,"driving":false}'
  ok "the deck's HOME also closes a page opened by a door here ($(Cdp-Eval 'Shell.log.slice(-1)[0]'))" (Wait-Until "Shell.cur === 'home' && Shell.log.slice(-1)[0] === 'home:nav:nav#74'" 4)

  # a stale close: a frame that is not the page up now (a page that has gone, anything else) is not believed
  Door 'rig'; $null = Wait-Until "Shell.cur === 'rig' && document.querySelector('#page iframe').contentDocument.readyState === 'complete'" 15
  $null = Cdp-Eval '(() => { const s = document.createElement("iframe"); s.id = "stale"; s.srcdoc = "<script>parent.postMessage({ irdash: \"sessions-close\" }, \"*\"); parent.postMessage({ paddock: \"esc\", token: \"h-old\" }, \"*\");<\/script>"; document.body.appendChild(s); return 1; })()'
  Start-Sleep -Milliseconds 700
  ok "a stale sessions-close and an Esc with an old token are ignored: RIG stays ($(Cdp-Eval 'Shell.log.slice(-2).join(" | ")'))" ((Cdp-Eval "Shell.cur === 'rig' && Shell.log.slice(-2).join('|') === 'ignored sessions-close (not the page up now)|ignored esc (not the page up now)'") -eq $true)
  $null = Cdp-Eval 'document.getElementById("stale").remove(); 1'
  $null = Cdp-Eval '(() => { const d = document.querySelector("#page iframe").contentDocument; d.dispatchEvent(new d.defaultView.KeyboardEvent("keydown", { key: "Escape", bubbles: true })); return 1; })()'
  ok "the page up now closing itself is believed ($(Cdp-Eval 'Shell.log.slice(-1)[0]'))" (Wait-Until "Shell.cur === 'home' && /^home:press:(perf-close|sessions-close|esc-frame)$/.test(Shell.log.slice(-1)[0])" 3)

  # Esc inside REVIEW with a session open: Sessions uses it (back to the list); only the next Esc goes HOME
  Door 'review'; $null = Wait-Until "Shell.cur === 'review' && document.querySelector('#page iframe').contentDocument.readyState === 'complete' && !!document.querySelector('#page iframe').contentDocument.__paddockEsc" 15
  $null = Cdp-Eval '(() => { const w = document.querySelector("#page iframe").contentWindow; w.location.hash = "a=" + encodeURIComponent("test.ibt"); return 1; })()'
  $opened = Wait-Until '(() => { const d = document.querySelector("#page iframe").contentDocument; return !!d.getElementById("wbHost"); })()' 8
  ok 'a session opened inside REVIEW' $opened
  $null = Cdp-Eval '(() => { const f = document.querySelector("#page iframe"); f.focus(); f.contentWindow.focus(); f.contentDocument.body.focus(); return 1; })()'
  Key
  Start-Sleep -Milliseconds 600
  ok "Esc with the session open goes back inside REVIEW, not HOME ($(Cdp-Eval 'Shell.cur + " / " + Shell.log.slice(-1)[0]'))" ((Cdp-Eval "Shell.cur === 'review' && document.querySelector('#page iframe').contentWindow.location.hash === ''") -eq $true)
  $null = Cdp-Eval '(() => { const w = document.querySelector("#page iframe").contentWindow; const h = w.document.getElementById("wbHost"); if (h) h.remove(); w.focus(); return 1; })()'
  Key
  ok "the next Esc goes HOME ($(Cdp-Eval 'Shell.log.slice(-1)[0]'))" (Wait-Until "Shell.cur === 'home'" 3)
  $null = Cdp-Eval '(() => { Shell.go("races", { from: "press" }); Shell.go("review", { from: "press" }); Shell.go("rig", { from: "press" }); return 1; })()'
  ok 'three doors pressed in a row: only the last is mounted, one page' (Wait-Until "Shell.cur === 'rig' && $one && !document.querySelector('#page .rc')" 5)
  Door 'home'
  ok "no page error so far ($(Cdp-Eval '__errs.join(" | ")'))" ((Cdp-Eval '__errs.length') -eq 0)

  # ------------------------------------------------------------------ 2. the banner
  Section '2. the banner: offline, kids, tow, a key message, the page''s own line'
  ok 'nothing to say: no banner' ((Cdp-Eval 'document.getElementById("banner").hidden') -eq $true)
  $null = Get-J "http://localhost:$CTL/__fault?mode=down"
  ok "irdash down: the banner says ""$OFFLINE""" (Wait-Until "!data.online && !document.getElementById('banner').hidden && document.getElementById('banner').textContent === '$OFFLINE'" 8) (Cdp-Eval 'document.getElementById("banner").textContent')
  Cdp-Shot (Join-Path $shots 'shell-offline.png')
  $errs0 = [int](Cdp-Eval '__errs.length')
  Door 'races'; $a = Wait-Until "Shell.cur === 'races' && $one" 4
  Door 'review'; $b = Wait-Until "Shell.cur === 'review' && $one" 4
  Door 'home'; $c = Wait-Until "Shell.cur === 'home' && $one" 4
  ok 'offline the doors still switch' ($a -and $b -and $c)
  ok "offline: no page error ($(Cdp-Eval "__errs.slice($errs0).join(' | ')"))" ([int](Cdp-Eval '__errs.length') -eq $errs0)
  ok 'offline the banner stays' ((Cdp-Eval "document.getElementById('banner').textContent === '$OFFLINE'") -eq $true)
  $null = Get-J "http://localhost:$CTL/__fault?mode=ok"
  $t0 = Get-Date
  $back = Wait-Until 'data.online && document.getElementById("banner").hidden' 6
  ok "back online: the banner clears within 5 s ($([math]::Round(((Get-Date) - $t0).TotalSeconds, 1)) s)" ($back -and ((Get-Date) - $t0).TotalSeconds -le 5.5)
  $kind = 'document.getElementById("banner").dataset.kind'
  Push 'kids' '{"on":true,"text":"KIDS MODE  -  keyboard and deck locked  -  to unlock press KIDS, then HOME"}'
  ok 'kids mode: the banner says so' (Wait-Until "$kind === 'kids' && /KIDS MODE/.test(document.getElementById('banner').textContent)" 3)
  Cdp-Shot (Join-Path $shots 'shell-kids.png')
  Push 'tow' '{"on":true}'
  Start-Sleep -Milliseconds 400
  ok 'tow wait while kids mode is on: kids keeps the banner' ((Cdp-Eval $kind) -eq 'kids')
  Push 'kids' '{"on":false,"text":""}'
  ok 'kids off: the tow wait shows' (Wait-Until "$kind === 'tow' && document.getElementById('banner').textContent === 'Reset car · waiting for the car to stop'" 3)
  Cdp-Shot (Join-Path $shots 'shell-tow.png')
  $at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  Push 'keymsg' ('{"seq":901,"key":"fuel","text":"Fuel to finish: 12.4 litres","kind":"ok","at":' + $at + '}')
  Start-Sleep -Milliseconds 400
  ok 'a key message during the tow wait: the tow wait keeps the banner' ((Cdp-Eval $kind) -eq 'tow')
  Push 'tow' '{"on":false}'
  ok 'tow over: the key message shows (it is still under 4 s old)' (Wait-Until "$kind === 'key' && document.getElementById('banner').textContent === 'Fuel to finish: 12.4 litres'" 3)
  Cdp-Shot (Join-Path $shots 'shell-keymsg.png')
  ok 'the key message goes after 4 s' (Wait-Until 'document.getElementById("banner").hidden' 5)
  $at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 6000
  Push 'keymsg' ('{"seq":902,"key":"fuel","text":"An old message","kind":"ok","at":' + $at + '}')
  Start-Sleep -Milliseconds 500
  ok 'a key message older than 4 s never shows' ((Cdp-Eval 'document.getElementById("banner").hidden') -eq $true)
  # the page's own line: RACES when its list will not load while irdash answers
  $null = Get-J "http://localhost:$CTL/__fault?mode=500&route=/api/library"
  Door 'races'
  ok 'RACES whose list fails: its own line in the banner (ctx.banner)' (Wait-Until "$kind === 'page' && /not answering/.test(document.getElementById('banner').textContent)" 5)
  Push 'kids' '{"on":true,"text":"KIDS MODE  -  keyboard and deck locked  -  to unlock press KIDS, then HOME"}'
  ok 'kids mode over the page''s line' (Wait-Until "$kind === 'kids'" 3)
  $null = Get-J "http://localhost:$CTL/__fault?mode=down"
  ok 'offline over kids mode' (Wait-Until "$kind === 'offline'" 8)
  $null = Get-J "http://localhost:$CTL/__fault?mode=ok"
  $null = Wait-Until 'data.online' 8
  Push 'kids' '{"on":false,"text":""}'
  ok 'back: the page''s line again' (Wait-Until "$kind === 'page'" 5)
  $null = Get-J "http://localhost:$CTL/__fault?mode=ok&route=/api/library"
  Door 'home'
  ok 'the page went: its line went with it' (Wait-Until 'document.getElementById("banner").hidden' 3)

  # ------------------------------------------------------------------ 3. driving
  Section '3. driving: the race screen, the page unmounted, back to HOME 5 s after'
  Door 'races'; $null = Wait-Until "Shell.cur === 'races'" 3
  $withRaces = [int](Cdp-Eval $listeners)
  ok "RACES subscribes ($withRaces listeners, $base on HOME)" ($withRaces -gt $base)
  $frame = 'window.__fv = { SessionFlags: 0x4, IsReplayPlaying: 0, IsOnTrack: 1, SessionNum: 0 }; clearInterval(window.__fr); window.__fr = setInterval(() => data.emit("frame", Object.assign({}, window.__fv)), 66); 1'
  $null = Cdp-Eval $frame
  Start-Sleep -Milliseconds 600
  ok 'fresh frames but not driving: the page stays' ((Cdp-Eval "!ShellRace.on && Shell.cur === 'races'") -eq $true)
  Push 'rig' '{"driving":true,"sessionOn":true,"simRunning":true,"online":true}'
  $t0 = Get-Date
  $on = Wait-Until "ShellRace.on && !document.getElementById('raceHost').hidden && document.getElementById('page').children.length === 0 && Shell.cur === ''" 4
  ok "driving + a fresh frame: the race screen shows, the page is unmounted ($([math]::Round(((Get-Date) - $t0).TotalMilliseconds)) ms)" $on
  ok "no listener left from RACES ($(Cdp-Eval $listeners), $base on HOME)" ([int](Cdp-Eval $listeners) -eq $base)
  ok "the stream asks for the race set ($(Cdp-Eval 'data.set'))" ((Cdp-Eval 'data.set') -eq 'race')
  ok "the flag glow shows the flag (green) and the race page reads it ($(Cdp-Eval 'document.getElementById("flagGlow").className'))" ((Cdp-Eval 'document.getElementById("flagGlow").className === "on green" && document.getElementById("raceFrame").contentWindow.RacePage.flag() === "green"') -eq $true)
  Start-Sleep -Milliseconds 500
  Cdp-Shot (Join-Path $shots 'shell-driving.png')
  Door 'races'
  Push 'nav' '{"to":"races","seq":60,"driving":true}'
  Start-Sleep -Milliseconds 500
  ok "while driving a door or a deck request opens nothing (the request is kept: $(Cdp-Eval 'Shell.log.slice(-1)[0]'))" ((Cdp-Eval "ShellRace.on && Shell.cur === '' && document.getElementById('page').children.length === 0 && Shell.pending === 'races'") -eq $true)
  $null = Cdp-Eval 'window.__fv.IsReplayPlaying = 1; 1'
  $t0 = Get-Date
  $atHome = Wait-Until "!ShellRace.on && Shell.cur === 'races'" 9
  $took = ((Get-Date) - $t0).TotalSeconds
  ok "a replay in the sim: after the 5 s wait the page the deck asked for while driving opens ($([math]::Round($took, 1)) s; $(Cdp-Eval 'Shell.log.slice(-1)[0]'))" ($atHome -and $took -ge 4.3 -and (Cdp-Eval 'Shell.log.slice(-1)[0]') -eq 'races:drive:pending')
  $null = Cdp-Eval 'window.__fv.IsReplayPlaying = 0; 1'
  ok 'out of the replay: the race screen again' (Wait-Until 'ShellRace.on' 3)
  $null = Cdp-Eval 'clearInterval(window.__fr); 1'
  $t0 = Get-Date
  $atHome = Wait-Until "!ShellRace.on && Shell.cur === 'home'" 12
  $took = ((Get-Date) - $t0).TotalSeconds
  ok "frames stop (a hung sim): HOME after 3 s stale + 5 s ($([math]::Round($took, 1)) s)" ($atHome -and $took -ge 7)
  ok 'no frames at all with rig.driving: no race screen' ((Cdp-Eval '!ShellRace.on') -eq $true)
  $null = Cdp-Eval $frame
  ok 'frames again: the race screen' (Wait-Until 'ShellRace.on' 3)
  Push 'rig' '{"driving":false,"sessionOn":true,"simRunning":true,"online":true}'
  Start-Sleep -Seconds 3
  ok '3 s after driving ends: still the race screen (a tow or a reset does not flick it)' ((Cdp-Eval 'ShellRace.on') -eq $true)
  Push 'nav' '{"to":"review","seq":61,"driving":false}'      # the deck's REVIEW during the 5 s wait (irdash already says not driving)
  ok "5 s after it ends the deck's REVIEW from the wait opens ($(Cdp-Eval 'Shell.log.slice(-1)[0]'))" (Wait-Until "!ShellRace.on && Shell.cur === 'review' && document.getElementById('raceHost').hidden && Shell.log.slice(-1)[0] === 'review:drive:pending'" 4)
  Door 'home'
  ok "out of the car the stream asks only the shell's four channels again ($(Cdp-Eval '(data.vars || []).join()'))" ((Cdp-Eval 'data.set === "" && (data.vars || []).join() === "SessionFlags,IsReplayPlaying,IsOnTrack,SessionNum"') -eq $true)
  $null = Cdp-Eval 'clearInterval(window.__fr); 1'
  ok "no page error ($(Cdp-Eval '__errs.join(" | ")'))" ((Cdp-Eval '__errs.length') -eq 0)
  ok "no exception seen by Chrome ($($script:cdp.errors -join ' | '))" ($script:cdp.errors.Count -eq 0)

  # ------------------------------------------------------------------ 4. request rate
  Section '4. request rate (20 s each)'
  Start-Sleep -Seconds 4
  $m = Rate
  "  info HOME idle: $($m.n) requests in 20 s = $($m.rate) / s ($($m.routes)); $($m.streams) stream open, $($m.opens) reconnects"
  ok "HOME idle: $($m.rate) requests / s (ceiling 2), one stream" ($m.rate -le 2 -and $m.streams -eq 1)
  $null = Cdp-Eval $frame
  Push 'rig' '{"driving":true,"sessionOn":true,"simRunning":true,"online":true}'
  $null = Wait-Until 'ShellRace.on' 4
  Start-Sleep -Seconds 2
  $m = Rate
  "  info driving: $($m.n) requests in 20 s = $($m.rate) / s besides the stream ($($m.routes))"
  ok "driving: $($m.rate) requests / s besides the stream (ceiling 1)" ($m.rate -le 1)
  $null = Cdp-Eval 'clearInterval(window.__fr); 1'
  Push 'rig' '{"driving":false,"sessionOn":false,"simRunning":false,"online":true}'
  Cdp-Close

  # ------------------------------------------------------------------ 5. a few more (fresh page)
  Section '5. ?page=, ?race=1, driving at load'
  Cdp-Open "http://localhost:$PORT/app/index.html?intro=0&page=races" -Port ($CDP + 1)
  ok '?page=races opens RACES first' (Wait-Until "window.Shell && Shell.cur === 'races' && document.querySelectorAll('#page .rc .card').length === 3" 10)
  Cdp-Close
  Cdp-Open "http://localhost:$PORT/app/index.html?intro=0&race=1" -Port ($CDP + 2)
  ok '?race=1 shows the race screen whatever the rig says, no page mounted' (Wait-Until "window.Shell && ShellRace.on && !document.getElementById('raceHost').hidden && Shell.cur === '' && data.set === 'race'" 10)
  Cdp-Shot (Join-Path $shots 'shell-race-forced.png')
  Cdp-Close

  # ------------------------------------------------------------------ 6. Friends mode
  Section '6. Friends mode: its layer, pages closed while a guest drives, the clean-lap call'
  Push 'rig' '{"driving":false,"sessionOn":false,"simRunning":false,"online":true}'
  Push 'guest' '{"active":false}'
  Cdp-Open "http://localhost:$PORT/app/index.html?intro=0&page=races" -Port ($CDP + 3)
  $null = Wait-Until "window.Shell && Shell.cur === 'races'" 10
  $g = '{"active":true,"driver":"Sam","driverId":"sam","voiceDriver":true,"car":{"name":"GR86","full":"Toyota GR86","aids":""},"track":{"name":"Road Atlanta","full":"Road Atlanta Full Course"},"wheel":"light","line":true,"lineKey":true,"coach":true,"board":true,"times":[{"name":"Alex","time":93.2},{"name":"Sam","time":94.1}]}'
  [IO.File]::WriteAllText((Join-Path $fx 'guest.json'), $g, (New-Object Text.UTF8Encoding($false)))   # what /guest answers after a lap (guest.js asks once more)
  Push 'guest' $g
  $gq = '(() => { const f = document.getElementById("guestFrame"); const d = f && f.contentDocument; const g = d && d.getElementById("guest"); return g ? g.className : ""; })()'
  ok 'a guest is on: the Friends mode layer shows its setup card' (Wait-Until "!document.getElementById('guestHost').hidden && $gq === 'setup'" 10) (Cdp-Eval $gq)
  ok 'with the guest only choosing, the page stays (under the layer)' ((Cdp-Eval "Shell.cur === 'races' && !Shell.block") -eq $true)
  Start-Sleep -Milliseconds 500
  Cdp-Shot (Join-Path $shots 'shell-guest.png')
  $null = Cdp-Eval $frame
  Push 'rig' '{"driving":true,"sessionOn":true,"simRunning":true,"online":true}'
  Push 'guest' $g.Replace('"coach":true', '"coach":false')       # irdash pushes the guest part again: the view redraws as the drive view
  ok 'a guest drives: the page is closed, no race screen, the drive view shows' (Wait-Until "Shell.block && Shell.cur === '' && document.getElementById('page').children.length === 0 && document.getElementById('raceHost').hidden && !ShellRace.on && $gq === 'drive'" 8) "($(Cdp-Eval $gq) / $(Cdp-Eval 'Shell.log.slice(-2).join(" | ")'))"
  Door 'review'
  ok "a door during the guest drive is refused ($(Cdp-Eval 'Shell.log.slice(-1)[0]'))" ((Cdp-Eval "Shell.cur === '' && Shell.log.slice(-1)[0] === 'refused review:press:door'") -eq $true)
  ok "the stream asks for Friends mode's channels ($(Cdp-Eval 'data.set + "|" + (data.vars || []).length'))" ((Cdp-Eval 'data.set === "" && (data.vars || []).length > 20 && (data.vars || []).includes("LapCurrentLapTime")') -eq $true)
  $null = Get-J "http://localhost:$CTL/__reset"
  $null = Cdp-Eval '(() => { const w = document.getElementById("guestFrame").contentWindow; w.eval("L.laps.push({ n: 99, time: 93.512, clean: true })"); return 1; })()'
  $lap = $false; for ($i = 0; $i -lt 12 -and -not $lap; $i++) { Start-Sleep -Milliseconds 250; $s = Get-J "http://localhost:$CTL/__stats"; $lap = [bool]($s.routes.PSObject.Properties | Where-Object { $_.Name -eq '/api/guest/lap' }) }
  ok 'a clean guest lap is sent to irdash (/api/guest/lap: the friends leaderboard)' $lap
  $null = Cdp-Eval 'window.__fv = Object.assign(window.__fv, { LapCurrentLapTime: 42.3, SessionTime: 500, Lap: 3, LapDistPct: 0.4, Throttle: 0.8, Brake: 0, LapLastLapTime: 94.1, LapBestLapTime: 93.9 }); 1'
  Start-Sleep -Milliseconds 800
  Cdp-Shot (Join-Path $shots 'shell-guest-drive.png')
  Push 'nav' '{"to":"rig","seq":90,"driving":false}'
  ok "a deck request during the guest drive is kept ($(Cdp-Eval 'Shell.log.slice(-1)[0]'))" ((Cdp-Eval "Shell.pending === 'rig'") -eq $true)
  $null = Cdp-Eval 'clearInterval(window.__fr); 1'
  Push 'rig' '{"driving":false,"sessionOn":false,"simRunning":false,"online":true}'
  Push 'guest' '{"active":false}'
  ok "the guest is gone: the layer goes and the kept request opens ($(Cdp-Eval 'Shell.log.slice(-1)[0]'))" (Wait-Until "document.getElementById('guestHost').hidden && !document.getElementById('guestFrame') && Shell.cur === 'rig'" 6)
  Cdp-Close

  # ------------------------------------------------------------------ 7. the start-up (W3-2's Startup.init)
  Section '7. the start-up: never on a window opened while he drives; stopped when he gets in'
  [IO.File]::WriteAllText((Join-Path $fx 'showcase~who=page.json'), '{"play":true,"seq":1,"driving":false}', (New-Object Text.UTF8Encoding($false)))
  Push 'rig' '{"driving":true,"sessionOn":true,"simRunning":true,"online":true}'
  Cdp-Open "http://localhost:$PORT/app/index.html" -Port ($CDP + 4)
  $null = Wait-Until 'window.Shell && data.seq >= 0' 10
  Start-Sleep -Seconds 3
  ok "a window opened while he drives: no start-up ($(Cdp-Eval 'Shell.log.join(" | ")'))" ((Cdp-Eval "!ShellStartup.running && document.getElementById('startup').hidden && !Shell.log.includes('startup')") -eq $true)
  Cdp-Close
  Push 'rig' '{"driving":false,"sessionOn":false,"simRunning":false,"online":true}'
  Cdp-Open "http://localhost:$PORT/app/index.html" -Port ($CDP + 5)
  ok 'not driving: irdash says play, the start-up plays' (Wait-Until "window.ShellStartup && ShellStartup.running && !document.getElementById('startup').hidden" 8)
  $null = Cdp-Eval '(() => { const A = window.AudioContext; window.__acs = []; window.AudioContext = function () { const c = new A(); window.__acs.push(c); return c; }; return 1; })()'   # before the first light's tone (1 s)
  Start-Sleep -Milliseconds 2600
  Cdp-Shot (Join-Path $shots 'shell-startup.png')
  $null = Cdp-Eval $frame
  Push 'rig' '{"driving":true,"sessionOn":true,"simRunning":true,"online":true}'
  ok "he gets in the car: the start-up stops at once, lights, dial and tones ($(Cdp-Eval 'Shell.log.slice(-3).join(" | ")'))" (Wait-Until "ShellRace.on && !ShellStartup.running && document.getElementById('startup').hidden && document.getElementById('startup').children.length === 0 && Shell.log.includes('startup stopped')" 4)
  Start-Sleep -Milliseconds 300
  ok "its tones are stopped too ($(Cdp-Eval 'window.__acs.map(c => c.state).join()') AudioContext)" ((Cdp-Eval 'window.__acs.length >= 1 && window.__acs.every(c => c.state === "closed")') -eq $true)
  $null = Cdp-Eval 'clearInterval(window.__fr); 1'
  Push 'rig' '{"driving":false,"sessionOn":false,"simRunning":false,"online":true}'
  Cdp-Close
} catch {
  $script:fail++; "  FAIL  the test stopped: $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage))"
} finally {
  Cdp-Close
  if ($pret) { Stop-Process -Id $pret.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
foreach ($s in 'home', 'races', 'review', 'rig', 'offline', 'kids', 'tow', 'keymsg', 'driving', 'race-forced', 'guest', 'guest-drive', 'startup') { ok "picture tests\shots\rework\shell-$s.png" (Test-Path (Join-Path $shots "shell-$s.png")) }
"shell-test: $($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0 -or $script:pass -eq 0) { exit 1 }
