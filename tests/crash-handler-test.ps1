# crash-handler-test.ps1 (W0-2) - one exception on a thread used to end irdash with no log line (no handler anywhere in dash\src).
# Now dash\src\log.cs Crash logs it and the program (and its tray) stays up; dash\irdash.exe.config keeps a dying background thread
# from taking the process with it. OFFLINE: compiles log.cs with tests\crash-harness.cs, runs it next to a copy of the real config.
#   powershell -ExecutionPolicy Bypass -File tests\crash-handler-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP "crash-test-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Run($exe, $mode) {
  $log = Join-Path $tmp "$mode-$([guid]::NewGuid().ToString('N').Substring(0,6)).log"
  $psi = New-Object Diagnostics.ProcessStartInfo $exe, "$mode `"$log`""
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi); $so = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd(); $p.WaitForExit(); Set-Content "$log.out" $so
  $lines = @(if (Test-Path $log) { Get-Content $log } else { })
  return @{ code = $p.ExitCode; out = $(if (Test-Path "$log.out") { Get-Content "$log.out" -Raw } else { '' }); lines = $lines; crash = @($lines | Where-Object { $_ -match '  crash: ' }) }
}
try {
  '0. build'
  $cfg = Join-Path $root 'dash\irdash.exe.config'
  Check 'dash\irdash.exe.config exists and is valid XML with the legacy policy on' ((Test-Path $cfg) -and ([xml](Get-Content $cfg -Raw)).configuration.runtime.legacyUnhandledExceptionPolicy.enabled -eq '1')
  $with = Join-Path $tmp 'with'; $without = Join-Path $tmp 'without'; New-Item -ItemType Directory -Force $with, $without | Out-Null
  $out = & $csc /nologo /target:exe "/out:$with\harness.exe" /r:System.dll /r:System.Windows.Forms.dll (Join-Path $root 'dash\src\log.cs') (Join-Path $PSScriptRoot 'crash-harness.cs') 2>&1
  Check 'log.cs compiles on its own with the harness' ((Test-Path "$with\harness.exe") -and -not ($out | Where-Object { $_ -match 'error' }))
  if (-not (Test-Path "$with\harness.exe")) { $out; throw 'no build' }
  Copy-Item $cfg "$with\harness.exe.config"
  Copy-Item "$with\harness.exe" "$without\harness.exe"

  ''; '1. a bare thread throws (ac.cs / recaudio.cs before W0-2)'
  $r = Run "$with\harness.exe" 'bare'
  Check 'the program is still running 1.5 s later and ends normally' ($r.code -eq 0 -and $r.out -match 'alive')
  Check 'exactly one log line says what failed and that it keeps running' ($r.crash.Count -eq 1 -and $r.crash[0] -match 'InvalidOperationException: boom on a bare thread' -and $r.crash[0] -match 'keeps running')
  $n = Run "$without\harness.exe" 'bare'
  Check 'control: without the config line .NET ends the program (so the config file is what keeps irdash up)' ($n.code -ne 0 -and $n.out -notmatch 'alive')
  Check 'control: even then the handler leaves one line in the log before it closes' ($n.crash.Count -eq 1 -and $n.crash[0] -match 'is closing')

  ''; '2. a thread wrapped in Crash.Guard (no config needed)'
  $r = Run "$without\harness.exe" 'guard'
  Check 'still running, one line naming the job' ($r.code -eq 0 -and $r.out -match 'alive' -and $r.crash.Count -eq 1 -and $r.crash[0] -match 'ac send: FormatException: boom in a guarded thread')

  ''; '3. the tray thread throws inside its message loop'
  $r = Run "$with\harness.exe" 'ui'
  Check 'the message loop goes on (the tray stays) and one line is logged' ($r.code -eq 0 -and $r.out -match 'alive' -and $r.crash.Count -eq 1 -and $r.crash[0] -match 'the tray thread failed: ArgumentException')

  ''; '4. wired into irdash (source)'
  $ir = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs')); $ac = [IO.File]::ReadAllText((Join-Path $root 'dash\src\ac.cs')); $ra = [IO.File]::ReadAllText((Join-Path $root 'dash\src\recaudio.cs'))
  Check 'irdash installs the handler first thing after the log path' ($ir -match 'Log\.FilePath = Path\.Combine\(Dir, "irdash\.log"\);\s+Crash\.Install\(\);')
  Check 'ac.cs: both bare threads are guarded, double.Parse is gone' ($ac -match 'new Thread\(Crash\.Guard\("ac setting"' -and $ac -match 'new Thread\(Crash\.Guard\("ac send", Send\)\)' -and $ac -notmatch 'double\.Parse\(')
  Check 'recaudio.cs: the capture thread catches and says what failed' ($ra -match 'new Thread\(delegate \(\) \{ try \{ Run\(d, m\); \} catch \(Exception ex\)')
  Check 'a port that will not open shows a tray balloon, not a MessageBox' ($ir -notmatch 'MessageBox\.Show\("Paddock could not start' -and $ir -match 'ShowBalloonTip\(20000, "Paddock could not start"')
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
