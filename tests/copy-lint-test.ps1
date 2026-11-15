# copy-lint-test.ps1 - offline: no sentences on Peter's screens (docs/rework/PLAN.md section 10 item 10, Peter 2026-11-14: "remove
# sentences and slop from the app"). Headless Chrome draws every fixture state of a page inside its own test's fixture shell and the
# lint reads every visible piece of text on the page. Nothing reaches the real irdash.
#   Mode 1, the race page (screens he sees while driving: numbers and one-word labels only): card W2-5 adds it to this file.
#   Mode 2, off-track pages (W5-6): RIG, REVIEW's card and HOME. On every state of each:
#     - no text over 8 words (a word has a letter in it; numbers, their units (s, m, mph, fps, ...) and the dots between labels do not count)
#     - no element with two sentences (two full stops)
#     - no "you" / "your"
#     Let be: the Doctor's own words (HOME marks them data-copy="doctor"), RIG's nightly log line (.rg-night), and REVIEW's pace line
#     "Your average 1:34.1 · the field 1:34.8 · 19 cars" (card W5-6 keeps it: it is numbers).
# Prints one ok / FAIL line per page state, then the count.
#   powershell -ExecutionPolicy Bypass -File tests\copy-lint-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'dash\www\app'
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'Copy lint (W5-6: off-track pages)'
$pass = 0; $fail = 0
function Section($t) { Assert-RigFree -Where $t; $t }
$utf8 = New-Object Text.UTF8Encoding($false)
$tmp = Join-Path $env:TEMP ('copy-lint-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
# headless Chrome's window has a 16 x 95 px frame: this window size gives the page the top screen's 1920 x 1080
$common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--allow-file-access-from-files', '--window-size=1936,1175', '--hide-scrollbars', '--force-device-scale-factor=1', '--virtual-time-budget=8000', '--dump-dom')

# the lint, run inside each page once it has drawn
$lint = @'
<script>
window.__run = async () => {
  await new Promise(r => setTimeout(r, 1500));
  const out = [];
  const vis = e => !e.closest('[hidden]') && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
  const UNITS = /^(s|m|L|mph|km\/h|fps|°F|°C|GB|ms)$/;      // numbers and their units are not words
  const words = t => t.split(/\s+/).map(w => w.replace(/^[^A-Za-z0-9°]+|[^A-Za-z0-9°]+$/g, '')).filter(w => /[A-Za-z]/.test(w) && !UNITS.test(w)).length;
  const own = e => [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
  let seen = 0;
  for (const e of document.querySelectorAll('#page *')) {
    if (/^(SCRIPT|STYLE)$/.test(e.tagName) || e.closest('svg') || !own(e) || !vis(e)) continue;
    if (e.closest('[data-copy], .rg-night')) continue;               // the Doctor's own words, the nightly log line
    const t = e.textContent.replace(/\s+/g, ' ').trim(); seen++;
    if (words(t) > 8) out.push('over 8 words: "' + t + '"');
    if ((t.match(/[A-Za-z0-9)…][.!?](?=\s|$)/g) || []).length >= 2) out.push('two sentences: "' + t + '"');
    if (!e.closest('.pace') && /\byou(r|rs|'re)?\b/i.test(t)) out.push('"you": "' + t + '"');
  }
  if (!seen) out.push('no text on the page');
  const o = document.getElementById('out'); o.textContent = 'LINT ' + seen + '\n' + out.join('\n') + '\nDONE'; o.hidden = false;
};
</script>
'@

function Lint([string]$page, [string]$state, [string]$file) {
  $null = Start-Process -FilePath $chrome -ArgumentList ($common + @('file:///' + ($file -replace '\\', '/'))) -NoNewWindow -PassThru -Wait -RedirectStandardOutput "$file.out" -RedirectStandardError "$file.err"
  $dom = Get-Content "$file.out" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  $m = [regex]::Match([string]$dom, '(?s)<pre id="out"[^>]*>(.*?)</pre>')
  $text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
  if ($text -notmatch 'DONE') { $script:fail++; "  FAIL  $page $state`: the page did not finish drawing"; return }
  $bad = @($text -split [char]10 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^(LINT \d+|DONE)$' })
  $n = [regex]::Match($text, 'LINT (\d+)').Groups[1].Value
  if ($bad.Count -eq 0) { $script:pass++; "  ok    $page $state ($n lines of text, none a sentence)" }
  else { $script:fail++; "  FAIL  $page $state`: " + ($bad -join ' | ') }
}

Section '0. the lint itself'
# the old words must fail it, the Doctor's own words must not
$f = "$tmp\self.html"
[IO.File]::WriteAllText($f, '<!doctype html><html><head><meta charset="utf-8"></head><body><main id="page"><p>You braked 14 m earlier than your best lap</p>' +
  '<p>The rig is off. Press RIG ON.</p><p>Turn in at the one hundred metre board and keep it flat</p><p>NEXT TIME · Turn 5 · brake 100 m · 0.31 s</p>' +
  '<p data-copy="doctor">Your spotter is muted. Press SPOTTER to hear it again, then try once more.</p></main><pre id="out" hidden></pre>' + $lint + '<script>window.__run();</script></body></html>', $utf8)
$null = Start-Process -FilePath $chrome -ArgumentList ($common + @('file:///' + ($f -replace '\\', '/'))) -NoNewWindow -PassThru -Wait -RedirectStandardOutput "$f.out" -RedirectStandardError "$f.err"
$t = [Net.WebUtility]::HtmlDecode([regex]::Match([string](Get-Content "$f.out" -Raw -Encoding UTF8), '(?s)<pre id="out"[^>]*>(.*?)</pre>').Groups[1].Value)
$got = @($t -split [char]10 | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^(over|two|")' })
if ($got.Count -eq 3 -and $t -match '"you": "You braked' -and $t -match 'two sentences: "The rig is off' -and $t -match 'over 8 words: "Turn in at' -and $t -notmatch 'spotter|NEXT TIME') { $pass++; '  ok    0. the lint catches "you", two sentences and 9+ words; lets the Doctor''s words and "NEXT TIME · Turn 5 · brake 100 m · 0.31 s" be' }
else { $fail++; '  FAIL  0. the lint itself: ' + ($got -join ' | ') }

# ---------------- mode 1: the race page (card W2-5 writes it here) ----------------

# ---------------- mode 2: off-track pages ----------------
Section '2a. RIG'
$fix = Join-Path $root 'tests\fixtures\rig'
$d = "$tmp\rig"; New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item -Recurse $app "$d\app"
$read = { param($n) [IO.File]::ReadAllText((Join-Path $fix $n), [Text.Encoding]::UTF8).Trim() }
$fx = (@('perf-12nov', 'perf-smooth', 'perf-processing') | ForEach-Object { "'$_': " + (& $read "$_.json") }) -join ",`n"
$shell = & $read 'rig-shell.html'
$rigStates = [ordered]@{
  'ready' = "{ state: 'ready', perf: 'perf-12nov', online: true, opts: {} }"; 'one-fault' = "{ state: 'deck-down', perf: 'perf-12nov', online: true, opts: {} }"
  'two-faults' = "{ state: 'two-faults', perf: 'perf-12nov', online: true, opts: {} }"; 'in-session' = "{ state: 'in-session', perf: 'perf-12nov', online: true, opts: {} }"
  'checking' = "{ state: 'checking', perf: 'perf-12nov', online: true, opts: {} }"; 'not-installed' = "{ state: 'not-installed', perf: 'perf-smooth', online: true, opts: {} }"
  'last-smooth' = "{ state: 'iracing-open', perf: 'perf-smooth', online: true, opts: {} }"; 'last-processing' = "{ state: 'ready', perf: 'perf-processing', online: true, opts: {} }"
  'perf-fails' = "{ state: 'ready', perf: 'fail', online: true, opts: {} }"; 'quiet-on' = "{ state: 'quiet-on', perf: 'perf-12nov', online: true, opts: {} }"
  'quiet-off' = "{ state: 'quiet-off', perf: 'perf-12nov', online: true, opts: {} }"; 'ac-off' = "{ state: 'ac-off', perf: 'perf-12nov', online: true, opts: {} }"
  'offline' = "{ state: 'deck-down', perf: 'perf-12nov', online: false, opts: {} }"; 'offline-stale' = "{ state: 'ready', perf: 'perf-12nov', online: true, opts: {}, stale: true }"
}
foreach ($s in $rigStates.Keys) {
  $f = "$d\app\lint-$s.html"
  [IO.File]::WriteAllText($f, $shell.Replace('/*FX*/', $fx).Replace('/*SETUP*/', 'window.__setup = ' + $rigStates[$s] + ';').Replace('<!--RUN-->', $lint), $utf8)
  Lint 'RIG' $s $f
}

Section '2b. REVIEW (the card)'
$fix = Join-Path $root 'tests\fixtures\review'
$d = "$tmp\review"; New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item -Recurse $app "$d\app"
Copy-Item -Force (Join-Path $fix 'map-stub.js') "$d\app\lib\map.js"
Copy-Item -Force (Join-Path $fix 'sub-stub.js') "$d\app\pages\review-laps.js"
Copy-Item -Force (Join-Path $fix 'sub-stub.js') "$d\app\pages\review-progress.js"
$read = { param($n) [IO.File]::ReadAllText((Join-Path $fix $n), [Text.Encoding]::UTF8).Trim() }
$fx = (@('card-practice-8', 'card-practice-2', 'card-race', 'card-nolap', 'card-working') | ForEach-Object { "'$_': " + (& $read "$_.json") }) -join ",`n"
$shell = & $read 'card-shell.html'
$rvStates = [ordered]@{
  'practice-8' = "window.__setup = { fx: 'card-practice-8', online: true, opts: {} };"; 'practice-2' = "window.__setup = { fx: 'card-practice-2', online: true, opts: {} };"
  'race' = "window.__setup = { fx: 'card-race', online: true, opts: {} };"; 'race-watch' = "window.__setup = { fx: 'card-race', online: true, opts: {}, watch: '.cr-watch' };"
  'nolap' = "window.__setup = { fx: 'card-nolap', online: true, opts: {} };"; 'working' = "window.__setup = { fx: 'card-working', online: true, opts: {} };"
  'offline' = "window.__setup = { fx: 'card-practice-8', online: false, opts: {} };"; 'offline-stale' = "window.__setup = { fx: 'card-practice-8', online: true, opts: {}, stale: true };"
  'no-clip' = "window.__setup = { fx: 'card-practice-8', online: true, opts: {} }; window.__fx['card-practice-8'].cards[0].clip = null;"
}
foreach ($s in $rvStates.Keys) {
  $f = "$d\app\lint-$s.html"
  [IO.File]::WriteAllText($f, $shell.Replace('/*FX*/', $fx).Replace('/*SETUP*/', $rvStates[$s]).Replace('<!--RUN-->', $lint), $utf8)
  Lint 'REVIEW' $s $f
}

Section '2c. HOME'
$fix = Join-Path $root 'tests\fixtures\home'
$d = "$tmp\home"; New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item -Recurse $app "$d\app"
Copy-Item -Force (Join-Path $fix 'clock-stub.js') "$d\app\lib\clock.js"
$read = { param($n) [IO.File]::ReadAllText((Join-Path $fix $n), [Text.Encoding]::UTF8).Trim() }
# /official from irdash's own code, as tests\home-test.ps1 makes it (Sat 14 Nov 12:30 UTC)
$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$ou = Join-Path $tmp 'official-unit.exe'
$null = & "$fw\csc.exe" -nologo -nowarn:0649 -r:System.Web.Extensions.dll "-out:$ou" "$root\tests\official-unit.cs" "$root\dash\src\officialcore.cs" "$root\dash\src\official.cs" 2>&1
$ofJson = ''
if (Test-Path $ou) { New-Item -ItemType Directory -Force "$tmp\ofroot" | Out-Null; $ofJson = ((& $ou homefx "$tmp\ofroot" '2026-11-14T12:30:00Z') | Where-Object { $_ -like 'JSON *' } | Select-Object -First 1) -replace '^JSON ', '' }
if ($ofJson -notmatch '"loaded":true') { $fail++; '  FAIL  HOME: /official could not be made from the server code' }
else {
  $fx = 'official: ' + $ofJson + ', library: ' + (& $read 'library.json') + ', home: ' + (& $read 'home.json') + ', state: ' + (& $read 'state.json')
  $shell = & $read 'shell.html'
  $statesJs = & $read 'states.js'
  foreach ($s in 'rig-off', 'rig-on-idle', 'race-soon', 'session-garage', 'offline', 'kids', 'after-drive', 'after-practice', 'rig-problem') {
    $setup = $statesJs + "`nwindow.__base = JSON.stringify(window.__fx);`ntry { sessionStorage.clear(); } catch (e) { }`nwindow.__setups['$s'](window.__fx);"
    $f = "$d\app\lint-$s.html"
    [IO.File]::WriteAllText($f, $shell.Replace('/*FX*/', $fx).Replace('/*SETUP*/', $setup).Replace('<!--RUN-->', $lint), $utf8)
    Lint 'HOME' $s $f
  }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
""
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
