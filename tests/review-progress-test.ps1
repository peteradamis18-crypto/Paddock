# review-progress-test.ps1 - offline (W4-6): the progress section of REVIEW, dash\www\app\pages\review-progress.js + .css.
# The section runs in headless Chrome inside a fixture shell (tests\fixtures\review\progress-shell.html: a plan line above it, the card
# screen's gutters) with a pretend data.json; the answers are tests\fixtures\review\progress-*.json (the W4-1 /api/review/progress
# contract). Nothing reaches the real irdash.
#   1. the dots: count and order by date, the latest one bright, the dates under the axis
#   2. the corner trend lines with the gain colour (falls green, rises red, flat plain), only the review's corners
#   3. the iRating line, labelled estimate, hidden with fewer than two races
#   4. the empty states in words (one session, no sessions, no trend yet, request failed)
#   5. no text under 24 px, no gold fill, nothing spills; one request at mount, a refresh on the review list, no timers
#   6. design-lint
# Pictures: tests\shots\rework\review-progress-<state>.png (look at every one).
#   powershell -ExecutionPolicy Bypass -File tests\review-progress-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'dash\www\app'
$fix = Join-Path $root 'tests\fixtures\review'
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'review progress test (W4-6)'
$pass = 0; $fail = 0
function Section($t) { Assert-RigFree -Where $t; $t }

$tmp = Join-Path $env:TEMP ('review-progress-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item -Recurse $app "$tmp\app"
$utf8 = New-Object Text.UTF8Encoding($false)
$read = { param($n) [IO.File]::ReadAllText((Join-Path $fix $n), [Text.Encoding]::UTF8).Trim() }
$fx = "four: $(& $read 'progress-four.json'), two: $(& $read 'progress-two.json'), first: $(& $read 'progress-first.json'), none: $(& $read 'progress-none.json')"
$shellSrc = & $read 'progress-shell.html'
$common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--allow-file-access-from-files', '--window-size=1920,1080', '--hide-scrollbars', '--force-device-scale-factor=1')
function Page([string]$name, [string]$state, [string]$run) {
  $h = $shellSrc.Replace('/*FX*/', $fx).Replace('<!--RUN-->', $run)
  [IO.File]::WriteAllText("$tmp\app\$name.html", $h, $utf8)
  return 'file:///' + ("$tmp\app\$name.html" -replace '\\', '/') + $(if ($state) { '#' + $state } else { '' })
}

$run = @'
<script>
window.__run = async () => {
  const out = [], ok = (what, cond, why) => out.push((cond ? 'ok ' : 'FAIL ') + what + (cond || why == null ? '' : ' -> ' + why));
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const P = window.__P, q = s => document.querySelector('#host ' + s), qa = s => [...document.querySelectorAll('#host ' + s)];
  const txt = s => { const e = q(s); return e ? e.textContent.replace(/\s+/g, ' ').trim() : ''; };
  const probe = c => { const p = document.createElement('div'); p.style.background = 'var(--' + c + ')'; p.style.color = 'var(--' + c + ')'; document.body.appendChild(p); const v = getComputedStyle(p).backgroundColor; p.remove(); return v; };
  const GOLD = probe('gold'), GAIN = probe('gain'), LOSS = probe('loss'), INK = probe('ink'), GOLDDIM = probe('gold-dim');
  const vis = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
  const golds = () => [...document.querySelectorAll('#host *')].filter(e => vis(e) && getComputedStyle(e).backgroundColor === GOLD);
  const small = () => [...document.querySelectorAll('#host *')].filter(e => vis(e) && [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()) && parseFloat(getComputedStyle(e).fontSize) < 24)
    .map(e => (e.getAttribute('class') || e.tagName) + ' ' + getComputedStyle(e).fontSize);
  const spill = () => { const z = document.querySelector('.screen').getBoundingClientRect(); return [...document.querySelectorAll('#host *')].filter(vis).filter(e => { const r = e.getBoundingClientRect(); return r.left < z.left - 1 || r.right > z.right + 1 || r.bottom > innerHeight; }).map(e => e.getAttribute('class') || e.tagName); };
  const trendLines = () => qa('.trend').map(e => e.textContent.trim());
  const ARROW = ' ' + String.fromCharCode(0x2192) + ' ';

  // ---------------- 1-3. four sessions, three races ----------------
  window.__mount('four'); await sleep(300);
  const best = qa('circle.best'), avg = qa('circle.avg');
  ok('1. one best-lap dot and one average dot per session (4 and 4)', best.length === 4 && avg.length === 4, best.length + ' / ' + avg.length);
  const ds = best.map(c => +c.dataset.d), xs = best.map(c => +c.getAttribute('cx'));
  ok('1. the dots are in date order left to right (the fixture is out of order)', ds.every((d, i) => !i || ds[i - 1] < d) && xs.every((x, i) => !i || xs[i - 1] < x) && ds[0] === 1793977200000 && ds[3] === 1794605220000, ds.join(',') + ' | ' + xs.join(','));
  ok('1. dots sit on a time axis (6, 9, 12, 13 Nov: the gaps are 3 : 3 : 1 days)', Math.abs((xs[1] - xs[0]) / (xs[3] - xs[2]) - 3.0) < 0.35 * 3 && (xs[3] - xs[2]) > 20, xs.join(','));
  ok('1. a faster lap sits higher (the 12 Nov 1:33.832 dot is the highest best dot)', (() => { const ys = best.map(c => +c.getAttribute('cy')); return ys[2] === Math.min.apply(null, ys); })());
  const lb = qa('circle.best.latest'), la = qa('circle.avg.latest');
  ok('1. exactly one latest dot per series, the newest session, bright (gold / ink) while the others are dim', lb.length === 1 && la.length === 1 && +lb[0].dataset.d === 1794605220000 && getComputedStyle(lb[0]).fill === GOLD && getComputedStyle(best[0]).fill === GOLDDIM && getComputedStyle(la[0]).fill === INK, lb.length + ' ' + (lb[0] && getComputedStyle(lb[0]).fill));
  ok('1. the latest dot is bigger than the others', +lb[0].getAttribute('r') > +best[0].getAttribute('r'));
  const xl = qa('.xlab').map(e => e.textContent);
  ok('1. dates under the axis: first and last ("6 Nov", "13 Nov"), none on top of each other', xl[0] === '6 Nov' && xl[xl.length - 1] === '13 Nov' && xl.length >= 3, xl.join(','));
  ok('1. the lap times at the left are real laps (1:33 .. 1:36)', qa('.ylab').every(e => /^1:3[3-6]\.\d{3}$/.test(e.textContent)), qa('.ylab').map(e => e.textContent).join(','));
  ok('1. the one-line summary: best lap 1:35.106, 0.798 s quicker than on 6 Nov', /Best lap 1:35\.106/.test(txt('.rp-sum')) && txt('.rp-sum').indexOf(String.fromCharCode(0x2212) + '0.798 s') > 0 && /since 6 Nov/.test(txt('.rp-sum')), txt('.rp-sum'));
  ok('1. the title names the place and the car', txt('.rp-title') === 'Progress at Road Atlanta in the GR86', txt('.rp-title'));

  // 2. the corner trend
  const tl = trendLines();
  ok('2. only this review\'s three corners, in the card order (T10b is not one of them)', tl.length === 3 && /^Turn 5:/.test(tl[0]) && /^Turn 8:/.test(tl[1]) && /^Turn 1:/.test(tl[2]), tl.join(' | '));
  ok('2. "Turn 5: lost 0.31 -> 0.22 -> 0.12 s over three sessions"', tl[0] === 'Turn 5: lost 0.31' + ARROW + '0.22' + ARROW + '0.12 s over three sessions', tl[0]);
  const t = qa('.trend');
  ok('2. a corner that falls is gain-coloured, one that rises is loss-coloured, a flat one is plain', getComputedStyle(t[0]).color === GAIN && getComputedStyle(t[1]).color === LOSS && getComputedStyle(t[2]).color === INK, [0, 1, 2].map(i => getComputedStyle(t[i]).color).join(' '));
  ok('2. the pure helper agrees (falls = gain, rises = loss, flat; a mis-ordered fixture is sorted by date)', P.trend({ label: 'T5', lost: [0.12, 0.31, 0.22], dates: [3, 1, 2] }).values.join() === '0.31,0.22,0.12' && P.trend({ label: 'T5', lost: [0.3, 0.1], dates: [1, 2] }).dir === 'gain' && P.trend({ label: 'T5', lost: [0.1, 0.3], dates: [1, 2] }).dir === 'loss' && P.trend({ label: 'T5', lost: [0.101, 0.104], dates: [1, 2] }).dir === 'flat');
  ok('2. the names: T5 is "Turn 5", T10a is "Turn 10a", The Esses stays', P.cornerName({ label: 'T5' }) === 'Turn 5' && P.cornerName({ label: 'T10a' }) === 'Turn 10a' && P.cornerName({ label: 'The Esses' }) === 'The Esses');
  ok('2. at most the last five sessions', P.trend({ label: 'T1', lost: [.9, .8, .7, .6, .5, .4, .3], dates: [1, 2, 3, 4, 5, 6, 7] }).values.length === 5 && /over five sessions/.test(P.trend({ label: 'T1', lost: [.9, .8, .7, .6, .5, .4, .3], dates: [1, 2, 3, 4, 5, 6, 7] }).text));

  // 3. the iRating line
  ok('3. the iRating line: "iRating (estimate) 1,871 +59 over three races" from his own race log', txt('.irating') === 'iRating (estimate) 1,871 +59 over three races', txt('.irating'));
  ok('3. the iRating change is gain-coloured when it rises; one line with 3 dots drawn', getComputedStyle(q('.irtext .chg')).color === GAIN && qa('.irline circle').length === 3 && qa('.irline circle.latest').length === 1);

  // 5. the rules of the screen
  const sm = small(); ok('5. no text under 24 px (HTML and the SVG labels)', sm.length === 0, sm.join('; '));
  const g = golds(); ok('5. no gold fill (the dots are marks, the key swatch is a 16 px dot)', g.filter(e => e.getBoundingClientRect().width > 24).length === 0, g.map(e => e.className).join(','));
  const sp = spill(); ok('5. nothing spills out of the 1728 px screen or off the bottom', sp.length === 0, sp.join(','));
  ok('5. one request at mount, to the contract url', window.__req.length === 1 && window.__req[0] === '/api/review/progress?car=toyotagr86&track=roadatlanta%20full', window.__req.join(' '));
  window.__emit('list:review'); await sleep(200);
  ok('5. a review-list change asks again (and only then): 2 requests', window.__req.length === 2, window.__req.length);
  await sleep(1500);
  ok('5. no timers: nothing asked in the next 1.5 s', window.__req.length === 2, window.__req.length);
  const hostBox = document.getElementById('host').getBoundingClientRect();
  ok('5. the band is 1728 px wide and sits under the plan line (' + Math.round(hostBox.top) + ' px from the top)', Math.round(hostBox.width) === 1728 && hostBox.top > document.querySelector('.plan').getBoundingClientRect().bottom, hostBox.width + ' ' + hostBox.top);

  // 3b / 4. fewer races, fewer sessions
  window.__mount('two'); await sleep(300);
  ok('3. one race in the log: no iRating line at all', q('.irating') === null && !/iRating/.test(document.getElementById('host').textContent), txt('.rp-side'));
  ok('2. a corner with one value says so and promises the trend', /^Turn 5: lost 0.22 s so far$/.test(trendLines()[0]) && /trend shows after the next session/.test(txt('.rp-side')), trendLines().join('|') + ' / ' + txt('.rp-side'));
  ok('2. a corner the data has nothing on (Turn 8, Turn 1) is not made up', trendLines().length === 1, trendLines().join('|'));
  ok('1. two sessions: two dots each, a line joins them', qa('circle.best').length === 2 && qa('circle.avg').length === 2 && qa('polyline.best').length === 1);
  window.__mount('first'); await sleep(300);
  ok('4. one session: "Your first session here: come back after the next one", no chart', txt('.rp-empty') === 'Your first session here: come back after the next one.' && q('svg') === null, txt('.rp-empty'));
  ok('4. one session still shows its best lap in words', /Best lap so far 1:33\.832/.test(txt('.rp-first')), txt('.rp-first'));
  window.__mount('none'); await sleep(300);
  ok('4. no session at all: one plain sentence', /^Nothing here yet: your first session will show up after you drive\.$/.test(txt('.rp-empty')) && q('svg') === null, txt('.rp-empty'));
  window.__mount('fail'); await sleep(300);
  ok('4. a failed request: "Progress is not available right now."', txt('.rp-empty') === 'Progress is not available right now.', txt('.rp-empty'));
  window.__P.unmount();
  ok('5. unmount empties the host and takes its listener off the list', document.getElementById('host').innerHTML === '' && (window.__ls['list:review'] || []).length === 0, document.getElementById('host').innerHTML.length + ' ' + (window.__ls['list:review'] || []).length);
  window.__P.mount(document.getElementById('host'), window.__ctx, window.__opts); window.__P.unmount();
  await sleep(200);
  ok('5. an answer that arrives after unmount draws nothing', document.getElementById('host').innerHTML === '');
  out.push('DONE');
  const o = document.getElementById('out'); o.textContent = out.join('\n'); o.hidden = false;
};
</script>
'@

Section '1-5. the section'
$url = Page 't' '' $run
$p = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=60000', '--dump-dom', $url)) -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out.txt" -RedirectStandardError "$tmp\err.txt" -Wait
$dom = Get-Content "$tmp\out.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
$m = [regex]::Match([string]$dom, '(?s)<pre id="out"[^>]*>(.*?)</pre>')
$text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
$lines = @($text -split [char]10 | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^(ok|FAIL) ' })
$lines | ForEach-Object { '  ' + $_ }
$pass += @($lines | Where-Object { $_ -match '^ok' }).Count; $fail += @($lines | Where-Object { $_ -match '^FAIL' }).Count
if ($text -notmatch 'DONE') { '  FAIL  the page test did not finish'; $fail++; Get-Content "$tmp\err.txt" -ErrorAction SilentlyContinue | Select-Object -Last 5 }

Section '5. source'
function Src($what, $cond) { if ($cond) { $script:pass++; "  ok    5. $what" } else { $script:fail++; "  FAIL  5. $what" } }
$js = [IO.File]::ReadAllText((Join-Path $app 'pages\review-progress.js'))
$css = [IO.File]::ReadAllText((Join-Path $app 'pages\review-progress.css'))
Src 'review-progress.js exports mount(el, ctx, opts) and unmount()' ($js -match 'export function mount\(el, ctx, opts\)' -and $js -match 'export function unmount\(\)')
Src 'no timers, no stream of its own, no POST: data.json and onList only' ($js -notmatch 'setInterval|setTimeout|EventSource|requestAnimationFrame' -and $js -notmatch 'fetch\(' -and $js.Contains('data.json(') -and $js.Contains("onList('review'"))
Src 'no colour literal in the css or the js, no font-size under 24 px in the css' ($css -notmatch '(?i)#[0-9a-f]{3,8}\b|rgba?\(|hsla?\(' -and $js -notmatch '(?i)[''"]#[0-9a-f]{3,8}[''"]|rgba?\(' -and (@([regex]::Matches($css, 'font-size:\s*([^;}]+)') | Where-Object { $_.Groups[1].Value -notmatch 'var\(--t-(body|read|title|display|banner|hero)\)' }).Count -eq 0))
Src 'the old "best lap over time" is not drawn here (that is workbench-career.js, which goes with W4-5)' ($js -notmatch '(?i)best lap over time')

Section '6. design lint'
$dl = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\design-lint-test.ps1') 2>&1 | Out-String
$last = ($dl -split "`n" | Where-Object { $_ -match 'passed, \d+ failed' } | Select-Object -Last 1)
if ($last -match ' 0 failed' -and $LASTEXITCODE -eq 0) { $pass++; "  ok    6. design-lint-test: $($last.Trim())" } else { $fail++; "  FAIL  6. design-lint-test: $last"; ($dl -split "`n" | Where-Object { $_ -match 'FAIL' } | Select-Object -First 5) }

# ---------------- one picture per state ----------------
Section 'pictures'
foreach ($s in 'four', 'two', 'first', 'none', 'fail') {
  $png = Join-Path $shots "review-progress-$s.png"; Remove-Item $png -ErrorAction SilentlyContinue
  $u = Page "s-$s" $s ''
  $p = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=3000', "--screenshot=$png", $u)) -NoNewWindow -PassThru -Wait -RedirectStandardError "$tmp\err-$s.txt" -RedirectStandardOutput "$tmp\so-$s.txt"
  if (Test-Path $png) { $pass++; "  ok    picture: $png" } else { $fail++; "  FAIL  no picture for $s" }
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
