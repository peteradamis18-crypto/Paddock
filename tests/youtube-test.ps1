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
  ok '4. Paddock takes Google''s client_secret*.json from Downloads by itself (PickUpClient: only while there is no client, files under 7 days old, must name client_id and client_secret, tests point PADDOCK_DOWNLOADS at their own folder)' ($yt.Contains('static void PickUpClient()') -and $yt.Contains('"client_secret*.json"') -and $yt.Contains('PADDOCK_DOWNLOADS') -and $yt.Contains('TotalDays < 7') -and $yt.Contains('if (File.Exists(ClientFile)') -and $yt.Contains('PickUpClient();'))
  ok '4. the client secret goes only in a POST body (Form), never in a query string' ($yt -match '"&client_secret=" \+ E\(secret\)' -and -not ($yt -match '\?[^"]*client_secret'))
  ok '4. the sign-in uses a plain TcpListener on loopback, not HttpListener (no URL reservation needed)' ($yt.Contains('new TcpListener(IPAddress.Loopback, resume != null ? resume.Port : 0)') -and -not $yt.Contains('new HttpListener'))
  ok '4. no videos.list call (the youtube.upload scope does not allow it)' (-not ($yt -match '/videos\?part='))
  ok '4. only SignIn opens a browser (one OpenBrowser call site besides the re-open)' (([regex]::Matches($yt, 'OpenBrowser\(')).Count -eq 2)
  # 2026-11-15 live: explorer.exe cuts an address at 260 characters (MAX_PATH); Google's ~450-character sign-in address lost its state and
  # code_challenge, Google answered without a state and Peter saw "Not found" twice. ShellExecute of the address itself keeps it whole.
  ok '4. the browser gets the sign-in address by ShellExecute of the address itself, never through explorer.exe (260-character cut)' ($yt -match 'new System\.Diagnostics\.ProcessStartInfo\(url\) \{ UseShellExecute = true \}' -and -not ($yt -match 'Process\.Start\("explorer\.exe"'))
  ok '4. the sign-in address is longer than explorer.exe allows (the cut was real, not a theory)' (('https://accounts.google.com/o/oauth2/v2/auth?client_id=' + ('x' * 72) + '&redirect_uri=http%3A%2F%2F127.0.0.1%3A55707%2F&response_type=code&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fyoutube.upload&code_challenge=' + ('c' * 43) + '&code_challenge_method=S256&state=' + ('s' * 22) + '&access_type=offline&prompt=consent').Length -gt 260)
  # 2026-11-15/16: the 5-minute window closed twice before Peter got to Chrome, and a deploy in between killed the listener. The page now
  # waits as long as irdash runs, and a restart listens on the same port again (dash\yt\pending.bin with DPAPI, a day at most).
  ok '4. the sign-in page waits as long as irdash runs (SignInTimeoutMs 0 = no limit; tests set a short one)' ($yt -match 'public static int SignInTimeoutMs = 0;' -and $yt.Contains('SignInTimeoutMs > 0 ?'))
  ok '4. a waiting sign-in is noted in dash\yt\pending.bin with DPAPI and listened for again on the same port at start (Start -> ResumeSignIn), for a week' ($yt.Contains('ResumeSignIn();') -and $yt -match 'new TcpListener\(IPAddress\.Loopback, resume != null \? resume\.Port : 0\)' -and $yt -match 'WriteAtomic\(PendingFile, ProtectedData\.Protect\(' -and $yt.Contains('TotalDays > 7'))
  ok '4. a tab from an earlier press gets the out-of-date page (what to press), not a bare "Not found."' ($yt.Contains('Answer(ns, 404, OldPage)') -and $yt.Contains('press Sign in to YouTube again."'))
  # 2026-11-25: Peter clicked through Google's pages in a dead tab of an earlier try (ShellExecute put each sign-in in a tab of whatever window
  # was on top). The sign-in now gets a window of its own (Chrome/Edge app mode) that fills the middle screen; Paddock closes it when done.
  ok '4. the sign-in opens in a window of its own: Chrome when installed (his Google account is there), else Edge, in app mode (--app=), put at 0,0 (the middle screen), maximized, in front' ($yt.Contains('Google\Chrome\Application\chrome.exe') -and $yt.Contains('Microsoft\Edge\Application\msedge.exe') -and $yt.Contains('"--app=\"" + url + "\""') -and $yt.Contains('SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOZORDER)') -and $yt.Contains('ShowWindow(h, SW_MAXIMIZE)') -and $yt.Contains('SetForegroundWindow(h)'))
  ok '4. Paddock closes only the window it opened itself (its handle), only while it shows the final page (its title), a moment after it (WM_CLOSE)' ($yt.Contains('Win.CloseLater(shown, DoneTitle)') -and $yt.Contains('Title(h).StartsWith(title)) PostMessage(h, WM_CLOSE') -and $yt.Contains('Thread.Sleep(2500)'))
  ok '4. a press while the page waits shows that window again instead of opening another' ($yt.Contains('if (Win.Show(signInWindow)) return'))
  # 2026-11-26 09:14: the screens woke from sleep, Windows shuffled the windows and Google's page sat maximized on the dashboard monitor until a press.
  $ird = Get-Content (Join-Path $root 'dash\src\irdash.cs') -Raw
  ok '4. a waiting sign-in window is kept on the middle screen by irdash''s guard loop (every 2 s; never while the sim runs or a session is on; one move per 30 s)' ($yt.Contains('public static void KeepWindow()') -and $yt.Contains('if (h == IntPtr.Zero || Win.FillsPrimary(h)) return;') -and $yt.Contains('TotalSeconds < 30) return;') -and $ird.Contains('if (!Driving && !Sdk.Latest.Connected && !RigState.SimRunning) YouTube.KeepWindow();'))
  ok '4. after a restart (a deploy) irdash finds its waiting window again by the app window''s exact title (a tab in a normal window ends in " - Google Chrome"), so a press shows it instead of opening a second one' ($yt.Contains('IntPtr h = Win.Find(Path.GetFileNameWithoutExtension(exe), GoogleTitle);') -and $yt.Contains('GoogleTitle = "Sign in - Google Accounts"') -and $yt.Contains('if (Title(w) == title) return w;'))
  ok '4. a window maximized on another screen is restored before the move (moved while maximized it kept that screen''s size)' ($yt.Contains('if (IsIconic(h) || IsZoomed(h)) ShowWindow(h, SW_RESTORE);') -and $yt.Contains('!IsZoomed(h)) return false;'))
  ok '4. no "Not found." page on the sign-in port: a favicon gets 204, any other address and a plain visit go to the sign-in page' (-not $yt.Contains('"Not found."') -and $yt.Contains('Answer(ns, 204, "")') -and (([regex]::Matches($yt, 'Redirect\(ns, url\)')).Count -eq 2))
  $main = Get-Content (Join-Path $PSScriptRoot 'youtube-main.cs') -Raw
  ok '4. the harness keeps Peter''s real Downloads out of the test (PADDOCK_DOWNLOADS points at its own folder; 2026-11-16 his real client file broke case 0)' ($main.Contains('Environment.SetEnvironmentVariable("PADDOCK_DOWNLOADS", downloads)'))
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
