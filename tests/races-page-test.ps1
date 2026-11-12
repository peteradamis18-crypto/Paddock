# races-page-test.ps1 - offline: the MY RACES page on the top screen (dash\www\v2\races.html / races.js, 2026-11-12).
# Builds a copy of races.html with a pretend irdash (fetch answered from a fixture, every request recorded), runs it in
# headless Chrome and checks: races only by default, the three plain buttons on every race, the practice tab, SHARE /
# WATCH / KEEP send the right command, DELETE needs two clicks and the second one deletes. Nothing reaches the real irdash.
# Picture: tests\shots\races-page.png
#   powershell -ExecutionPolicy Bypass -File tests\races-page-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$www = Join-Path $root 'dash\www\v2'
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'MY RACES page test'

$now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$fixture = @"
{"freeGb":283,"races":[
 {"id":"r-today","track":"Road Atlanta","car":"Toyota GR86","type":"Race","startMs":$($now - 3600000),"min":20,"laps":11,"best":93.639,"mb":1101,"saved":true,"exported":true},
 {"id":"p-today","track":"Road Atlanta","car":"Toyota GR86","type":"Practice","startMs":$($now - 7200000),"min":9,"laps":4,"best":96.44,"mb":536,"saved":false,"exported":false},
 {"id":"r-old","track":"Road America","car":"Porsche 718 Cayman GT4","type":"Race","startMs":$($now - 20 * 86400000),"min":19,"laps":8,"best":138.485,"mb":1130,"saved":true,"exported":false}]}
"@

# the pretend irdash: answers the list and the commands, and records what was asked
$stub = @"
<script>
window.__req = [];
window.fetch = (url) => { window.__req.push(String(url));
  const j = (o, ok) => Promise.resolve(new Response(typeof o === 'string' ? o : JSON.stringify(o), { status: ok === false ? 400 : 200 }));
  if (/\/api\/rec\/races/.test(url)) return j(window.__fx);
  if (/\/api\/rec\/delete/.test(url)) { if (!/confirm=yes/.test(url)) return j({ state: 'ASK' });
    const id = decodeURIComponent((/id=([^&]+)/.exec(url) || [])[1] || ''); window.__fx.races = window.__fx.races.filter(r => r.id !== id); return j({ state: 'DELETED' }); }
  if (/c=recsave/.test(url)) window.__fx.races.forEach(r => { if (url.endsWith('a=' + r.id)) r.saved = true; });
  if (/\/api\/do/.test(url)) return j('ok');
  return j('{}', false); };
window.__fx = $fixture;
</script>
"@

# what the test does in the page; results go into <pre id="out">
$run = @'
<pre id="out"></pre>
<script>
(async () => {
  const out = [], ok = (what, cond, why) => out.push((cond ? 'ok ' : 'FAIL ') + what + (cond || !why ? '' : ' -> ' + why));
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const rows = () => [...document.querySelectorAll('.race')];
  const btn = (id, act) => document.querySelector('.race[data-id="' + id + '"] button[data-act="' + act + '"]');
  const msg = () => (document.getElementById('msg').hidden ? '' : document.getElementById('msg').textContent);
  await sleep(800);
  ok('only races at first (2 races, not the practice)', rows().length === 2, rows().length + ' rows');
  ok('the line under the title says how many races and how much space is free', /2 races on this PC/.test(document.getElementById('sub').textContent) && /283 GB/.test(document.getElementById('sub').textContent), document.getElementById('sub').textContent);
  ok('the two how-to notes are on the page', /Drag the file onto YouTube/.test(document.body.textContent) && /click again/i.test(document.body.textContent));
  const r1 = rows()[0];
  ok('newest race first, its day and track shown', r1 && r1.dataset.id === 'r-today' && /Today/.test(r1.textContent) && /Road Atlanta/.test(r1.textContent));
  ok('a race shows WATCH, SHARE ON YOUTUBE and DELETE FROM PC', !!btn('r-today', 'watch') && /Share on YouTube/i.test(btn('r-today', 'share').textContent) && /Delete from PC/i.test(btn('r-today', 'del').textContent));
  ok('a kept race says Kept and has no KEEP button', /Kept/.test(r1.textContent) && !btn('r-today', 'keep'));
  ok('the facts: car, minutes, laps, best lap, size', /Toyota GR86/.test(r1.textContent) && /20 min/.test(r1.textContent) && /11 laps/.test(r1.textContent) && /1:33\.639/.test(r1.textContent) && /1\.1 GB/.test(r1.textContent), r1.textContent);

  document.getElementById('tabAll').click(); await sleep(100);
  ok('Practice and qualifying too: all 3 sessions', rows().length === 3, rows().length + ' rows');
  ok('the practice is labelled and can be kept', /Practice/.test(document.querySelector('.race[data-id="p-today"]').textContent) && !!btn('p-today', 'keep'));
  window.__req.length = 0; btn('p-today', 'keep').click(); await sleep(300);
  ok('KEEP sends recsave for that session', window.__req.some(u => u === '/api/do?c=recsave&a=p-today'), window.__req.join(' '));
  ok('after KEEP it says Kept', /Kept/.test(document.querySelector('.race[data-id="p-today"]').textContent));
  document.getElementById('tabRaces').click(); await sleep(100);
  ok('back to races only', rows().length === 2);

  window.__req.length = 0; btn('r-old', 'share').click(); await sleep(300);
  ok('SHARE ON YOUTUBE sends raceexport for that race', window.__req.some(u => u === '/api/do?c=raceexport&a=r-old'), window.__req.join(' '));
  ok('and says what to do next', /Drag the race file onto the YouTube page/.test(msg()), msg());

  window.__req.length = 0; btn('r-old', 'watch').click(); await sleep(300);
  ok('WATCH sends racewatch', window.__req.some(u => u === '/api/do?c=racewatch&a=r-old'), window.__req.join(' '));

  window.__req.length = 0; btn('r-old', 'del').click(); await sleep(200);
  ok('DELETE once asks again and deletes nothing', window.__req.length === 0 && /Click again to delete/i.test(btn('r-old', 'del').textContent), window.__req.join(' '));
  await sleep(5600);
  ok('the question goes away by itself after 5 s', /Delete from PC/i.test(btn('r-old', 'del').textContent));
  btn('r-old', 'del').click(); await sleep(200); btn('r-old', 'del').click(); await sleep(400);
  ok('DELETE twice deletes that race (confirm=yes)', window.__req.some(u => u === '/api/rec/delete?id=r-old&confirm=yes'), window.__req.join(' '));
  ok('the race is gone from the list and the space is reported', rows().length === 1 && /Deleted/.test(msg()), rows().length + ' rows, ' + msg());
  ok('the other race was not touched', !window.__req.some(u => /r-today/.test(u)));
  out.push('DONE');
  document.getElementById('out').textContent = out.join('\n');
})();
</script>
'@

$src = [IO.File]::ReadAllText((Join-Path $www 'races.html'))
$base = '<base href="file:///' + ($www -replace '\\', '/') + '/">'
$h = $src.Replace('<head>', '<head>' + $base + $stub)
$shot = $h.Replace('</body>', "<script>setTimeout(() => document.getElementById('tabRaces').click(), 500);</script></body>")
$h = $h.Replace('</body>', $run + '</body>')
$tmp = Join-Path $env:TEMP ('races-page-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$tmp\t.html", $h, $utf8); [IO.File]::WriteAllText("$tmp\s.html", $shot, $utf8)
$common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--allow-file-access-from-files', '--window-size=1920,1080', '--hide-scrollbars')

Assert-RigFree -Where '1. page'
$p = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=20000', '--dump-dom', ('file:///' + ("$tmp\t.html" -replace '\\', '/')))) -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out.txt" -Wait
$dom = Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue
$m = [regex]::Match([string]$dom, '(?s)<pre id="out">(.*?)</pre>')
$text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
$lines = @($text -split "`n" | Where-Object { $_ -match '^(ok|FAIL) ' })
$lines | ForEach-Object { '  ' + $_ }
$pass = @($lines | Where-Object { $_ -match '^ok' }).Count; $fail = @($lines | Where-Object { $_ -match '^FAIL' }).Count
if ($text -notmatch 'DONE') { '  FAIL  the page test did not finish'; $fail++ }

Assert-RigFree -Where '2. picture'
$png = Join-Path $shots 'races-page.png'; Remove-Item $png -ErrorAction SilentlyContinue
$p = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=3000', "--screenshot=$png", ('file:///' + ("$tmp\s.html" -replace '\\', '/')))) -NoNewWindow -PassThru -Wait
if (Test-Path $png) { $pass++; "  ok    picture: $png" } else { $fail++; '  FAIL  no picture' }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
