# pagehost-test.ps1 - offline: the pages over the dashboard (Sessions, Vault, Performance) open and close reliably
# (dash\www\v2\pagehost.js). Opens tests\pagehost-harness.html from disk in headless Chrome against a mock irdash:
# no network, no live app, safe while Peter races.
#   powershell -ExecutionPolicy Bypass -File tests\pagehost-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
$page = 'file:///' + ((Join-Path $PSScriptRoot 'pagehost-harness.html') -replace '\\', '/')
$prof = Join-Path $env:TEMP ('pagehost-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", '--allow-file-access-from-files', '--virtual-time-budget=40000', '--dump-dom', $page) -NoNewWindow -PassThru -RedirectStandardOutput "$prof.out" -Wait
$dom = Get-Content "$prof.out" -Raw -ErrorAction SilentlyContinue
Remove-Item "$prof.out" -ErrorAction SilentlyContinue; Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue
$m = [regex]::Match([string]$dom, '(?s)<pre id="out">(.*?)</pre>')
$text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
$lines = @($text -split "`n" | Where-Object { $_ -match '^(ok|FAIL) ' })
$lines | ForEach-Object { '  ' + $_ }
$pass = @($lines | Where-Object { $_ -match '^ok' }).Count; $fail = @($lines | Where-Object { $_ -match '^FAIL' }).Count
if ($text -notmatch 'DONE') { '  FAIL  the harness did not finish'; $fail++ }
"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
