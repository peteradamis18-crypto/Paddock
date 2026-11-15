# races-hl-test.ps1 - offline: the HIGHLIGHTS card on RACES (W1-11, dash\www\app\pages\races.js + races.css). Same harness as
# tests\races-page-test.ps1: a copy of the shell in headless Chrome, a pretend irdash answering /api/library from a fixture and /api/do.
#   the card follows its race, says "HIGHLIGHTS · 2:41" and nothing more, has its own SHARE (raceshare a=<id>:h), a label once it is on
#   its way, never a tick or OPEN, opens its race when pressed; no card for a race without highlights or for practice.
# Picture: tests\shots\rework\races-highlights.png. Nothing reaches the real irdash.
#   powershell -ExecutionPolicy Bypass -File tests\races-hl-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$www = Join-Path $root 'dash\www\app'
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'RACES highlights card test (W1-11)'
$pass = 0; $fail = 0
$tmp = Join-Path $env:TEMP ('races-hl-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force "$tmp\thumbs" | Out-Null
Add-Type -AssemblyName System.Drawing
$bmp = New-Object Drawing.Bitmap 600, 338
$g = [Drawing.Graphics]::FromImage($bmp)
$br = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle 0, 0, 600, 338), [Drawing.Color]::FromArgb(70, 72, 76), [Drawing.Color]::FromArgb(24, 25, 28), 60)
$g.FillRectangle($br, 0, 0, 600, 338); $g.Dispose()
foreach ($id in 'r1', 'r2', 'r3', 'p1') { $bmp.Save("$tmp\thumbs\$id.jpg", [Drawing.Imaging.ImageFormat]::Jpeg) }
$bmp.Dispose()

$now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds(); $h = 3600000; $d = 86400000
function Race($id, $ms, $hl, $type = 'Race', $track = 'Road Atlanta') {
  $isRace = if ($type -match 'race' -and $type -notmatch 'qual|prac') { 'true' } else { 'false' }
  '{"id":"' + $id + '","track":"' + $track + '","config":"","car":"Toyota GR86","type":"' + $type + '","isRace":' + $isRace + ',"startMs":' + $ms +
  ',"sec":1268,"laps":10,"counted":7,"best":93.832,"bestLap":9,"mb":1101,"kept":false,"thumb":true,"state":{"kind":"none"},"markers":[],"hl":' + $hl + '}'
}
$races = @(
  (Race 'r1' ($now - $h) '{"sec":161,"state":{"kind":"none"}}'),
  (Race 'r2' ($now - $d) '{"sec":95,"state":{"kind":"shared","pct":100,"privacy":"private","url":"https://youtu.be/x"}}' -track 'Spa'),
  (Race 'r3' ($now - 2 * $d) 'null' -track 'Monza'),
  (Race 'p1' ($now - 2 * $h) '{"sec":60,"state":{"kind":"none"}}' -type 'Practice'))
$fixture = '{"storage":{"usedGb":412,"freeGb":280,"trashGb":0,"moreRaces":38,"lowSpace":false},"youtube":{"signedIn":true,"privacy":"private","template":1,"queue":0},"titles":[],"races":[' + ($races -join ',') + '],"trash":[]}'

$stub = @"
<script>
window.__fx = $fixture;
window.__req = []; window.__rig = { online: true, driving: false }; window.__ls = {};
window.data = { __paddock: true, state: {}, seq: -1, telemetry() {}, reloadOnVersion() {}, get rig() { return window.__rig; }, get online() { return window.__rig.online; },
  on(n, f) { (window.__ls[n] = window.__ls[n] || []).push(f); return () => {}; },
  onList(n, f) { (window.__ls['list:' + n] = window.__ls['list:' + n] || []).push(f); },
  fetch(u, o) { return window.fetch(u, o); }, json(u) { return window.fetch(u).then(r => r.json()); } };
window.fetch = (url) => { url = String(url); window.__req.push(url);
  const j = (o, code) => Promise.resolve(new Response(typeof o === 'string' ? o : JSON.stringify(o), { status: code || 200 }));
  if (/^\/api\/library$/.test(url)) return j(JSON.parse(JSON.stringify(window.__fx)));
  if (/^\/api\/do\?c=raceshare/.test(url)) return j({ ok: true, count: 1, signin: false, say: 'Sharing the highlights' });
  return j({ ok: true, say: 'ok' }); };
</script>
"@

$run = @'
<pre id="out"></pre>
<script>
(async () => {
  const out = [], ok = (what, cond, why) => out.push((cond ? 'ok ' : 'FAIL ') + what + (cond || why == null ? '' : ' -> ' + why));
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const hl = id => document.querySelector('.card.hl[data-id="' + id + '"]');
  const race = id => document.querySelector('.card:not(.hl)[data-id="' + id + '"]');
  const order = () => [...document.querySelectorAll('#grid .card')].map(c => c.dataset.id + (c.dataset.hl ? ':h' : ''));
  const cmds = () => window.__req.filter(u => u.indexOf('/api/do') === 0).map(u => decodeURIComponent(u));
  const click = el => el.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  await sleep(600);
  ok('the highlights card comes right after its race; none for a race without highlights', order().join(',') === 'r1,r1:h,r2,r2:h,r3', order().join(','));
  const DOT = String.fromCharCode(183), words = el => el.textContent.replace(/\s+/g, ' ').trim();
  ok('it says HIGHLIGHTS, the dot, 2:41 (161 s)', hl('r1').querySelector('.hlname').textContent === 'HIGHLIGHTS ' + DOT + ' 2:41', hl('r1').querySelector('.hlname').textContent);
  ok('nothing more on it: the label and one SHARE key', words(hl('r1')) === 'HIGHLIGHTS ' + DOT + ' 2:41Share' || words(hl('r1')) === 'HIGHLIGHTS ' + DOT + ' 2:41 Share', words(hl('r1')));
  ok('no tick box and no OPEN on it', !hl('r1').querySelector('.tick') && !hl('r1').querySelector('[data-act="open"]'));
  ok('the race picture on it', !!hl('r1').querySelector('img.pic'));
  ok('on YouTube already: a label, not a key', !hl('r2').querySelector('button') && /On YouTube/i.test(hl('r2').textContent));
  ok('the label reads 36 px (the state size), gold', getComputedStyle(hl('r1').querySelector('.hlname')).fontSize === '36px');
  window.__req.length = 0; click(hl('r1').querySelector('[data-act="sharehl"]')); await sleep(200);
  ok('SHARE sends raceshare a=r1:h, nothing else', cmds().join(' ') === '/api/do?c=raceshare&a=r1:h', cmds().join(' '));
  ok('then a label in its place (Waiting), no second key', !hl('r1').querySelector('button') && /Waiting/i.test(hl('r1').textContent), hl('r1').innerHTML);
  ok('the race card itself is not touched (Not shared)', /Not shared/i.test(race('r1').querySelector('.state').textContent));
  window.__req.length = 0; click(hl('r2')); await sleep(100);
  ok('pressing the card opens its race', !document.getElementById('open').hidden && /Spa/.test(document.getElementById('open').textContent) && cmds().length === 0);
  click(document.querySelector('#open [data-act="close"]')); await sleep(50);
  click(race('r3').querySelector('.tick')); await sleep(50);
  click(hl('r2')); await sleep(50);
  ok('while ticking, pressing it does nothing (it is never ticked)', document.getElementById('open').hidden && !hl('r2').classList.contains('on'));
  click(document.querySelector('.tab[data-tab="pq"]')); await sleep(50);
  ok('practice: no highlights card', !document.querySelector('.card.hl'));
  out.push('DONE');
  document.getElementById('out').textContent = out.join('\n');
})();
</script>
'@

$src = [IO.File]::ReadAllText((Join-Path $www 'index.html'))
$base = '<base href="file:///' + ($www -replace '\\', '/') + '/">'
$utf8 = New-Object Text.UTF8Encoding($false)
$thumbs = 'file:///' + ("$tmp\thumbs\" -replace '\\', '/')
$common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--allow-file-access-from-files', '--window-size=1920,1080', '--hide-scrollbars')
function Page([string]$name, [string]$body) {
  $h = $src.Replace('<head>', '<head>' + $base + $stub)
  if ($body) { $h = $h.Replace('</body>', $body + '</body>') }
  [IO.File]::WriteAllText("$tmp\$name.html", $h, $utf8)
  return 'file:///' + ("$tmp\$name.html" -replace '\\', '/') + '?page=races&intro=0&thumbs=' + [uri]::EscapeDataString($thumbs)
}
try {
  Assert-RigFree -Where 'page'
  $url = Page 't' $run
  Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=20000', '--dump-dom', $url)) -NoNewWindow -Wait -RedirectStandardOutput "$tmp\out.txt" -RedirectStandardError "$tmp\err.txt"
  $dom = Get-Content "$tmp\out.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  $m = [regex]::Match([string]$dom, '(?s)<pre id="out">(.*?)</pre>')
  $text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
  $lines = @($text -split "`n" | Where-Object { $_ -match '^(ok|FAIL) ' })
  $lines | ForEach-Object { '  ' + $_ }
  $pass += @($lines | Where-Object { $_ -match '^ok' }).Count; $fail += @($lines | Where-Object { $_ -match '^FAIL' }).Count
  if ($text -notmatch 'DONE') { '  FAIL  the page test did not finish'; $fail++ }
  Assert-RigFree -Where 'picture'
  $png = Join-Path $shots 'races-highlights.png'; Remove-Item $png -ErrorAction SilentlyContinue
  Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=2500', "--screenshot=$png", (Page 's' ''))) -NoNewWindow -Wait -RedirectStandardError "$tmp\err-s.txt" -RedirectStandardOutput "$tmp\so-s.txt"
  if (Test-Path $png) { $pass++; "  ok    picture: $png" } else { $fail++; '  FAIL  no picture' }
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
