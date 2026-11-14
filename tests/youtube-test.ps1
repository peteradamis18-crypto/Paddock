# youtube-test.ps1 - offline: YouTube sign-in once, upload a race, survive anything, never twice (W1-2, dash\src\youtube.cs).
# A pretend Google (tests\youtube-google.cs, HttpListener on a free 127.0.0.1 port, made-up client, codes and tokens) plays the
# sign-in page, the token endpoint, the resumable upload, the read-back and thumbnails. No call reaches the real Google.
#   1-3. a throw-away exe built from dash\src (the build.ps1 list) + tests\youtube-main.cs + tests\youtube-google.cs: cases 0-9
#   4.   source checks: no secret goes to the log or a URL, the job is whenFree, dash/yt stays gitignored
# Nothing touches irdash, the sim or any app; dash\yt of the checkout is never used (the harness works in %TEMP%).
#   powershell -ExecutionPolicy Bypass -File tests\youtube-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$tmp = Join-Path $env:TEMP ('yt-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$buildList = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
$srcs = @([regex]::Matches($buildList, '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) }) +
        @([regex]::Matches($buildList, '"\.\.\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('src\' + $_.Groups[1].Value) }) +
        @((Join-Path $PSScriptRoot 'youtube-main.cs'), (Join-Path $PSScriptRoot 'youtube-google.cs'))
$harness = Join-Path $tmp 'youtube-harness.exe'

'W1-2 YouTube: sign in once, upload a race, survive anything, never twice'
try {
  Assert-RigFree -Where '1. compile'
  'Section 1. the harness'
  $cout = & $csc /nologo /target:exe /platform:anycpu /main:IRDash.YouTubeMain "/out:$harness" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll /r:System.Security.dll @srcs 2>&1 | Out-String
  ok 'the harness (dash\src + tests\youtube-main.cs + tests\youtube-google.cs) compiles' (Test-Path $harness) $cout
  if (-not (Test-Path $harness)) { throw 'no harness' }

  Assert-RigFree -Where '2. cases'
  'Section 2. cases 0-9 against the pretend Google'
  $work = Join-Path $tmp 'work'
  $p = Start-Process $harness -ArgumentList "`"$work`"" -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out.txt" -RedirectStandardError "$tmp\err.txt"
  if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { }; ok 'the harness finished within 3 minutes' $false }
  $lines = @(Get-Content "$tmp\out.txt" -ErrorAction SilentlyContinue)
  foreach ($l in $lines) { if ($l -match '^ok (.*)') { ok $Matches[1] $true } elseif ($l -match '^FAIL (.*)') { ok $Matches[1] $false } }
  ok 'the harness ran to the end' ($lines -contains 'DONE') ((Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) + '')

  Assert-RigFree -Where '3. source'
  'Section 3. source checks'
  $yt = Get-Content (Join-Path $root 'dash\src\youtube.cs') -Raw
  $logLines = [regex]::Matches($yt, 'Log\.W\(([^;]*)\);') | ForEach-Object { $_.Groups[1].Value }
  $leaky = @($logLines | Where-Object { $_ -cmatch '\b(secret|verifier|code|t\.Refresh|t\.Access|n\.Access|tok\b|s\.Url|loc\b|url\b|r\.Body|p\.Body|q\.Body|bearer)\b' })
  ok '4. no Log.W line names a secret, code, token, body or the session URL' ($leaky.Count -eq 0) ($leaky -join ' || ')
  ok '4. the upload is one whenFree job (never while a session is on)' ($yt.Contains('Jobs.Run(JobName, Work, true)') -and -not ($yt -match 'Jobs\.Run\([^)]*false\)'))
  ok '4. the job stops between chunks when a session starts (Jobs.ShouldYield) and queues the rest (Jobs.Again)' ($yt.Contains('Jobs.ShouldYield') -and $yt.Contains('Jobs.Again(JobName, Work)'))
  ok '4. the token is kept with DPAPI for this Windows user' ($yt.Contains('ProtectedData.Protect(') -and $yt.Contains('DataProtectionScope.CurrentUser'))
  ok '4. the client secret goes only in a POST body (Form), never in a query string' ($yt -match '"&client_secret=" \+ E\(secret\)' -and -not ($yt -match '\?[^"]*client_secret'))
  ok '4. the sign-in uses a plain TcpListener on loopback, not HttpListener (no URL reservation needed)' ($yt.Contains('new TcpListener(IPAddress.Loopback, 0)') -and -not $yt.Contains('new HttpListener'))
  ok '4. no videos.list call (the youtube.upload scope does not allow it)' (-not ($yt -match '/videos\?part='))
  ok '4. only SignIn opens a browser (one OpenBrowser call site besides the re-open)' (([regex]::Matches($yt, 'OpenBrowser\(')).Count -eq 2)
  ok '4. C# 5 only: no $"...", ?., nameof, out var' (-not ($yt -match '\$"|\?\.|\bnameof\(|out var '))
  $gi = Get-Content (Join-Path $root '.gitignore') -Raw
  ok '4. dash/yt/ is gitignored' ($gi -match '(?m)^dash/yt/\s*$')
  $tracked = & git -C $root ls-files 'dash/yt' 2>$null
  ok '4. nothing under dash/yt is committed' (-not $tracked) ($tracked -join ' ')
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
"`n$($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
