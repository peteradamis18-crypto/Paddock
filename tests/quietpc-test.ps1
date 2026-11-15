# quietpc-test.ps1 - offline (W5-2 Quiet PC). Never stops a real service, never runs the real tasks, never runs the setup.
#   1. tools\quiet-pc.ps1 -Preview lists exactly wuauserv, UsoSvc, WSearch and OneDrive, and changes nothing
#   2. -On / -Off on a pretend PC (-Mock): only what was running is stopped, and only that is started again; the two halves
#      (services elevated, OneDrive not); on twice keeps the first list; -Status JSON shape; the log line; the restart note
#   3. the setup / UNDO .cmd files only read (never run): task names, -Verb RunAs, the repo path; -Setup -Preview's plan
#   4. a non-elevated schtasks /Run starts a task of our own (registered here without highest privileges, deleted after)
#   5. irdash: the quiet part and the session hooks through tests\quietpc-main.cs (pretend session, a stub .cmd), sim priority
#   powershell -ExecutionPolicy Bypass -File tests\quietpc-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$tmp = Join-Path $env:TEMP ('quietpc-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$qp = Join-Path $root 'tools\quiet-pc.ps1'
$dataDir = Join-Path $tmp 'data'; $logFile = Join-Path $tmp 'quiet-pc.log'
$realLog = Join-Path $root 'tools\quiet-pc.log'; $realLogBefore = if (Test-Path $realLog) { (Get-Item $realLog).Length } else { -1 }
function QP { param([Parameter(ValueFromRemainingArguments = $true)]$rest) & powershell -NoProfile -ExecutionPolicy Bypass -File $qp -DataDir $dataDir -LogFile $logFile @rest 2>&1 | Out-String }
function Mock($admin, $svc, $od) {
  $f = Join-Path $tmp 'mock.json'
  [IO.File]::WriteAllText($f, (@{ admin = $admin; services = $svc; onedrive = $od; did = @() } | ConvertTo-Json -Depth 4)); $f
}
function MockRead { Get-Content (Join-Path $tmp 'mock.json') -Raw | ConvertFrom-Json }
function Section($n) { Assert-RigFree -Where $n; $n }
function LogLines { if (Test-Path $logFile) { @(Get-Content $logFile) } else { @() } }

try {
  Section '1. -Preview'
  $before = @(Get-Service wuauserv, UsoSvc, WSearch -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + '=' + $_.Status }) -join ','
  $pv = QP -Preview
  $named = @([regex]::Matches($pv, '(?m)^(\w+): ') | ForEach-Object { $_.Groups[1].Value })
  ok "-Preview names exactly wuauserv, UsoSvc, WSearch, OneDrive ($($named -join ', '))" (($named -join ',') -eq 'wuauserv,UsoSvc,WSearch,OneDrive') $pv
  ok '-Preview says it changes nothing and writes no state file and no log line' ($pv -match 'changes nothing' -and -not (Test-Path $dataDir) -and (LogLines).Count -eq 0) $pv
  $after = @(Get-Service wuauserv, UsoSvc, WSearch -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + '=' + $_.Status }) -join ','
  ok "the real services are as they were ($after)" ($before -eq $after)

  Section '2. -On / -Off on a pretend PC'
  $mk = Mock $true @{ wuauserv = 'Stopped'; UsoSvc = 'Running'; WSearch = 'Running' } $true
  $o = QP -On -Mock $mk
  $m = MockRead
  ok "elevated -On stops only what was running: $(@($m.did) -join ', ')" ((@($m.did) -join ',') -eq 'stop UsoSvc,stop WSearch') $o
  $st = Get-Content (Join-Path $dataDir 'state.json') -Raw | ConvertFrom-Json
  ok "state.json: on, since, services = what WAS running ($(@($st.services) -join ','))" ($st.on -eq $true -and [long]$st.since -gt 0 -and (@($st.services) -join ',') -eq 'UsoSvc,WSearch')
  ok 'elevated -On leaves OneDrive alone (it refuses administrator rights: irdash runs that half)' ($o -match 'OneDrive: left to irdash' -and $m.onedrive -eq $true -and -not (Test-Path (Join-Path $dataDir 'onedrive.json')))
  # on twice (irdash restarted mid-session): the second run finds them stopped and must keep the first list
  $since1 = [long]$st.since
  $null = QP -On -Mock $mk
  $st2 = Get-Content (Join-Path $dataDir 'state.json') -Raw | ConvertFrom-Json
  ok "-On twice keeps the first list and time ($(@($st2.services) -join ','))" ((@($st2.services) -join ',') -eq 'UsoSvc,WSearch' -and [long]$st2.since -eq $since1)
  # the OneDrive half, not elevated
  $m = MockRead; $m.admin = $false; [IO.File]::WriteAllText($mk, ($m | ConvertTo-Json -Depth 4))
  $o = QP -On -Mock $mk
  $m = MockRead
  ok 'not elevated -On quits OneDrive (/shutdown) and touches no service' ((@($m.did) -join ',') -eq 'stop UsoSvc,stop WSearch,onedrive /shutdown' -and $o -match 'services: left to the setup task') $o
  $odj = Get-Content (Join-Path $dataDir 'onedrive.json') -Raw | ConvertFrom-Json
  ok 'onedrive.json: paused, since' ($odj.paused -eq $true -and [long]$odj.since -gt 0)
  # setup.json present for -Status, then Windows starts wuauserv by itself mid-session
  [IO.File]::WriteAllText((Join-Path $dataDir 'setup.json'), '{"at":"x","user":"x","logon":"S4U","tasks":["Paddock Quiet PC on","Paddock Quiet PC off"]}')
  $m = MockRead; $m.services.wuauserv = 'Running'; [IO.File]::WriteAllText($mk, ($m | ConvertTo-Json -Depth 4))
  $sj = (QP -Status -Mock $mk).Trim()
  $s = $null; try { $s = $sj | ConvertFrom-Json } catch { }
  ok '-Status prints the quiet JSON: setup, on, since, say, four items in order' ($s -and $s.setup -eq $true -and $s.on -eq $true -and [long]$s.since -gt 0 -and $s.say -and ((@($s.items) | ForEach-Object { $_.id }) -join ',') -eq 'update,search,onedrive,simprio') $sj
  $dot = [char]0xB7
  ok "-Status say: $($s.say)" ($s.say -match ('^Quiet PC on since \d\d:\d\d ' + $dot + ' Windows Update, search and OneDrive paused$'))
  ok '-Status items: update running (Windows restarted it), search paused, onedrive paused' (($s.items | Where-Object id -eq 'update').state -eq 'running' -and ($s.items | Where-Object id -eq 'search').state -eq 'paused' -and ($s.items | Where-Object id -eq 'onedrive').state -eq 'paused')
  ok "the item names are Windows Update, Search indexing, OneDrive, Sim priority" (((@($s.items) | ForEach-Object { $_.name }) -join ',') -eq 'Windows Update,Search indexing,OneDrive,Sim priority')
  ok 'the Status read logs that Windows Update runs again while Quiet PC is on' ((LogLines | Select-Object -Last 1) -match 'status .*Windows Update is running again while Quiet PC is on')
  # off: elevated starts only UsoSvc and WSearch (wuauserv was never ours), then not elevated starts OneDrive
  $m = MockRead; $m.admin = $true; $m.did = @(); [IO.File]::WriteAllText($mk, ($m | ConvertTo-Json -Depth 4))
  $o = QP -Off -Mock $mk
  $m = MockRead
  ok "elevated -Off starts again exactly what it stopped: $(@($m.did) -join ', ')" ((@($m.did) -join ',') -eq 'start UsoSvc,start WSearch') $o
  $st3 = Get-Content (Join-Path $dataDir 'state.json') -Raw | ConvertFrom-Json
  ok 'state.json: on false, services empty' ($st3.on -eq $false -and @($st3.services).Count -eq 0)
  $m.admin = $false; $m.did = @(); [IO.File]::WriteAllText($mk, ($m | ConvertTo-Json -Depth 4))
  $null = QP -Off -Mock $mk
  $m = MockRead
  ok 'not elevated -Off starts OneDrive again (/background)' ((@($m.did) -join ',') -eq 'onedrive /background' -and $m.onedrive -eq $true)
  $m.admin = $true; $m.did = @(); [IO.File]::WriteAllText($mk, ($m | ConvertTo-Json -Depth 4)); $null = QP -Off -Mock $mk
  $m.admin = $false; [IO.File]::WriteAllText($mk, ($m | ConvertTo-Json -Depth 4)); $null = QP -Off -Mock $mk
  $m = MockRead
  ok '-Off a second time does nothing (both halves)' (@($m.did).Count -eq 0)
  $s = (QP -Status -Mock $mk).Trim() | ConvertFrom-Json
  ok "-Status after: on false, say: $($s.say)" ($s.on -eq $false -and [long]$s.since -eq 0 -and $s.say -eq ('Quiet PC off ' + $dot + ' everything handed back'))
  Remove-Item (Join-Path $dataDir 'setup.json')
  $s = (QP -Status -Mock $mk).Trim() | ConvertFrom-Json
  ok "-Status without setup.json: setup false, say: $($s.say)" ($s.setup -eq $false -and $s.say -eq ('Quiet PC ' + $dot + ' not set up'))
  # nothing was running: nothing is recorded, nothing comes back
  Remove-Item (Join-Path $dataDir '*.json')
  $mk = Mock $true @{ wuauserv = 'Stopped'; UsoSvc = 'Stopped'; WSearch = 'Stopped' } $false
  $null = QP -On -Mock $mk; $null = QP -Off -Mock $mk
  ok 'nothing running: -On stops nothing, -Off starts nothing' (@((MockRead).did).Count -eq 0)
  $ll = LogLines
  ok "every run (not -Preview) appends ONE log line ($($ll.Count) lines for 12 runs), with on/off/status and admin/user" ($ll.Count -eq 12 -and ($ll | Where-Object { $_ -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  (on|off|status) \((admin|user)\): ' }).Count -eq 12) ($ll -join "`n")
  ok 'the real tools\quiet-pc.log was not written by these runs' ($(if (Test-Path $realLog) { (Get-Item $realLog).Length } else { -1 }) -eq $realLogBefore)
  $src = Get-Content $qp -Raw
  ok 'the script touches no registry, policy or "pause updates" setting' ($src -notmatch 'HKLM:|HKCU:|Set-ItemProperty|New-ItemProperty|reg(\.exe)? add|PauseUpdates|gpupdate')

  Section '3. setup and UNDO: only read, never run'
  $su = Get-Content (Join-Path $root 'tools\quiet-pc-setup.cmd') -Raw; $un = Get-Content (Join-Path $root 'tools\quiet-pc-setup-UNDO.cmd') -Raw
  ok 'quiet-pc-setup.cmd runs quiet-pc.ps1 -Setup from its own folder (%~dp0)' ($su -match 'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0quiet-pc\.ps1" -Setup')
  ok 'quiet-pc-setup-UNDO.cmd runs quiet-pc.ps1 -Undo from its own folder' ($un -match 'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0quiet-pc\.ps1" -Undo')
  ok 'both say what they do in plain words and name the other one' ($su -match 'Windows Update, search indexing and OneDrive' -and $su -match 'quiet-pc-setup-UNDO\.cmd' -and $un -match 'removes the two Quiet PC tasks')
  ok 'the script asks administrator with Start-Process -Verb RunAs (and passes the user on)' ($src -match "Start-Process powershell -Verb RunAs -Wait -ArgumentList" -and $src -match '-ForUser')
  ok 'the task names are "Paddock Quiet PC on" / "Paddock Quiet PC off"' ($src -match "\`$TaskOn = 'Paddock Quiet PC on'; \`$TaskOff = 'Paddock Quiet PC off'")
  ok 'the tasks: highest privileges, no trigger, S4U (no window can appear), the hidden launcher as fallback' ($src -match '-LogonType S4U -RunLevel Highest' -and $src -notmatch 'New-ScheduledTaskTrigger' -and $src -match 'quiet-pc-hidden\.vbs')
  ok 'UNDO deletes both tasks and the json files' ($src -match 'Unregister-ScheduledTask -TaskName \$t' -and $src -match '\$setupFile, \$stateFile' -and $src -match 'Remove-Item -LiteralPath \$odFile')
  $vb = Get-Content (Join-Path $root 'tools\quiet-pc-hidden.vbs') -Raw
  ok 'the fallback launcher runs quiet-pc.ps1 hidden (window style 0) and only with -On / -Off' ($vb -match 'quiet-pc\.ps1"" " & arg, 0, True' -and $vb -match 'If arg <> "-On" And arg <> "-Off" Then WScript\.Quit 1')
  $sp = QP -Setup -Preview
  $repoQp = [regex]::Escape((Join-Path $root 'tools\quiet-pc.ps1'))
  ok "-Setup -Preview prints the plan: the user, both tasks, the repo's script with -On / -Off" ($sp -match ('Quiet PC setup for ' + [regex]::Escape([Security.Principal.WindowsIdentity]::GetCurrent().Name)) -and $sp -match ('Paddock Quiet PC on: powershell\.exe .*-File "' + $repoQp + '" -On') -and $sp -match ('Paddock Quiet PC off: powershell\.exe .*-File "' + $repoQp + '" -Off')) $sp
  ok '-Setup -Preview registered nothing and wrote no setup.json' (-not (Get-ScheduledTask -TaskName 'Paddock Quiet PC on' -ErrorAction SilentlyContinue) -and -not (Test-Path (Join-Path $dataDir 'setup.json')))
  ok 'the real tasks do not exist on this PC (never set up by a test)' (-not (Get-ScheduledTask -TaskName 'Paddock Quiet PC off' -ErrorAction SilentlyContinue))

  Section '4. a non-elevated schtasks /Run starts our own stand-in task'
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  ok 'this test runs NOT elevated (the same as irdash)' (-not $isAdmin)
  $tn = 'Paddock W5-2 test ' + [guid]::NewGuid().ToString('N').Substring(0, 6)
  $mark = Join-Path $tmp 'standin-ran.txt'
  $vbsT = Join-Path $tmp 'standin.vbs'
  # wscript writes the file: no window at all, so nothing shows on Peter's screens
  [IO.File]::WriteAllText($vbsT, "Set f = CreateObject(""Scripting.FileSystemObject"").CreateTextFile(""$mark"", True)`r`nf.WriteLine ""ran""`r`nf.Close`r`n")
  $registered = $false
  try {
    $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B //Nologo "' + $vbsT + '"')
    $pr = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $tn -Action $act -Principal $pr -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) -ErrorAction Stop | Out-Null
    $registered = $true
  } catch { "  skip schtasks: registering our own task was refused ($($_.Exception.Message)): the non-elevated /Run is not proved here" }
  if ($registered) {
    try {
      $out = & schtasks.exe /Run /TN $tn 2>&1 | Out-String
      ok "schtasks /Run of our own task, not elevated, is accepted (exit $LASTEXITCODE)" ($LASTEXITCODE -eq 0) $out
      $w = [Diagnostics.Stopwatch]::StartNew(); while ($w.ElapsedMilliseconds -lt 15000 -and -not (Test-Path $mark)) { Start-Sleep -Milliseconds 200 }
      ok "and the task really ran (its file appeared after $([int]$w.Elapsed.TotalSeconds) s)" (Test-Path $mark)
      # what the setup does NOT need to do from here: register a highest-privileges task (refused when not elevated)
      $hi = $false
      try { Register-ScheduledTask -TaskName ($tn + ' hi') -Action $act -Principal (New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest) -ErrorAction Stop | Out-Null; $hi = $true } catch { }
      "  info registering a highest-privileges task without administrator: $(if ($hi) { 'ALLOWED' } else { 'refused (so only the setup click can do it)' })"
      if ($hi) { Unregister-ScheduledTask -TaskName ($tn + ' hi') -Confirm:$false -ErrorAction SilentlyContinue }
    } finally {
      Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
      ok 'the stand-in task is deleted again' (-not (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue))
    }
  }

  Section '5. irdash: the quiet part, the session hooks, sim priority (tests\quietpc-main.cs, port 8297)'
  $ird = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
  ok 'irdash.cs: SessionEnded runs Review.QueueLast and QuietPC.SessionEnded; SessionStarted = QuietPC.SessionStarted; QuietPC.Start()' ($ird -match 'StateBuilder\.SessionEnded = delegate \(\) \{ Review\.QueueLast\(\); QuietPC\.SessionEnded\(\); \};' -and $ird -match 'StateBuilder\.SessionStarted = QuietPC\.SessionStarted; QuietPC\.Start\(\);')
  ok 'irdash.cs: the quiet part every 1000 ms' ($ird -match 'StateBuilder\.Add\("quiet", 1000, 1000, QuietPC\.Json\)')
  $allSrc = (Get-ChildItem (Join-Path $root 'dash\src') -Filter *.cs | Where-Object Name -ne 'quietpc.cs' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) -replace '//[^\r\n]*', '' }) -join "`n"   # code only, not the comments
  ok 'no command or route turns Quiet PC on or off (only the hooks call it)' (([regex]::Matches($allSrc, 'QuietPC\.(SessionStarted|SessionEnded|Start\(\))')).Count -eq 3 -and $allSrc -notmatch '"quiet(on|off|pc)"')
  $sb = [IO.File]::ReadAllText((Join-Path $root 'dash\src\statebuilder.cs'))
  ok 'statebuilder.cs: SessionStarted fires when SessionOn rises (the mirror of SessionEnded)' ($sb -match 'if \(!wasSession && on\) \{ try \{ if \(SessionStarted != null\) SessionStarted\(\); \} catch \{ \} \}')
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  $b = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
  ok 'dash\build.ps1 compiles quietpc.cs' ($b -match '"\$d\\src\\quietpc\.cs"')
  $srcs = @([regex]::Matches($b, '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) })
  $srcs += @([regex]::Matches($b, '"\.\.\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('src\' + $_.Groups[1].Value) })
  $srcs += (Join-Path $PSScriptRoot 'quietpc-main.cs')
  $exe = Join-Path $tmp 'quietpc-main.exe'
  $cout = & $csc /nologo /target:exe /optimize+ /platform:anycpu /main:IRDash.QuietPcMain "/out:$exe" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll /r:System.Security.dll @srcs 2>&1 | Out-String
  ok "the harness compiles ($($srcs.Count) files)" (Test-Path $exe) ($cout -split "`n" | Select-String 'error' | Select-Object -First 5 | Out-String)
  if (Test-Path $exe) {
    $www = Join-Path $tmp 'www'; New-Item -ItemType Directory -Force (Join-Path $www 'v2') | Out-Null; Set-Content -Encoding utf8 (Join-Path $www 'v2\a.js') '/* a */'
    $rec = Join-Path $tmp 'stub-record.txt'; $stub = Join-Path $tmp 'quiet-stub.cmd'
    [IO.File]::WriteAllText($stub, "@echo off`r`necho(%1>>""$rec""`r`n")
    $standin = Join-Path $tmp 'qp-standin.exe'; Copy-Item (Join-Path $env:WINDIR 'System32\cmd.exe') $standin
    Assert-RigFree -Where 'the harness'
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = "8297 `"$www`" `"$(Join-Path $tmp 'irdata')`" `"$rec`" `"$standin`""
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['PADDOCK_QUIETPC_CMD'] = $stub
    $pr = [Diagnostics.Process]::Start($psi); try { $pr.PriorityClass = 'BelowNormal' } catch { }
    $out = $pr.StandardOutput.ReadToEnd(); $null = $pr.WaitForExit(180000)
    foreach ($l in ($out -split "`r?`n")) {
      if ($l -match '^\s+ok\s+(.*)$') { $script:pass++; "  ok   $($Matches[1])" }
      elseif ($l -match '^\s+FAIL\s+(.*)$') { $script:fail++; "  FAIL $($Matches[1])" }
      elseif ($l -match '^(Section|\s+info)') { $l }
    }
    ok 'the harness ran to the end' ($out -match 'result: \d+ ok') ($out.Substring([Math]::Max(0, $out.Length - 400)))
    Get-Process qp-standin -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
"quietpc-test: $($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
