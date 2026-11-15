# copy-lint-test.ps1 (W2-5) - offline: no sentences on THE RACE SCREEN, enforced. Peter, 14 Nov: "need to remove sentences and slop
# from the app, your thinking becomes slop on the UI". The sibling of tests\design-lint-test.ps1 (that one reads the files for colours
# and sizes; this one reads what the page actually shows).
# Headless Chrome on dash\www\v2\race.html with the stand-in data.js (tests\tools\race-stub.js), never irdash:
#   A. every fixture state (tests\fixtures\race\*.json: green, short, save, measuring, re-measuring, caution, pit road, rejoin, gallons,
#      practice, qualifying, timed, multiclass), every flag flash, no data, the feed frozen;
#   B. Peter's real race of 14 Nov 21:27 (tests\tools\race-real-timeline.cs: his .ibt + irdash's field log) played at 40x.
# Every visible text node on the page is collected while it runs, and:
#   1. no text node has more than 3 words, except a driver's or a class's name (a word = a token with a letter or a digit)
#   2. no full stop (a "." not followed by a digit: 1:33.832 is a number), no "you", "your", "will" or "please" outside a name
#   3. the fuel line is one of: FUEL 12.3 L · 8.1 LAPS · +1.8 | FUEL 2/3 LAPS | PIT · 12.3 L | PIT NOW · 24 L · HAVE 22 L
#      (GAL in place of L when his iRacing is set to imperial)
#   4. the lint bites: the old sentences are caught
# Every word the page showed is written to tests\last\race-words.txt.
#   powershell -ExecutionPolicy Bypass -File tests\copy-lint-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root 'tests\tools'
. (Join-Path $tools 'cdp-lib.ps1')
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what $why" } }
function Section($t) { Assert-RigFree -Where $t; $t }
$lastDir = Join-Path $root 'tests\last'; New-Item -ItemType Directory -Force $lastDir | Out-Null
$page = 'file:///' + ((Join-Path $root 'dash\www\v2\race.html') -replace '\\', '/')
$outline = Join-Path $root 'dash\maps\t127-roadatlanta-full.json'
$ibt = 'C:\Users\peter\OneDrive\Documents\iRacing\telemetry\toyotagr86_roadatlanta full 2026-11-14 21-27-47.ibt'
$fieldLog = 'C:\Users\peter\iRacingDeck\vault\field\f20261114-212650-2.json'
'COPY LINT on the race screen (W2-5)'

$fx = @{}
foreach ($f in Get-ChildItem (Join-Path $root 'tests\fixtures\race') -Filter *.json) { $fx[$f.BaseName] = [IO.File]::ReadAllText($f.FullName) }
$fxJs = '{' + (($fx.Keys | Sort-Object | ForEach-Object { '"' + $_ + '":' + $fx[$_] }) -join ',') + '}'
$stub = [IO.File]::ReadAllText((Join-Path $tools 'race-stub.js'), [Text.Encoding]::UTF8).Replace('__FX__', $fxJs).Replace('__OUTLINE__', ('file:///' + ($outline -replace '\\', '/')))

# the collector and the rules, in the page: every visible text node of #race, 10 times a second
$lint = @'
(function () {
  window.__seen = {}; window.__fuel = {};
  // a name may be longer than 3 words or end in "." (iRacing's names; shortName cuts a long one with "."): car rows, the gap cells, the class header
  var isName = function (el) { return !!(el.closest('.row:not(.ghost):not(.empty-row):not(.lapr):not(.head):not(.cut) .nm') || el.closest('.g-who') || el.closest('#bOneS') || el.closest('.row.head .p')); };
  window.__words = function (t) { return t.split(/\s+/).filter(function (w) { return /[A-Za-z0-9]/.test(w); }); };
  window.__bad = function (t, name) {
    var why = [];
    if (!name && __words(t).length > 3) why.push('more than 3 words');
    if (!name && /\.(?!\d)/.test(t)) why.push('a full stop');
    if (!name && /\b(you|your|will|please)\b/i.test(t)) why.push('you / your / will / please');
    return why;
  };
  var vis = function (el) { if (!el || el.hidden) return false; var cs = getComputedStyle(el); return cs.visibility !== 'hidden' && cs.display !== 'none' && +cs.opacity > 0.05; };
  setInterval(function () {
    var root = document.getElementById('race'); if (!root) return;
    var walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    while (walk.nextNode()) {
      var n = walk.currentNode, el = n.parentElement, t = n.nodeValue.replace(/\s+/g, ' ').trim();
      if (!t || t === '·') continue;
      var anc = el, ok = true; while (anc && anc !== document.body) { if (!vis(anc)) { ok = false; break; } anc = anc.parentElement; } if (!ok) continue;
      var name = isName(el), key = (name ? 'name:' : '') + t;
      if (!__seen[key]) __seen[key] = { t: t, name: name, why: __bad(t, name), where: (el.id || el.className || el.tagName) };
    }
    var f = document.getElementById('cFuel'); if (f && vis(f)) __fuel[f.innerText.replace(/\s+/g, ' ').trim()] = 1;
  }, 100);
})();
'@

try {
  Cdp-Open 'about:blank' -Port 9398 -Extra @('--allow-file-access-from-files')
  $null = Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $stub + "`n" + $lint }

  Section 'A. every fixture state, every flag, no data, frozen'
  $null = Cdp 'Page.navigate' @{ url = $page }
  $up = $false; for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 150; if ((Cdp-Eval '!!(window.RacePage && RacePage.slots.length && window.__seen)') -eq $true) { $up = $true; break } }
  ok 'race.html started with the stand-in data.js and the collector' $up
  Start-Sleep -Milliseconds 600                      # no data first
  $states = @(
    "__push({ session: __fx['session-single'], race: __fx['race-green'] }); __run({ mePos: 4 });",
    "__push({ race: __fx['race-short'] });", "__push({ race: __fx['race-save'] });", "__push({ race: __fx['race-measuring'] });", "__push({ race: __fx['race-restale'] });",
    "__push({ race: __fx['race-caution'] }); __run({ mePos: 4, lap: 33, pit: [3, 6] });",
    "__push({ race: __fx['race-pit'] }); __run({ mePos: 4, lap: 34, pit: [2] });",
    "__push({ race: __fx['race-pit-rejoin'] }); __run({ mePos: 4, lap: 34, pit: [2] });",
    "__push({ race: __fx['race-pit-rejoin-far'] }); __run({ mePos: 15, lap: 34, pit: [2] });",
    "__push({ race: __fx['race-gallons'] }); __run({ mePos: 4, lap: 34, pit: [2] });",
    "__run({ mePos: 6, lap: 10, lc: 9, sessNum: 0, timeRemain: 1214.5 }); __push({ race: __fx['race-practice'] }); RacePage.laps = [];",
    "RacePage.laps = [{n:5,t:94.863,dirty:false},{n:6,t:93.919,dirty:false},{n:7,t:94.933,dirty:true}];",
    "__run({ mePos: 3, lap: 2, lc: 1, sessNum: 1, timeRemain: 252 }); __push({ race: __fx['race-qualifying'] }); RacePage.laps = [{n:1,t:93.512,dirty:false}];",
    "__push({ race: __fx['race-timed'] }); __run({ mePos: 4, lap: 12, timeRemain: 1330 });",
    "__push({ session: __fx['session-multi'], race: __fx['race-multiclass'] }); __run({ mePos: 18, multi: true });",
    "__push({ race: __fx['race-pit-rejoin-multi'] }); __run({ mePos: 18, multi: true, pit: [2] });",
    "__push({ session: __fx['session-single'], race: __fx['race-green'] }); __run({ mePos: 1 });")
  foreach ($s in $states) { $null = Cdp-Eval ($s + ' 1'); Start-Sleep -Milliseconds 700 }
  foreach ($fl in 'black', 'orange', 'warning', 'checkered', 'red', 'yellow', 'blue', 'white', 'green') {
    $null = Cdp-Eval "window.__flag = '$fl'; 1"; Start-Sleep -Milliseconds 450; $null = Cdp-Eval "window.__flag = ''; 1"; Start-Sleep -Milliseconds 300
  }
  $null = Cdp-Eval "__stop(); RacePage.frameAt = performance.now() - 11500; 1"; Start-Sleep -Milliseconds 600
  $nA = [int](Cdp-Eval 'Object.keys(__seen).length')
  ok "A. the fixture states showed $nA different texts" ($nA -gt 60)

  Section 'B. the real race of 14 Nov at 40x'
  if (-not (Test-Path $ibt) -or -not (Test-Path $fieldLog)) { '  skip the 14 Nov race files are not on this PC' }
  else {
    $tmp = Join-Path $env:TEMP "copy-lint-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
      $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'; $exe = Join-Path $tmp 'timeline.exe'; $tl = Join-Path $tmp 'tl.js'
      $null = & $csc /nologo /target:exe "/out:$exe" /r:System.Web.Extensions.dll (Join-Path $tools 'race-real-timeline.cs') (Join-Path $root 'dash\src\fuel.cs') (Join-Path $root 'dash\src\lapstore.cs') (Join-Path $root 'dash\src\ibtfile.cs') 2>&1
      $p = New-Object Diagnostics.ProcessStartInfo $exe; $p.Arguments = '"' + $ibt + '" "' + $fieldLog + '" "' + $tl + '"'; $p.UseShellExecute = $false; $p.RedirectStandardOutput = $true; $p.CreateNoWindow = $true
      $pr = [Diagnostics.Process]::Start($p); try { $pr.PriorityClass = 'BelowNormal' } catch { }; $null = $pr.StandardOutput.ReadToEnd(); $pr.WaitForExit()
      ok 'the real race feed was built from the .ibt and the field log' (Test-Path $tl)
      $null = Cdp-Eval ("(() => { RacePage.flagFrom = () => ''; const s = document.createElement('script'); s.src = '" + ('file:///' + ($tl -replace '\\', '/')) + "'; document.head.appendChild(s); return 1; })()")
      ok 'the feed is in the page' (Wait-Until '!!window.__tl' 20)
      $before = [int](Cdp-Eval 'Object.keys(__seen).length')
      $null = Cdp-Eval "(() => { const E = __tl.entries; let i = 0; __push({ session: __tl.session }); window.__done = false; const t = setInterval(() => { if (i >= E.length) { clearInterval(t); window.__done = true; return; } __push({ race: E[i].race }); __frame(E[i].v); i++; }, 25); return 1; })()"
      ok 'the race played to the flag' (Wait-Until 'window.__done === true' 90)
      Start-Sleep -Milliseconds 400
      "  info the real race added $([int](Cdp-Eval 'Object.keys(__seen).length') - $before) different texts"
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }

  Section '1-3. the rules over everything the page showed'
  $seen = Cdp-Json 'Object.keys(__seen).map(k => __seen[k])'
  $bad = @($seen | Where-Object { @($_.why).Count -gt 0 })
  ok "1-2. no sentence: nothing over 3 words outside a name, no full stop, no you / your / will / please ($(@($seen).Count) texts)" ($bad.Count -eq 0) (($bad | ForEach-Object { "'$($_.t)' [$($_.where)]: $(@($_.why) -join ', ')" }) -join '; ')
  $fuelRx = '^FUEL( \d+(\.\d)? (L|GAL))?( · \d+(\.\d)? LAPS)?( · [+−]\d+(\.\d)?)?$|^FUEL \d/3 LAPS$|^PIT · \d+(\.\d)? (L|GAL)$|^PIT NOW · \d+ (L|GAL) · HAVE \d+ (L|GAL)$'
  $fuel = @((Cdp-Json 'Object.keys(__fuel)'))
  $badF = @($fuel | Where-Object { $_ -cnotmatch $fuelRx })
  $shapes = @($fuel | ForEach-Object { $_ -replace '\d+(\.\d)?', 'n' } | Select-Object -Unique)
  ok "3. every fuel line is one of the shapes ($($fuel.Count) lines: $($shapes -join ' | '))" ($badF.Count -eq 0 -and $fuel.Count -ge 5) ($badF -join '; ')
  # every word the page can show (numbers folded to n, names left out): the list for the report
  $vocab = @($seen | Where-Object { -not $_.name } | ForEach-Object { ($_.t -replace '[+−-]?\d+([:.]\d+)*(/\d+)?', 'n') } | Sort-Object -Unique)
  $file = Join-Path $lastDir 'race-words.txt'; [IO.File]::WriteAllLines($file, [string[]]$vocab)
  "  info every text the page showed, numbers as n ($($vocab.Count)): $($vocab -join ' | ')"

  Section '4. the lint bites'
  $old = @('Caution laps and pit laps are left out', 'You rejoin P7', 'Waiting for the car', 'Re-measuring after the stop (1 of 3 laps)', 'Pit window: laps 37 to 39', 'Your best', 'Done.')
  $caught = Cdp-Json ("(" + ($old | ConvertTo-Json -Compress) + ").map(t => __bad(t, false).length > 0)")
  ok "the old sentences are caught ($(@($caught | Where-Object { $_ }).Count) of $($old.Count))" (@($caught | Where-Object { $_ }).Count -eq $old.Count)
  ok 'a driver name and a lap time pass (Mcgillivray, 1:33.832, 4x / 17)' ((Cdp-Eval "__bad('Mcgillivray', true).length + __bad('1:33.832', false).length + __bad('4x / 17', false).length") -eq 0)
  ok 'the fuel rule catches the old fuel words' ('23.8 laps of fuel · ~14 to go' -cnotmatch $fuelRx -and 'FUEL 55.0 L · 23.8 LAPS · +2.8' -cmatch $fuelRx)
} catch {
  $script:fail++; "  FAIL  the test stopped: $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage))"
} finally { Cdp-Close }
"$($script:pass) passed, $($script:fail) failed."
if ($script:fail -gt 0 -or $script:pass -eq 0) { exit 1 }
