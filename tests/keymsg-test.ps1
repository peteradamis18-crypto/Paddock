# keymsg-test.ps1 - the one-line "what that deck key just did" message on the top screen (dash\src\keymsg.cs, the /api/keymsg and
# /keymsg routes in irdash.cs, dash\www\v2\keymsg.js + keymsg.css).
#   1. offline, compiled copy of keymsg.cs: sanitising, 80 characters, kind, seq, valid JSON
#   2. offline, static: the route is wired, keymsg.cs is in the build, index.html has the element, the css and the script
#   3. offline, headless Chrome with irdash mocked (no network): in three layouts (HOME, Drive v1, old grid) the message appears with its
#      words, is >= 36 px, stays inside 1920 x 1080, covers none of the in-car blocks, fades away after ~4 s; a stale message never shows;
#      a hidden page stops polling; prefers-reduced-motion switches the fade off. Pictures: tests\shots\keymsg-<layout>.png
#   4. live, ONLY when the rig is free (sim not running, no START key in the last 10 min) and the running irdash already has the route
#      (answers 404 until the lead deploys): the real route. It shows a message on the top screen for 4 s, hence the guard.
#   powershell -ExecutionPolicy Bypass -File tests\keymsg-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
$root = Split-Path -Parent $PSScriptRoot
$www = Join-Path $root 'dash\www\v2'
$shots = Join-Path $PSScriptRoot 'shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$pass = 0; $fail = 0
function Section($name) { $name }
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }

# ---------------------------------------------------------------- 1. the C# state, compiled on its own
Section '1. keymsg.cs compiled on its own'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP ('keymsg-unit-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
& $csc /nologo /target:exe "/out:$tmp\unit.exe" /r:System.dll /r:System.Core.dll /r:System.Web.Extensions.dll (Join-Path $root 'dash\src\keymsg.cs') (Join-Path $PSScriptRoot 'keymsg-unit.cs') | Out-Null
if (-not (Test-Path "$tmp\unit.exe")) { Check 'keymsg.cs and tests\keymsg-unit.cs compile' $false }
else {
  $u = & "$tmp\unit.exe"
  foreach ($l in $u) { if ($l -match '^ok ') { $script:pass++; "  $l" } elseif ($l -match '^FAIL ') { $script:fail++; "  $l" } }
  Check 'unit run finished' ($u -contains 'UNIT-DONE')
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 2. wiring
Section '2. wiring'
$irdash = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
$build = [IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1'))
$idx = [IO.File]::ReadAllText((Join-Path $www 'index.html'))
$css = [IO.File]::ReadAllText((Join-Path $www 'keymsg.css'))
$js = [IO.File]::ReadAllText((Join-Path $www 'keymsg.js'))
Check 'irdash.cs has GET /keymsg and GET /api/keymsg' ($irdash -match 'path == "/keymsg"' -and $irdash -match 'path == "/api/keymsg"')
Check '/api/keymsg answers this PC only (not the phone)' ($irdash -match '(?s)path == "/api/keymsg".{0,300}!local')
Check 'dash\build.ps1 compiles keymsg.cs' ($build -match 'keymsg\.cs')
Check 'index.html: the element, the stylesheet and the script' ($idx -match 'id="keyMsg"' -and $idx -match 'href="keymsg\.css"' -and $idx -match 'src="keymsg\.js"')
Check 'the script polls /keymsg every 400 ms and stops while the page is hidden' ($js -match "fetch\('/keymsg'" -and $js -match 'POLL_MS = 400' -and $js -match 'document\.hidden' -and $js -match 'clearInterval')
Check 'the message is shown as text, never as markup' ($js -match 'textContent' -and $js -notmatch 'innerHTML')
Check 'no sound anywhere' ($js -notmatch 'Audio|beep|\.play\(' -and $css -notmatch '.(wav|mp3|ogg)')
Check 'css respects prefers-reduced-motion' ($css -match '@media \(prefers-reduced-motion: reduce\)')

# ---------------------------------------------------------------- 2b. irdeck's words: real log lines -> what the top screen says
# src\keymsg.cs turns the last line a key logged into plain words, first matching row wins. The lines below are copied from the
# Log(...) calls and from irdeck.log, so a row that grabs the wrong line (a refusal shown as success) fails here.
Section '2b. irdeck log line -> top-screen words'
$say = [IO.File]::ReadAllText((Join-Path $root 'src\keymsg.cs'))
$rows = @([regex]::Matches($say, 'new\[\] \{ @"((?:[^"]|"")*)", "(\w+)", "([^"]*)" \}') | ForEach-Object { , @($_.Groups[1].Value.Replace('""', '"'), $_.Groups[2].Value, $_.Groups[3].Value) })
function Words($line) {
  foreach ($r in $rows) { $m = [regex]::Match($line, $r[0], 'IgnoreCase'); if ($m.Success) { $t = $r[2]; for ($g = 1; $g -lt $m.Groups.Count; $g++) { $t = $t.Replace('$' + $g, $m.Groups[$g].Value.Trim()) }; return $r[1] + '|' + $t } }
  return ''
}
Check "the table was read ($($rows.Count) rows)" ($rows.Count -ge 30)
$cases = [ordered]@{
  'go: in the car (press 2)' = 'ok|In the car'
  'smart: in the car' = 'ok|In the car'
  'smart: already in the car' = 'ok|Already in the car'
  'tow: back in the car in the pits' = 'ok|Car reset to the pits'
  'mydrive: START -> in the car in 34 s' = 'ok|In the car'
  'chat say sent' = 'ok|Sent'
  'pit: fast repair on' = 'ok|Pit: fast repair on'
  'pit clear sent' = 'ok|Pit stop cleared'
  'getout: held Esc' = 'ok|Out of the car'
  'getout: you are not in the car' = 'ok|Already out of the car'
  'skip refused: the car is still moving - slow down and press again' = 'no|The car did not stop'
  'getout refused: the car is still moving (6.1 m/s) after 15 s - slow down and press again' = 'no|The car did not stop'
  'tow refused: the car is moving (4.2 m/s)' = 'no|Stop the car first'
  'quitmain refused: the car is still moving - slow down and press again' = 'no|The car did not stop'
  'skip: now in session 2 (Race) - the first Next did it' = 'ok|Next session: Race'
  'restart: back in the car' = 'ok|Race restarted'
  'racenow: in the race, in the car' = 'ok|Race starting'
  'racenow: only an AI race can be fast-forwarded to its race (a Test Drive has no race, official sessions cannot be skipped)' = 'no|Only AI races can jump to the race'
  'racenow: still in Practice after 4 skips - stopped' = 'no|Could not reach the race'
  'racenow: no session is running' = 'no|No race running'
  'appvol game: 40% (3 session(s))' = 'ok|Game volume 40 %'
  'appvol mute: CrewChiefV4 muted (1 session(s))' = 'ok|Spotter muted'
  'appvol mute: CrewChiefV4 sound back on (1 session(s))' = 'ok|Spotter on'
  'appvol mute: CrewChiefV4 is not making sound right now' = 'no|No game sound right now'
  'kids: press HOME within 4 seconds to unlock' = 'wait|Press HOME within 4 seconds to unlock'
  'power off' = 'ok|PC turning off in 5 seconds'
  'power sleep' = 'ok|PC going to sleep'
  'power off: cancelled because iRacing did not quit' = 'no|Stopped: iRacing did not quit'
}
foreach ($k in $cases.Keys) { $w = Words $k; Check "'$k' -> '$($cases[$k])'" ($w -eq $cases[$k]) }
Check 'a line nobody planned for falls through to the result code (no row matches it)' ((Words 'zz unrelated text 123') -eq '')

# ---------------------------------------------------------------- 3. the page, in headless Chrome
Section '3. the page in headless Chrome (irdash mocked)'
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { Check 'Chrome found' $false }
else {
  $links = ([regex]::Matches($idx, '<link rel="stylesheet" href="([^"]+)">') | ForEach-Object { '<link rel="stylesheet" href="../dash/www/v2/' + $_.Groups[1].Value + '">' }) -join "`n"
  $markup = [regex]::Match($idx, '(?s)<body>(.*?)<script src="core\.js">').Groups[1].Value
  $harness = @'
(function(){
  var MODE = '__MODE__', SHOT = __SHOT__, NOANIM = __NOANIM__, el = document.getElementById('keyMsg'), out = [];
  function $(i){ return document.getElementById(i); }
  function ck(name, ok, info){ out.push((ok ? 'ok ' : 'FAIL ') + name + (ok ? '' : '  [' + info + ']')); }
  // ---- the layout under test, filled with typical words so the blocks have their real size
  document.getElementById('overlay').classList.remove('show');
  if (MODE === 'home') document.getElementById('overlay').classList.add('show');
  if (MODE === 'drive') {
    $('drive').hidden = false;
    $('dSess').textContent = 'Race'; $('dTrack').textContent = 'Road America - Full Course'; $('dClock').textContent = '12:34';
    var cells = { cPos: ['Position', 'P4', 'of 20'], cGap: ['Gap ahead', '+1.24', 'Smith #12'], cDelta: ['Delta', '-0.213', 'vs best'], cLeft: ['Laps left', '14', 'of 20'], cFuel: ['Fuel', '8.4 laps', 'enough'] };
    Object.keys(cells).forEach(function(k){ var c = $(k); c.querySelector('.lbl').textContent = cells[k][0]; c.querySelector('.v').textContent = cells[k][1]; c.querySelector('.s').textContent = cells[k][2]; });
    $('cDelta').querySelector('.dbar i').style.cssText = 'right:50%;width:20%;background:var(--gain)';
    $('dLaps').innerHTML = 'Last <b>1:23.456</b> ' + String.fromCharCode(183) + ' Best <b>1:22.345</b>';
    $('dRec').hidden = false; $('dRec').querySelector('span').textContent = 'REC PAUSED: DISK FULL';   // the widest pill there is
    $('dTowerT').textContent = 'Battle'; $('dTowerG').textContent = 'Gap';
    var rows = ''; for (var i = 0; i < 7; i++) rows += '<div class="trow' + (i === 3 ? ' me' : '') + '"><i class="cls"></i><span class="p">' + (i + 1) + '</span><span class="n">#' + (10 + i) + '</span><span class="nm">Driver Name ' + i + '</span><span class="g">+' + (i * 1.3).toFixed(1) + '</span></div>';
    $('dRows').innerHTML = rows;
  }
  // ---- irdash mocked: /keymsg answers whatever MSG says; every call is counted
  var MSG = { seq: 0, key: '', text: '', kind: 'ok', at: 0, ageMs: 0 }, CALLS = 0;
  window.fetch = function(u){ CALLS++; var m = JSON.parse(JSON.stringify(MSG)); return Promise.resolve({ ok: String(u).indexOf('/keymsg') === 0, json: function(){ return Promise.resolve(m); } }); };
  function push(seq, text, kind, age){ MSG = { seq: seq, key: 'get-out', text: text, kind: kind, at: 1, ageMs: age || 0 }; }
  function lum(rgb){ var m = rgb.match(/[\d.]+/g).map(Number).slice(0, 3).map(function(v){ v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }); return 0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]; }
  function snap(){
    var r = el.getBoundingClientRect(), cs = getComputedStyle(el);
    return { on: el.classList.contains('on'), text: el.textContent, fs: parseFloat(cs.fontSize), l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height, color: cs.color, border: cs.borderTopColor,
      bg: cs.backgroundColor, op: parseFloat(cs.opacity), vis: cs.visibility, ws: cs.whiteSpace, tr: cs.transitionDuration, z: parseInt(cs.zIndex, 10), pe: cs.pointerEvents };
  }
  function box(s){ return Math.round(s.l) + ',' + Math.round(s.t) + '-' + Math.round(s.r) + ',' + Math.round(s.b); }
  // blocks that must stay uncovered, per layout (selectors; zero-size or hidden ones are skipped)
  var BLOCKS = {
    drive: ['#dTop', '#dMap', '#dTower', '#dBand .dcell', '#dBand .dbar', '#dLaps', '#dRec:not([hidden])'],
    grid: ['#strip', '#pStand', '#pRel', '#pMap', '#pCar', '.lapnow', '.deltabar', '.laprefs', '.sectors:not(:empty)', '.fuel'],
    home: ['.idle-top', '.home-hr', '#homeNext:not([hidden])', '#idleRig', '#homeRace', '#homeLast']
  };
  function overlaps(s){
    var hit = [];
    (BLOCKS[MODE] || []).forEach(function(sel){ [].forEach.call(document.querySelectorAll(sel), function(n){
      var q = n.getBoundingClientRect(); if (q.width < 0.5 || q.height < 0.5) return;
      if (s.l < q.right - 0.5 && q.left < s.r - 0.5 && s.t < q.bottom - 0.5 && q.top < s.b - 0.5) hit.push(sel + ' ' + Math.round(q.left) + ',' + Math.round(q.top) + '-' + Math.round(q.right) + ',' + Math.round(q.bottom));
    }); });
    return hit;
  }
  function shows(tag, s, text, kind){
    ck(tag + ': shown with its words', s.on && s.text === text && s.op > 0.95 && s.vis === 'visible', JSON.stringify(s));
    ck(tag + ': at least 36 px (' + s.fs + ')', s.fs >= 36, s.fs);
    ck(tag + ': one line', s.ws === 'nowrap' && s.h <= 62, s.ws + ' h=' + s.h);
    ck(tag + ': inside 1920 x 1080 (' + box(s) + ')', s.l >= 0 && s.t >= 0 && s.r <= 1920 && s.b <= 1080, box(s));
    ck(tag + ': in the bottom edge, centred', s.t >= 984 && Math.abs((s.l + s.r) / 2 - 960) <= 1, box(s));
    ck(tag + ': high contrast (' + (((lum(s.color) + 0.05) / (lum(s.bg) + 0.05))).toFixed(1) + ':1)', (lum(s.color) + 0.05) / (lum(s.bg) + 0.05) >= 7, s.color + ' on ' + s.bg);
    ck(tag + ': ' + kind + ' colours', kind === 'ok' ? /242, 194, 48/.test(s.border) : kind === 'wait' ? /255, 178, 30/.test(s.border) && /255, 178, 30/.test(s.color) : /255, 102, 89/.test(s.color), s.border + ' / ' + s.color);
    ck(tag + ': above every layer, never takes a click', s.z >= 960 && s.pe === 'none', s.z + ' ' + s.pe);
    var h = overlaps(s); ck(tag + ': covers none of the blocks (' + MODE + ')', h.length === 0, h.join(' ; '));
  }
  var A = 'Waiting for the car to stop', C = 'No race running', D = 'x'.repeat(0) + 'In the car, but this is a very long line of plain words that goes on and on until the very last allowed character';
  D = D.slice(0, 80);
  var E = 'Game volume 60 %';
  var tr0 = getComputedStyle(el).transitionDuration; out.push('INFO transition ' + tr0);
  if (NOANIM) { ck('the fade is declared (' + tr0 + ')', /0\.25s/.test(tr0), tr0); var st = document.createElement('style'); st.textContent = '#keyMsg,#keyMsg.on{transition:none!important}'; document.head.appendChild(st); }   // headless virtual time does not run CSS transitions: judge the end states
  ck('the screen is 1920 x 1080', innerWidth === 1920 && innerHeight === 1080, innerWidth + ' x ' + innerHeight);
  if (SHOT) {
    window.KeyMsg.show({ key: 'get-out', text: A, kind: 'wait' }, -100000);   // held on screen for the picture
    setTimeout(function(){ var s = snap(); ck('the picture shows the message', s.on && s.op === 1 && s.vis === 'visible' && s.text === A, JSON.stringify(s)); var p = document.createElement('pre'); p.id = 'out'; p.style.display = 'none'; p.textContent = out.join('\n') + '\nDONE'; document.body.appendChild(p); }, 1500);
    return;
  }
  var t = {};
  setTimeout(function(){ var s = snap(); ck('nothing shown before the first message', !s.on && s.vis === 'hidden' && s.op === 0, JSON.stringify(s)); push(1, A, 'wait'); }, 1000);
  setTimeout(function(){ shows('wait', snap(), A, 'wait'); }, 1900);
  setTimeout(function(){ ck('still there after about 3 s', snap().on, JSON.stringify(snap())); }, 4300);
  setTimeout(function(){ var s = snap(); ck('gone after about 4 s (faded out, not just transparent)', !s.on && s.op === 0 && s.vis === 'hidden', JSON.stringify(s)); }, 6300);
  setTimeout(function(){ push(2, 'Old news', 'ok', 5000); }, 6400);
  setTimeout(function(){ ck('a message already older than 4 s is never shown', !snap().on, JSON.stringify(snap())); push(3, C, 'no'); }, 7200);
  setTimeout(function(){ shows('no', snap(), C, 'no'); push(4, D, 'ok'); }, 8100);
  setTimeout(function(){
    var s = snap(); ck('80 characters: shown, one line, inside the screen', s.on && s.text.length === 80 && s.h <= 62 && s.l >= 0 && s.r <= 1920 && s.w <= 840.5, JSON.stringify(s));
    push(5, 'In the car', 'ok');
  }, 9000);
  setTimeout(function(){ shows('ok', snap(), 'In the car', 'ok'); }, 9900);
  // a hidden page: polling stops; shown again: polling and messages carry on
  setTimeout(function(){ Object.defineProperty(document, 'hidden', { configurable: true, get: function(){ return true; } }); document.dispatchEvent(new Event('visibilitychange')); t.c0 = CALLS; }, 14000);
  setTimeout(function(){ ck('a hidden page makes no requests', CALLS === t.c0, (CALLS - t.c0) + ' calls'); delete document.hidden; document.dispatchEvent(new Event('visibilitychange')); push(6, E, 'ok'); }, 15500);
  setTimeout(function(){ shows('after hidden', snap(), E, 'ok'); ck('polling is back after the page shows again', CALLS > t.c0, CALLS + ' vs ' + t.c0); }, 16500);
  setTimeout(function(){ var p = document.createElement('pre'); p.id = 'out'; p.style.display = 'none'; p.textContent = out.join('\n') + '\nDONE'; document.body.appendChild(p); }, 17000);
})();
'@
  $modes = @('home', 'drive', 'grid')
  function Run-Chrome($mode, $shot, $extra) {
    $js = $harness.Replace('__MODE__', $mode).Replace('__SHOT__', $(if ($shot) { 'true' } else { 'false' })).Replace('__NOANIM__', $(if ($extra) { 'false' } else { 'true' }))
    $html = "<!doctype html><html><head><meta charset=`"utf-8`">`n$links`n<style>html,body{margin:0;overflow:hidden}</style></head><body>`n$markup`n<script src=`"../dash/www/v2/keymsg.js`"></script>`n<script>$js</script>`n</body></html>"
    $file = Join-Path $PSScriptRoot "keymsg-$mode$(if ($shot) { '-shot' } elseif ($extra) { '-rm' }).harness.html"
    [IO.File]::WriteAllText($file, $html, (New-Object Text.UTF8Encoding($false)))
    $url = 'file:///' + ($file -replace '\\', '/')
    $prof = Join-Path $env:TEMP ('keymsg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $a = @('--headless=new', '--disable-gpu', '--no-first-run', '--hide-scrollbars', "--user-data-dir=$prof", '--allow-file-access-from-files', '--window-size=1936,1175')   # headless Chrome's page is 16 px narrower and 95 px shorter than the window: this gives a 1920 x 1080 page
    if ($extra) { $a += $extra }
    $res = @{ lines = @(); png = $null }
    if ($shot) {
      $png = Join-Path $env:TEMP "keymsg-$mode-raw.png"
      $null = Start-Process -FilePath $chrome -ArgumentList (($a | ForEach-Object { $_ -replace 'window-size=1936,1175', 'window-size=1920,1080' }) + @('--virtual-time-budget=2500', "--screenshot=$png", $url)) -NoNewWindow -Wait -RedirectStandardOutput "$prof.o1" -RedirectStandardError "$prof.e1"
      $res.png = $png
    }
    $null = Start-Process -FilePath $chrome -ArgumentList ($a + @($(if ($shot) { '--virtual-time-budget=2500' } else { '--virtual-time-budget=19000' }), '--dump-dom', $url)) -NoNewWindow -Wait -RedirectStandardOutput "$prof.dom" -RedirectStandardError "$prof.err"
    $dom = Get-Content "$prof.dom" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    Remove-Item "$prof.*" -ErrorAction SilentlyContinue; Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item $file -ErrorAction SilentlyContinue
    $m = [regex]::Match([string]$dom, '(?s)<pre id="out"[^>]*>(.*?)</pre>')
    $res.text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
    return $res
  }
  foreach ($mode in $modes) {
    "  -- layout: $mode"
    $r = Run-Chrome $mode $false $null
    $lines = @($r.text -split "`n" | Where-Object { $_ -match '^(ok|FAIL) ' })
    if ($r.text -notmatch 'DONE') { Check "$mode : the harness finished" $false }
    foreach ($l in $lines) { if ($l -match '^ok ') { $pass++; "  ok    $mode : " + $l.Substring(3) } else { $fail++; "  FAIL  $mode : " + $l.Substring(5) } }
  }
  # reduced motion: Chrome's own switch for the OS setting
  "  -- prefers-reduced-motion"
  $r = Run-Chrome 'drive' $false @('--force-prefers-reduced-motion')
  $tr = [regex]::Match($r.text, 'INFO transition (\S+)').Groups[1].Value
  Check "reduced motion: no fade (transition-duration '$tr')" ($r.text -match 'DONE' -and $tr -match '^0s(, 0s)*$')
  # pictures (a message on screen), 1920 x 1080
  Add-Type -AssemblyName System.Drawing
  foreach ($mode in $modes) {
    $r = Run-Chrome $mode $true $null
    $dest = Join-Path $shots "keymsg-$mode.png"
    if ($r.png -and (Test-Path $r.png)) { $img = [Drawing.Image]::FromFile($r.png); $bmp = New-Object Drawing.Bitmap 1920, 1080; $g = [Drawing.Graphics]::FromImage($bmp); $g.DrawImage($img, (New-Object Drawing.Rectangle -ArgumentList 0, 0, 1920, 1080), (New-Object Drawing.Rectangle -ArgumentList 0, 0, 1920, ([math]::Min(1080, $img.Height))), [Drawing.GraphicsUnit]::Pixel); $g.Dispose(); $img.Dispose(); $bmp.Save($dest, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); Remove-Item $r.png }
    $onScreen = [bool]($r.text -match '(?m)^ok the picture shows the message')
    Check "picture tests\shots\keymsg-$mode.png (the message is on screen: $onScreen)" ((Test-Path $dest) -and $onScreen)
  }
}

# ---------------------------------------------------------------- 4. the real irdash (only when the rig is free and the route is deployed)
Section '4. live irdash'
$api = 'http://localhost:8199'
function Get-Code($url) { try { $r = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 5; return @{ code = [int]$r.StatusCode; body = $r.Content } } catch { if ($_.Exception.Response) { return @{ code = [int]$_.Exception.Response.StatusCode; body = '' } } return @{ code = 0; body = '' } } }
$probe = Get-Code "$api/keymsg"
$busy = Get-RigBusy
if ($probe.code -eq 0) { "  skip  live: irdash does not answer on $api (not running)" }
elseif ($probe.code -eq 404) { "  skip  live: the running irdash has no /keymsg yet (404): deploy first, then run this test again" }
elseif ($busy) { "  skip  live: $busy (a test message would appear on his top screen)" }
else {
  $j0 = $probe.body | ConvertFrom-Json
  $r = Get-Code "$api/api/keymsg?key=keymsg-test&text=Waiting%20for%20the%20car%20to%20stop&kind=wait"
  Check 'GET /api/keymsg answers 200' ($r.code -eq 200)
  $j = (Get-Code "$api/keymsg").body | ConvertFrom-Json
  Check 'GET /keymsg returns the message: seq up by one, key, text, kind, at' ($j.seq -eq $j0.seq + 1 -and $j.key -eq 'keymsg-test' -and $j.text -eq 'Waiting for the car to stop' -and $j.kind -eq 'wait' -and $j.at -gt 1700000000000)
  Check 'ageMs is small right after' ($j.ageMs -ge 0 -and $j.ageMs -lt 3000)
  $null = Get-Code "$api/api/keymsg?key=keymsg-test&text=$([uri]::EscapeDataString('<b>hi</b>  there' + ('x' * 100)))&kind=bogus"
  $j = (Get-Code "$api/keymsg").body | ConvertFrom-Json
  Check 'live: angle brackets removed, 80 characters at most, an unknown kind becomes ok' ($j.text -notmatch '[<>]' -and $j.text.Length -le 80 -and $j.kind -eq 'ok')
  $seq = $j.seq
  $r = Get-Code "$api/api/keymsg?key=keymsg-test&text=&kind=ok"
  Check 'live: no text is refused (400) and changes nothing' ($r.code -eq 400 -and ((Get-Code "$api/keymsg").body | ConvertFrom-Json).seq -eq $seq)
  $r = Get-Code "$api/api/keymsg?key=keymsg-test&text=phone&kind=ok&asphone=1"
  Check 'live: treated as a phone it cannot write (404)' ($r.code -eq 404)
}

"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
