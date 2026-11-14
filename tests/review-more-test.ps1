# review-more-test.ps1 - offline: REVIEW > MORE DATA (W4-5; dash\www\app\pages\review-more.js hosting v2\workbench.html in the shell's frame).
# A made-up lap (tests\tools\review-more-fixtures.ps1) is served by the pretend irdash (tests\tools\pretend-irdash.exe, never port 8199) next to a copy of
# dash\www, and headless Chrome mounts the module in a 1920 x 992 page area under an 88 px header, the way the shell does.
#   1. the four tabs only (DRIVER, BRAKING, SPLITS, RACE) and nothing else in the bar; the links by install state (Pi / Delta / neither); EXPORT CSV;
#      the words under Pi; a 20 px floor (DOM text, canvas text, the css, and the lean-in list of design-lint)
#   2. nothing on a timer (no request in 6 s, no POST ever); a deck command through the state part zooms; Esc zooms out first, then goes HOME
#   3. the buttons: EXPORT CSV, OPEN IN PI TOOLBOX and OPEN DELTA send their one request each; the deleted files are gone and nothing points at them;
#      dead-code-test and design-lint-test pass
# Pictures: tests\shots\rework\review-more-<tab>.png (driver, braking, splits, race, plus the links states).
# Nothing reaches the real irdash (port 8199 is never used).
#   powershell -ExecutionPolicy Bypass -File tests\review-more-test.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
$pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
function Section($t) { Assert-RigFree -Where $t; $t }
'REVIEW > MORE DATA test (W4-5)'

. (Join-Path $PSScriptRoot 'tools\review-more-fixtures.ps1')
$tmp = Join-Path $env:TEMP ('review-more-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$www = Join-Path $tmp 'www'; $fx = Join-Path $tmp 'fx'
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item (Join-Path $root 'dash\www') $www -Recurse
New-MoreFixtures -Dir $fx -Pi $true -Delta $false

# the pretend irdash: build it if needed, then start it on a free pair of ports (it also listens on port+1), with our fixtures
powershell -ExecutionPolicy Bypass -File (Join-Path $root 'tests\tools\pretend-irdash.ps1') -Port 8296 -Www $www | Out-Null
powershell -ExecutionPolicy Bypass -File (Join-Path $root 'tests\tools\pretend-irdash.ps1') -Port 8296 -Stop | Out-Null
$exe = Join-Path $root 'tests\tools\bin\pretend-irdash.exe'
function Free($p) { foreach ($q in $p, ($p + 1)) { try { $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $q); $l.Start(); $l.Stop() } catch { return $false } }; return $true }
$port = 0; foreach ($p in 8298, 8302, 8306, 8310, 8314, 8318, 8322, 8326, 8330, 8334, 8338) { if (Free $p) { $port = $p; break } }
if (-not $port) { '  FAIL  no free port between 8298 and 8340'; exit 1 }
$srv = Start-Process -FilePath $exe -ArgumentList @("$port", '--fixtures', "`"$fx`"", '--www', "`"$www`"") -PassThru -WindowStyle Hidden
$base = "http://localhost:$port"
for ($i = 0; $i -lt 40; $i++) { try { $null = (New-Object Net.WebClient).DownloadString("$base/__stats"); break } catch { Start-Sleep -Milliseconds 150 } }

# ---- the page that stands in for the shell: the module mounted in the page area (88 px down, 1920 x 992), a stand-in connection ----
$harness = @'
<!doctype html><html><head><meta charset="utf-8"><title>review-more harness</title>
<link rel="stylesheet" href="design.css"><link rel="stylesheet" href="shell.css">
<style>body{margin:0;width:1920px;height:1080px;overflow:hidden}#page{height:992px;bottom:auto}#hdr{position:fixed;left:0;top:0;width:1920px;height:88px;background:var(--panel)}</style></head>
<body class="shell"><div id="hdr"></div><div id="page"></div><pre id="out" style="position:fixed;left:0;top:1100px"></pre>
<script type="module">
import mod, { onDeck } from './pages/review-more.js';
const Q = new URLSearchParams(location.search), out = [];
const sleep = ms => new Promise(r => setTimeout(r, ms));
const ok = (what, cond, detail) => out.push((cond ? 'ok ' : 'FAIL ') + what + (!cond && detail ? ' | ' + detail : ''));
const listeners = []; let driving = false; const homes = [];
window.addEventListener('message', e => { if (e.data && e.data.paddock === 'esc') homes.push(e.data.token); });
const ctx = { data: { state: { workbench: { seq: 5, cmd: '', arg: '' } }, on(n, f) { listeners.push(f); return () => { }; } }, driving: () => driving, opts: {} };
const stats = () => fetch('/__stats').then(r => r.json());
const frame = () => document.querySelector('#page iframe');
const W = () => frame().contentWindow;
async function ready() { for (let i = 0; i < 80; i++) { const w = frame() && frame().contentWindow; if (w && w.WB && w.WB.ready && w.WB.extras) return true; await sleep(200); } return false; }
async function deck(cmd, arg, seq) { const st = { workbench: { seq, cmd, arg } }; ctx.data.state = st; listeners.forEach(f => f(st, { workbench: true })); await sleep(200); }
(async () => {
  const where = Q.get('page') || 'driver';
  mod.mount(document.getElementById('page'), ctx, { id: 'fixture-lap.ibt', lap: 4, ref: 'pb', page: where });
  const up = await ready();
  ok('the workbench loads in the frame', up);
  if (!up) { document.getElementById('out').textContent = out.join('\n') + '\nDONE'; return; }
  await sleep(1200);
  const d = W().document, WB = W().WB;
  const tabs = [...d.querySelectorAll('#tabs span')].map(s => s.textContent.trim());
  const mode = Q.get('mode') || 'full';
  if (mode === 'links') { document.getElementById('out').textContent = 'tabs=' + tabs.join('|') + '\nchips=' + [...d.querySelectorAll('#tools .addch')].map(b => b.textContent.trim()).join('|') + '\nDONE'; return; }
  if (mode === 'shot') {                                     // a picture: the tab asked for, nothing else done
    if (Q.get('tab')) { WB.cmd('page', Q.get('tab')); await sleep(1200); }
    if (Q.get('zoom')) { WB.cmd('zoom-corner'); await sleep(600); }
    document.getElementById('out').textContent = 'tabs=' + tabs.join(',') + '\nDONE'; return;
  }
  // 1. tabs, links, floor
  ok('1. the bar shows exactly DRIVER, BRAKING, SPLITS, RACE: ' + tabs.join(' / '), tabs.join('|') === 'DRIVER|BRAKING|SPLITS|RACE');
  const chips = [...d.querySelectorAll('#tools .addch')].map(b => b.textContent.trim());
  out.push('chips=' + chips.join('|'));
  const want = Q.get('want') || '';
  ok('1. the links are ' + want, chips.join('|') === want, chips.join('|'));
  const note = d.querySelector('#cwbtn') ? d.querySelector('#cwbtn').parentNode.textContent : '';
  ok('1. the Pi link says what it does (or is absent)', d.querySelector('#cwbtn') ? /opens the whole file in Cosworth's standard layout/.test(note) : true, note);
  const small = []; const all = d.body.querySelectorAll('*');
  for (const e of all) {
    if (e.tagName === 'SCRIPT' || e.tagName === 'STYLE' || e.tagName === 'CANVAS') continue;
    const own = [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
    if (!own) continue; const r = e.getBoundingClientRect(); if (!r.width || !r.height) continue;
    const px = parseFloat(W().getComputedStyle(e).fontSize); if (px < 19.99) small.push(e.tagName + '.' + e.className + ' ' + px + ' ' + e.textContent.trim().slice(0, 20));
  }
  ok('1. every line of page text is 20 px or more (' + all.length + ' elements looked at)', small.length === 0, small.slice(0, 4).join('; '));
  for (const p of ['driver', 'braking', 'splits', 'race']) {
    WB.cmd('page', p); await sleep(400); WB.bench(1, true);
    const boxes = WB.textBoxes().filter(b => b.h < 17.9);
    ok('1. canvas text on ' + p + ' is 20 px or more (' + WB.textBoxes().length + ' pieces)', boxes.length === 0, boxes.slice(0, 3).map(b => b.s + ' ' + b.h).join('; '));
    const lowest = Math.max(...WB.textBoxes().map(b => b.y + b.h));
    ok('1. ' + p + ' keeps its text above the links at the foot (lowest ' + Math.round(lowest) + ' of ' + (W().innerHeight - 60) + ')', WB.state.page === p && lowest <= W().innerHeight - 60);
  }
  WB.cmd('page', 'driver'); await sleep(300);
  const low = [...d.querySelectorAll('.panel')].filter(e => e.getBoundingClientRect().bottom > W().innerHeight - 60);
  ok('1. on DRIVER no display runs into the links at the foot', low.length === 0, low.map(e => e.className + ' ' + Math.round(e.getBoundingClientRect().bottom)).join('; '));

  // 2. nothing on a timer, a deck command, Esc
  await fetch('/__reset'); await sleep(6200);
  const s1 = await stats();
  const traffic = Object.keys(s1.routes || {}).filter(k => !k.startsWith('/__'));
  ok('2. no request at all in 6 s of an open page', traffic.length === 0, traffic.join(' '));
  ok('2. nothing was ever sent to /workbench/cmd or /api/do', !(s1.routes || {})['/workbench/cmd'] && (s1.do || []).length === 0);
  ok('2. a command already in the state when the page opened is not run (seq 5 only learned)', (await deck('page', 'braking', 5), WB.state.page === 'driver'));
  await deck('page', 'braking', 6);
  ok('2. a new deck command through the state part switches the tab', WB.state.page === 'braking');
  await deck('page', 'braking', 6); await deck('page', 'splits', 6);
  ok('2. the same seq is run once (a repeat does nothing)', WB.state.page === 'braking');
  await deck('page', 'driver', 7); await deck('zoom-reset', '', 8);
  const n = WB.data().n; ok('2. not zoomed to begin with', WB.state.z1 - WB.state.z0 > n - 2);
  await deck('zoom-corner', '', 9);
  ok('2. a zoom command zooms', WB.state.z1 - WB.state.z0 < n - 2);
  driving = true; await deck('zoom-reset', '', 10);
  ok('2. while he drives a deck command is ignored', WB.state.z1 - WB.state.z0 < n - 2); driving = false;
  homes.length = 0;
  const esc = () => { const ev = new (W().KeyboardEvent)('keydown', { key: 'Escape', bubbles: true, cancelable: true }); d.dispatchEvent(ev); return ev.defaultPrevented; };
  const used1 = esc(); await sleep(150);
  ok('2. Esc while zoomed resets the zoom and is used up (no HOME)', used1 && WB.state.z1 - WB.state.z0 > n - 2 && homes.length === 0, 'used=' + used1 + ' homes=' + homes.length);
  const used2 = esc(); await sleep(150);
  ok('2. Esc when not zoomed is left alone and reaches the shell (HOME)', !used2 && homes.length === 1, 'used=' + used2 + ' homes=' + homes.length);

  // 3. the buttons
  await fetch('/__reset');
  if (d.querySelector('#csvbtn')) { d.querySelector('#csvbtn').click(); await sleep(800); }
  let s2 = await stats(); const rk = Object.keys(s2.routes || {});
  ok('3. EXPORT CSV asks /analysis/pro/export once (csv, lap and reference)', rk.some(k => k.indexOf('/analysis/pro/export') === 0) && (s2.routes['/analysis/pro/export'] || {}).count === 1, rk.join(' '));
  ok('3. the file name is kept (the export saved)', !!W().WB.exported, JSON.stringify(W().WB.exported));
  if (d.querySelector('#cwbtn')) { d.querySelector('#cwbtn').click(); d.querySelector('#cwbtn').click(); await sleep(500); s2 = await stats(); ok('3. OPEN IN PI TOOLBOX opens one lap through /vault/open (a second press while opening does nothing)', (s2.routes['/vault/open'] || {}).count === 1, JSON.stringify(s2.routes['/vault/open'])); }
  if (d.querySelector('#dlbtn')) { d.querySelector('#dlbtn').click(); await sleep(500); s2 = await stats(); ok('3. OPEN DELTA starts Delta through /api/review/tools?open=delta', (s2.routes['/api/review/tools'] || {}).count >= 1); }
  mod.unmount();
  ok('3. after unmount the deck can do nothing (and no throw)', onDeck({ seq: 99, cmd: 'page', arg: 'braking' }) === false);
  document.getElementById('out').textContent = out.join('\n') + '\nDONE';
})().catch(e => { document.getElementById('out').textContent = out.join('\n') + '\nFAIL harness threw: ' + e + '\nDONE'; });
</script></body></html>
'@
[IO.File]::WriteAllText((Join-Path $www 'app\rm-harness.html'), $harness, (New-Object Text.UTF8Encoding($false)))

$common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--window-size=1920,1080', '--hide-scrollbars')
function Run-Page($query) {
  $p = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=45000', '--dump-dom', "$base/app/rm-harness.html?$query")) -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out.txt" -RedirectStandardError "$tmp\err.txt"
  if (-not $p.WaitForExit(170000)) { try { $p.Kill() } catch { } }
  $dom = Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue
  $m = [regex]::Match([string]$dom, '(?s)<pre id="out"[^>]*>(.*?)</pre>')
  return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
}
function Show($text) {
  $lines = @($text -split "`n" | Where-Object { $_ -match '^(ok|FAIL) ' })
  foreach ($l in $lines) { if ($l -match '^ok ') { $script:pass++; "  $l" } else { $script:fail++; "  $l" } }
  if ($text -notmatch 'DONE') { $script:fail++; '  FAIL  the page did not finish' }
}

try {
  Section '1-3. Pi Toolbox installed, Delta not (the usual rig)'
  New-MoreFixtures -Dir $fx -Pi $true -Delta $false
  $t = Run-Page ('want=' + [uri]::EscapeDataString('EXPORT CSV|OPEN IN PI TOOLBOX'))
  Show $t

  Section '1. both installed: Pi and Delta; neither: only EXPORT CSV'
  New-MoreFixtures -Dir $fx -Pi $true -Delta $true
  $t = Run-Page 'mode=links'
  $line = ($t -split "`n" | Where-Object { $_ -match '^chips=' } | Select-Object -First 1)
  Check 'with both installed the links are CSV, Pi, Delta' ($line -eq 'chips=EXPORT CSV|OPEN IN PI TOOLBOX|OPEN DELTA') $line
  New-MoreFixtures -Dir $fx -Pi $false -Delta $false -Race $false
  $t = Run-Page 'mode=links'
  $line = ($t -split "`n" | Where-Object { $_ -match '^chips=' } | Select-Object -First 1)
  Check 'with neither installed the only link is EXPORT CSV' ($line -eq 'chips=EXPORT CSV') $line
  Check 'with no field log for the session there is no RACE tab' (($t -split "`n" | Where-Object { $_ -match '^tabs=' } | Select-Object -First 1) -eq 'tabs=DRIVER|BRAKING|SPLITS')

  Section 'pictures'
  New-MoreFixtures -Dir $fx -Pi $true -Delta $true
  foreach ($tab in 'driver', 'braking', 'splits', 'race') {
    $png = Join-Path $shots "review-more-$tab.png"; Remove-Item $png -ErrorAction SilentlyContinue
    $null = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=20000', "--screenshot=$png", "$base/app/rm-harness.html?mode=shot&tab=$tab")) -NoNewWindow -PassThru -Wait -RedirectStandardError "$tmp\e-$tab.txt" -RedirectStandardOutput "$tmp\o-$tab.txt"
    Check "picture $png" (Test-Path $png)
  }
  $png = Join-Path $shots 'review-more-braking-zoomed.png'; Remove-Item $png -ErrorAction SilentlyContinue
  $null = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=20000', "--screenshot=$png", "$base/app/rm-harness.html?mode=shot&tab=driver&zoom=1")) -NoNewWindow -PassThru -Wait -RedirectStandardError "$tmp\e-z.txt" -RedirectStandardOutput "$tmp\o-z.txt"
  Check "picture $png (DRIVER zoomed on a corner)" (Test-Path $png)
}
finally {
  try { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue } catch { }
}

Section '3. the deleted files are gone; the page files are clean'
$gone = @('workbench-pro.js', 'workbench-pro.css', 'workbench-career.js', 'workbench-video.js', 'vault.html', 'vault.js', 'vault.css', 'vaultlive.js')
foreach ($g in $gone) { Check "dash\www\v2\$g is deleted" (-not (Test-Path (Join-Path $root "dash\www\v2\$g"))) }
$wbHtml = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\workbench.html'))
Check 'workbench.html loads none of the deleted files and not data.js (no second connection to irdash)' ($wbHtml -notmatch 'workbench-(pro|career|video)|data\.js')
$wbJs = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\workbench.js')) + [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\workbench-race.js')) + [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\workbench-share.js'))
Check 'no workbench file has a setInterval or a /workbench/cmd report (nothing polls)' ($wbJs -notmatch 'setInterval' -and $wbJs -notmatch "/workbench/cmd" -and $wbJs -notmatch 'pollDeck')
Check 'the PRO, CAREER, VIDEO, GRIP, TYRES and SUSPENSION tabs are gone from the page list' ($wbJs -notmatch "id: '(pro|career|video|grip|tyres|suspension)'")
$css = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\workbench.css'))
$small = @([regex]::Matches($css, '(?i)font(?:-size)?\s*:\s*(\d+(?:\.\d+)?)px') | Where-Object { [double]$_.Groups[1].Value -lt 20 })
Check 'workbench.css has no text size under 20 px' ($small.Count -eq 0) (($small | ForEach-Object { $_.Value }) -join '; ')
Check 'workbench.js draws canvas text at 20 px at the least' ($wbJs -match 'size = Math\.max\(20, size\)')
$dl = [IO.File]::ReadAllText((Join-Path $root 'tests\design-lint-test.ps1'))
Check 'design-lint holds review-more.js and review-more.css to the 20 px lean-in floor' ($dl -match 'pages/review-more\.js' -and $dl -match 'pages/review-more\.css')
$rm = [IO.File]::ReadAllText((Join-Path $root 'dash\www\app\pages\review-more.js'))
Check 'review-more.js exports mount, unmount and onDeck and has no timer' ($rm -match 'export function mount' -and $rm -match 'export function unmount' -and $rm -match 'export function onDeck' -and $rm -notmatch 'setInterval|setTimeout')
$vc = [IO.File]::ReadAllText((Join-Path $root 'dash\src\vault.cs'))
Check '/api/review/tools is in vault.cs next to /vault/open and the route is open while the vault is off' ($vc -match 'case "/api/review/tools"' -and $vc -match 'path == "/api/review/tools" \|\|')
$tl = [IO.File]::ReadAllText((Join-Path $root 'tests\run-all.ps1'))
Check 'run-all.ps1 lists review-more-test.ps1' ($tl -match "review-more-test\.ps1")

foreach ($child in 'dead-code-test.ps1', 'design-lint-test.ps1') {
  Assert-RigFree -Where $child
  $o = & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $child) 2>&1 | Out-String
  $m = [regex]::Match($o, '(\d+) passed, (\d+) failed')
  Check "$child passes ($($m.Value))" ($m.Success -and $m.Groups[2].Value -eq '0' -and $LASTEXITCODE -eq 0) (($o -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 3) -join ' / ')
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
