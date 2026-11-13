# perf-verdict-test.ps1 - offline (W0-9): the black box's cause rules and sentence, the Performance verdict for the 12 Nov race
# (lap 9, 23.7 fps, track and date), "still being processed", the fps cap from the sim's own setting, the session start time.
# Pure C#: every irdash source is compiled together with tests\tools\perf-verdict-driver.cs (its own Main), nothing is started,
# no port is opened. The 12 Nov file is only read (BelowNormal), and only while the sim is not running.
#   powershell -ExecutionPolicy Bypass -File tests\perf-verdict-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }

'W0-9 Performance verdict and the cause rules'
Assert-RigFree -Where '1. compile'
'Section 1. compile irdash with the test driver'
$build = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
$src = @([regex]::Matches($build, '\$d\\src\\([a-z0-9]+)\.cs') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value + '.cs') } | Select-Object -Unique)
$src += (Join-Path $root 'src\deckstate.cs')
ok "the build list names blackbox.cs and simsettings.cs ($($src.Count) files)" (($src -match 'blackbox\.cs').Count -eq 1 -and ($src -match 'simsettings\.cs').Count -eq 1)
$tmp = Join-Path $env:TEMP "perf-verdict-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$out = & $csc /nologo /target:exe /platform:anycpu /main:IRDash.VerdictDriver "/out:$tmp\verdict.exe" `
  /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll `
  @src (Join-Path $root 'tests\tools\perf-verdict-driver.cs') 2>&1
ok 'irdash and the driver compile together (C# 5, Windows csc)' ($LASTEXITCODE -eq 0) (($out | Where-Object { $_ -match 'error' }) -join ' | ')

Assert-RigFree -Where '2. run'
'Section 2. the rules, the sentence and the 12 Nov race'
$source = 'C:\Users\peter\OneDrive\Documents\iRacing\telemetry\toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt'
$ibt = if (Test-Path $source) { $source } else { '-' }
if ($ibt -eq '-') { '  skip the 12 Nov source file is not on this PC: the race checks are left out' }
if (Test-Path "$tmp\verdict.exe") {
  $lines = & "$tmp\verdict.exe" $ibt
  $driverExit = $LASTEXITCODE
  foreach ($l in $lines) {
    if ($l -match '^\s+ok\s') { $script:pass++ } elseif ($l -match '^\s+FAIL\s') { $script:fail++ }
    $l
  }
  ok 'the driver finished and printed its count' (($lines -match '^DRIVER \d+ ok').Count -eq 1)
  if ($ibt -ne '-') { ok 'the driver read the 12 Nov race and printed its sentence' (($lines -match '^SENTENCE Road Atlanta, 12 Nov').Count -eq 1) }
}

# ---------------------------------------------------------------- 3. the Performance page's top line (headless Chrome, a pretend /perf)
Assert-RigFree -Where '3. page'
'Section 3. the Performance page shows the sentence on its top line'
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$sentence = (($lines | Where-Object { $_ -like 'SENTENCE *' }) -replace '^SENTENCE ', '') | Select-Object -First 1
$verdict = (($lines | Where-Object { $_ -like 'VERDICT *' }) -replace '^VERDICT ', '') | Select-Object -First 1
if (-not $sentence) { $sentence = 'Road Atlanta, 12 Nov 09:28. Lap 9, start/finish: the picture froze for 4 s (worst second 23.7 fps, at 09:46:00). Average 114 fps.'; $verdict = $sentence }
if ($chrome) {
  $www = Join-Path $root 'dash\www\v2'
  $shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
  $last = [ordered]@{ file = 'toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt'; ts = 1794493687000; dur = 1184; secs = 1180; track = 'Road Atlanta'; config = 'Full Course'; key = ''; trackName = 'roadatlanta full'
    car = 'Toyota GR86'; type = 'Race'; field = 20; cars = 19; online = $true; build = ''; avg = 113.9; low1 = 91.8; worst = 23.7; cap = 131; limit = 160; belowPct = 50; dip = 2; cpu = 37; cpuPeak = 309; gpu = 50; gpuPeak = 317
    bg = $null; bgPeak = $null; verdict = 'close'; text = $verdict; usual = $null; net = $null; memory = $null; places = @(); procs = $null }
  $perf = [ordered]@{ ready = $true; now = 1794590000; status = @{ state = 'done'; files = 5; reports = 5; counted = 5; pending = 0 }; last = $last; sessions = @(); hidden = 0; changes = @(); own = @{ drives = 0 }; summary = $sentence }
  $json = $perf | ConvertTo-Json -Depth 6 -Compress
  $stub = "<script>window.fetch = (url) => { const j = o => Promise.resolve(new Response(typeof o === 'string' ? o : JSON.stringify(o), { status: 200 }));" +
          " if (/\/perf\/checklist/.test(url)) return j({ items: [], look: 0, at: 0 }); if (/\/perf(\?|$)/.test(url)) return j(window.__perf); return j('{}'); }; window.__perf = $json;</script>"
  $src2 = [IO.File]::ReadAllText((Join-Path $www 'perf.html'))
  $h = $src2.Replace('<head>', '<head><base href="file:///' + ($www -replace '\\', '/') + '/">' + $stub)
  $tmp2 = Join-Path $env:TEMP "perf-verdict-page-$PID"; New-Item -ItemType Directory -Force $tmp2 | Out-Null
  [IO.File]::WriteAllText("$tmp2\p.html", $h, (New-Object Text.UTF8Encoding($false)))
  $common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp2\prof", '--allow-file-access-from-files', '--window-size=1920,1080', '--hide-scrollbars')
  $null = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=5000', '--dump-dom', ('file:///' + ("$tmp2\p.html" -replace '\\', '/')))) -NoNewWindow -PassThru -RedirectStandardOutput "$tmp2\dom.txt" -RedirectStandardError "$tmp2\err1.txt" -Wait
  $dom = Get-Content "$tmp2\dom.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  $m = [regex]::Match([string]$dom, '<div class="verdict" id="bbLine"[^>]*>(.*?)</div>')
  $shown = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
  ok "the top line of the last-session card is the sentence: $shown" ($m.Success -and $shown -eq $sentence) "dom $([string]$dom.Length) chars"
  ok 'a freeze line is drawn in gold' ($m.Success -and $m.Value -match 'color:var\(--gold\)')
  $png = Join-Path $shots 'perf-freeze.png'; Remove-Item $png -ErrorAction SilentlyContinue
  $null = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=5000', "--screenshot=$png", ('file:///' + ("$tmp2\p.html" -replace '\\', '/')))) -NoNewWindow -PassThru -RedirectStandardOutput "$tmp2\out2.txt" -RedirectStandardError "$tmp2\err2.txt" -Wait
  ok "picture: $png" (Test-Path $png)
  Remove-Item -Recurse -Force $tmp2 -ErrorAction SilentlyContinue
} else { '  skip Chrome not found: no page check' }
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
"perf-verdict-test: $script:pass ok, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
