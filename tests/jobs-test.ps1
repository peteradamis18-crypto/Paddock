# jobs-test.ps1 (W0-3) - the one background queue for heavy work (dash\src\jobs.cs) and the counted process lookups (proc.cs).
# A whenFree job waits while a (pretend) session is on, runs after the grace period, one at a time, in order; a job queued while
# free runs at once; a job stops at a step when a session starts and the rest runs after it; Status() JSON; background mode.
# OFFLINE: compiles jobs.cs + proc.cs + log.cs with tests\jobs-unit.cs. Touches no irdash, no sim, no screen. Safe while Peter races.
#   powershell -ExecutionPolicy Bypass -File tests\jobs-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP "jobs-test-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
try {
  '0. build'
  $out = & $csc /nologo /target:exe "/out:$tmp\jobs-unit.exe" /r:System.dll /r:System.Core.dll /r:System.Web.Extensions.dll `
    (Join-Path $root 'dash\src\jobs.cs') (Join-Path $root 'dash\src\proc.cs') (Join-Path $root 'dash\src\pending.cs') (Join-Path $root 'dash\src\zorder.cs') (Join-Path $root 'dash\src\log.cs') (Join-Path $PSScriptRoot 'jobs-unit.cs') 2>&1
  Check 'jobs.cs and proc.cs compile on their own (C# 5, Windows csc, only Log from irdash)' ((Test-Path "$tmp\jobs-unit.exe") -and -not ($out | Where-Object { $_ -match 'error' }))
  if (Test-Path "$tmp\jobs-unit.exe") {
    $p = Start-Process "$tmp\jobs-unit.exe" -ArgumentList "`"$tmp`"" -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out.txt" -Wait
    foreach ($l in (Get-Content "$tmp\out.txt")) {
      if ($l -match '^\s+ok\s') { $script:pass++; $l } elseif ($l -match '^\s+FAIL\s') { $script:fail++; $l } elseif ($l -notmatch 'passed, .* failed') { $l }
    }
    $log = if (Test-Path "$tmp\jobs-unit.log") { Get-Content "$tmp\jobs-unit.log" -Raw } else { '' }
    Check 'one log line per job: "jobs: <name> ran (waited x s, took y s)"' ($log -match 'jobs: cut 1 ran \(waited \d+\.\d s, took \d+\.\d s\)')
    Check 'a paused job says so in the log' ($log -match 'jobs: steps paused - a session started; the rest runs after it')
  } else { $out }

  ''; '7. wired into irdash (source)'
  $src = @{}; foreach ($f in 'irdash', 'recorder', 'vault', 'refs', 'bench', 'gain', 'career', 'official', 'overlays', 'mydrive', 'doctor', 'ac', 'perf') { $src[$f] = [IO.File]::ReadAllText((Join-Path $root "dash\src\$f.cs")) }
  $build = [IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1'))
  Check 'jobs.cs and proc.cs are in dash\build.ps1' ($build -match 'src\\jobs\.cs' -and $build -match 'src\\proc\.cs')
  Check 'irdash starts the queue and tells it about the session' ($src.irdash -match 'Jobs\.SessionOn = delegate \{ return RigState\.SessionOn; \};' -and $src.irdash -match 'Jobs\.Start\(\);')
  Check 'the recorder: cuts, incident clips and the session file go through Jobs' ($src.recorder -match 'Heavy\("recorder cut ' -and $src.recorder -match 'Heavy\("recorder incident ' -and $src.recorder -match 'Heavy\("recorder session file ')
  Check 'the recorder: retention, export sync, segment and sound pruning are one whenFree job' ($src.recorder -match 'Jobs\.Routine\("recorder housekeeping"')
  Check 'the map builder is a whenFree job and looks the sim up once per build' ($src.irdash -match 'Jobs\.Run\("map " \+ ' -and $src.irdash -match 'bool simUp = RigState\.SimRunning;')
  Check 'the PB reference build and its write wait for the session to end' ($src.refs -match 'Jobs\.Run\("pb reference build ' -and $src.refs -match 'Jobs\.Save\("pb reference save ')
  Check 'field laps are kept in memory during the session and written after' ($src.bench -match 'Jobs\.Save\("field laps save ' -and $src.bench -notmatch 'capAt\).TotalSeconds >= 30')
  Check 'gain and the career page reader are whenFree jobs' ($src.gain -match 'Jobs\.Run\("gain"' -and $src.career -match 'Jobs\.Run\("career ')
  Check 'the career scan is a whenFree job' ($src.irdash -match 'Jobs\.Run\("career scan"')
    $ens = [regex]::Match($src.official, 'static void EnsureData\(\)[\s\S]*?\n        \}').Value
  Check 'official BuildOwned is never run from a request (a job at start and every 6 h), and swaps its result in under the lock' ($src.official -match 'Jobs\.Run\("official owned"' -and $ens -notmatch 'BuildOwned\(\)' -and $src.official -match 'lock \(gate\) \{ owned = o;')
  # review #3: the raw process scans that ran all session are gone (they go through Proc, counted, held handles)
  $ra = [IO.File]::ReadAllText((Join-Path $root 'dash\src\recaudio.cs')); $db = [IO.File]::ReadAllText((Join-Path $root 'dash\src\deltabar.cs')); $sg = [IO.File]::ReadAllText((Join-Path $root 'dash\src\spotterguard.cs'))
  Check 'no raw scans left in the sound capture, the delta bar, the spotter guard or the deck watchdog' ($ra -notmatch 'Process\.GetProcesses\(\)' -and $db -notmatch 'GetProcessesByName' -and $sg -notmatch 'Process\.GetProcessesByName' -and $src.irdash -match 'Process sd = Proc\.Held\("StreamDeck"\)')
  Check 'the deck log is read from where it left off, not 4 MB every 2 s' ($src.irdash -match 'fs\.Position = tailLen;')
  # review #7: the saves are written at exit
  Check 'irdash writes the waiting saves on Exit, on the SHUT DOWN key and when Windows ends the session' ($src.irdash -match 'Exit", null, delegate \{ Jobs\.Drain\(5000\);' -and $src.irdash -match 'dc == "shutdown"\) Jobs\.Drain\(5000\);' -and $src.irdash -match 'SessionEnding \+= delegate \{ Jobs\.Drain\(4000\);')
  # review #5 / #6: long jobs stop for a session, the session file never sleeps on the job thread
  Check 'copies, the PB build and retention stop for a session; the session file goes back instead of waiting on the job thread' ($src.vault -match 'if \(Jobs\.ShouldYield\) throw new OperationCanceledException' -and $src.refs -match 'if \(Jobs\.ShouldYield\) \{ why = "stopped: a session started"' -and $src.recorder -match 'retention paused - a session started' -and $src.recorder -match 'if \(Jobs\.OnWorker\)')
  Check 'the Vault save after a KEEP: one line now, the rest after the session' ($src.vault -match 'AppendMark\(m\)' -and $src.vault -match 'Jobs\.Save\("vault save"')
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
