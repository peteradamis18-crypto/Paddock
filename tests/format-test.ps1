# format-test.ps1 - offline: dash\www\app\lib\format.js (lap, delta, dur, when, sessionName, size, none) run in headless Chrome.
#   powershell -ExecutionPolicy Bypass -File tests\format-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$js = Join-Path $root 'dash\www\app\lib\format.js'
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
'format.js test'

$page = @'
<pre id="out"></pre>
<script src="FORMATJS"></script>
<script>
const out = [], F = window.Fmt, MINUS = String.fromCharCode(0x2212);
const eq = (what, got, want) => out.push((got === want ? 'ok ' : 'FAIL ') + what + (got === want ? '' : ' -> got [' + got + '] want [' + want + ']'));
eq('lap 93.832', F.lap(93.832), '1:33.832');
eq('lap under a minute', F.lap(59.5), '0:59.500');
eq('lap pads seconds', F.lap(125.04), '2:05.040');
eq('lap rounds up into the next minute', F.lap(119.9996), '2:00.000');
eq('lap none (null)', F.lap(null), F.none);
eq('lap none (0)', F.lap(0), F.none);
eq('lap none (NaN)', F.lap(NaN), F.none);
eq('the no-value mark is an en dash', F.none, String.fromCharCode(0x2013));
eq('delta plus', F.delta(0.123), '+0.123');
eq('delta minus is the real minus sign', F.delta(-0.123), MINUS + '0.123');
eq('delta zero', F.delta(0), '0.000');
eq('delta none', F.delta(undefined), F.none);
eq('delta over a minute', F.delta(-62.5), MINUS + '1:02.500');
eq('dur 12 min', F.dur(720), '12 min');
eq('dur 1 h 02', F.dur(3720), '1 h 02');
eq('dur exactly 1 h', F.dur(3600), '1 h 00');
eq('dur seconds', F.dur(45), '45 s');
eq('dur none', F.dur(null), F.none);
eq('when is New York (EST in November)', F.when('2026-11-11T14:28:00Z'), 'Wed 11 Nov, 09:28');
eq('when is New York (EDT in summer)', F.when('2026-07-04T14:28:00Z'), 'Sat 4 Jul, 10:28');
eq('when takes a millisecond number', F.when(Date.UTC(2026, 10, 12, 14, 28)), 'Thu 12 Nov, 09:28');
eq('when bad input', F.when('nonsense'), F.none);
eq('whenRel today', F.whenRel('2026-11-12T14:28:00Z', Date.UTC(2026, 10, 12, 20, 0)), 'Today, 09:28');
eq('whenRel yesterday', F.whenRel('2026-11-11T14:28:00Z', Date.UTC(2026, 10, 12, 20, 0)), 'Yesterday, 09:28');
eq('whenRel older', F.whenRel('2026-11-01T14:28:00Z', Date.UTC(2026, 10, 12, 20, 0)), 'Sun 1 Nov, 09:28');
eq('session Practice', F.sessionName('Practice'), 'Practice');
eq('session warmup is practice', F.sessionName('Warmup'), 'Practice');
eq('session Qualifying', F.sessionName('Lone Qualify'), 'Qualifying');
eq('session Race', F.sessionName('Race'), 'Race');
eq('session Test drive', F.sessionName('Test Drive'), 'Test drive');
eq('session AI race', F.sessionName('AI Race'), 'AI race');
eq('session unknown/empty', F.sessionName(''), 'Session');
eq('size GB', F.size(1.3 * 1073741824), '1.3 GB');
eq('size MB', F.size(536 * 1048576), '536 MB');
eq('size KB', F.size(2048), '2 KB');
eq('size none', F.size(undefined), F.none);
out.push('DONE');
document.getElementById('out').textContent = out.join('\n');
</script>
'@
$tmp = Join-Path $env:TEMP ('format-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
$html = '<meta charset="utf-8">' + $page.Replace('FORMATJS', 'file:///' + ($js -replace '\\', '/'))
[IO.File]::WriteAllText("$tmp\t.html", $html, (New-Object Text.UTF8Encoding($false)))
Assert-RigFree -Where '1. run in Chrome'
Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--allow-file-access-from-files', '--virtual-time-budget=5000', '--dump-dom', ('file:///' + ("$tmp\t.html" -replace '\\', '/'))) -NoNewWindow -RedirectStandardOutput "$tmp\out.txt" -Wait
$dom = Get-Content "$tmp\out.txt" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
$m = [regex]::Match([string]$dom, '(?s)<pre id="out">(.*?)</pre>')
$text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
$lines = @($text -split '[\r\n]+' | Where-Object { $_ -match '^(ok|FAIL) ' })
$lines | ForEach-Object { '  ' + $_ }
$pass = @($lines | Where-Object { $_ -match '^ok' }).Count; $fail = @($lines | Where-Object { $_ -match '^FAIL' }).Count
if ($text -notmatch 'DONE') { '  FAIL  the page did not finish'; $fail++ }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
