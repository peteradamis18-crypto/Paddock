# Quiet PC (W5-2): while a session is on, Windows Update, search indexing and OneDrive are paused; afterwards exactly what
# was running is handed back. Peter's ONE click is tools\quiet-pc-setup.cmd (UNDO: quiet-pc-setup-UNDO.cmd); after that
# irdash does it on its own at session start and end. Nothing here touches the registry, a policy or "pause updates".
#
#   -Setup    (asks administrator once) registers "Paddock Quiet PC on" / "Paddock Quiet PC off" for Peter, highest
#             privileges, no trigger; writes data\quiet-pc\setup.json
#   -Undo     hands everything back (-Off), deletes both tasks and the json files
#   -On/-Off  elevated (the tasks): the services. Not elevated (irdash): OneDrive. OneDrive refuses to run with
#             administrator rights, so the two halves run in the two places, each writing its own state file:
#             state.json (the services that WERE running) and onedrive.json (OneDrive was running).
#   -Status   prints the "quiet" JSON (the same one irdash's state part sends); no administrator needed
#   -Preview  changes nothing and prints the plan (with -Setup / -Undo: their plan)
# Every run (but -Preview) appends one line to tools\quiet-pc.log. Paddock and Claude never run -Setup or -Undo.
# Test overrides: -ServiceNames, -OneDrivePath, -DataDir, -LogFile, -Mock <json> (a pretend PC: services, onedrive, admin,
# and a list of what would have been done; nothing real is touched).
param([switch]$Setup, [switch]$Undo, [switch]$On, [switch]$Off, [switch]$Status, [switch]$Preview,
      [string[]]$ServiceNames = @('wuauserv', 'UsoSvc', 'WSearch'),
      [string]$OneDrivePath = (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'),
      [string]$DataDir = '', [string]$LogFile = '', [string]$Mock = '', [string]$ForUser = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $DataDir) { $DataDir = Join-Path $root 'data\quiet-pc' }
if (-not $LogFile) { $LogFile = Join-Path $PSScriptRoot 'quiet-pc.log' }
$ServiceNames = @($ServiceNames | ForEach-Object { $_ -split ',' } | Where-Object { $_ })     # "a,b" when started with -File
$TaskOn = 'Paddock Quiet PC on'; $TaskOff = 'Paddock Quiet PC off'
$names = @{ wuauserv = 'Windows Update'; UsoSvc = 'Windows Update'; WSearch = 'search'; OneDrive = 'OneDrive' }
$setupFile = Join-Path $DataDir 'setup.json'; $stateFile = Join-Path $DataDir 'state.json'; $odFile = Join-Path $DataDir 'onedrive.json'

$m = $null
if ($Mock) { $m = Get-Content -LiteralPath $Mock -Raw | ConvertFrom-Json }
$isAdmin = if ($m) { [bool]$m.admin } else { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
$line = New-Object System.Collections.Generic.List[string]     # the one log line of this run
function Note($t) { $t; [void]$line.Add($t) }
function Write-Log($verb) { if (-not $Preview) { New-Item -ItemType Directory -Force (Split-Path $LogFile) | Out-Null; Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $verb + ' (' + $(if ($isAdmin) { 'admin' } else { 'user' }) + '): ' + $(if ($line.Count) { $line -join '; ' } else { '-' })) } }
function NowMs { [long]([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalMilliseconds }
function JStr($s) { '"' + ([string]$s).Replace('\', '\\').Replace('"', '\"') + '"' }
function JArr($a) { '[' + ((@($a) | Where-Object { $_ } | ForEach-Object { JStr $_ }) -join ',') + ']' }
function Put($file, $text) { New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null; [IO.File]::WriteAllText($file, $text) }
function Read-Json($file) { if (Test-Path -LiteralPath $file) { try { return (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) } catch { } }; $null }
function Save-Mock { if ($m) { [IO.File]::WriteAllText($Mock, ($m | ConvertTo-Json -Depth 5)) } }
function Did($what) { if ($m) { $m.did = @($m.did) + $what; Save-Mock } }

# ---- the PC, or the pretend one ----
function Svc-State($n) {
  if ($m) { $v = $m.services.$n; if ($v) { return [string]$v }; return $null }
  $s = Get-Service -Name $n -ErrorAction SilentlyContinue; if ($s) { return [string]$s.Status }; $null
}
function Svc-Stop($n) { if ($m) { $m.services.$n = 'Stopped'; Did ('stop ' + $n); return }; Stop-Service -Name $n -Force -ErrorAction Stop }
function Svc-Start($n) { if ($m) { $m.services.$n = 'Running'; Did ('start ' + $n); return }; Start-Service -Name $n -ErrorAction Stop }
function Od-Running {
  if ($m) { return [bool]$m.onedrive }
  $me = [Diagnostics.Process]::GetCurrentProcess().SessionId
  @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $me }).Count -gt 0
}
function Od-Run($arg) {
  if ($m) { $m.onedrive = ($arg -eq '/background'); Did ('onedrive ' + $arg); return }
  if (-not (Test-Path -LiteralPath $OneDrivePath)) { throw "OneDrive.exe is not at $OneDrivePath" }
  $p = Start-Process -FilePath $OneDrivePath -ArgumentList $arg -PassThru -WindowStyle Hidden
  if ($arg -eq '/shutdown') { [void]$p.WaitForExit(15000) }
}

function Paused-Words($services, $od) {
  $w = @()
  if (@($services) -contains 'wuauserv' -or @($services) -contains 'UsoSvc') { $w += 'Windows Update' }
  if (@($services) -contains 'WSearch') { $w += 'search' }
  foreach ($s in @($services)) { if ($s -and -not $names.ContainsKey($s) -and $w -notcontains $s) { $w += $s } }   # a stand-in name (tests)
  if ($od) { $w += 'OneDrive' }
  if ($w.Count -eq 0) { return 'nothing needed pausing' }
  if ($w.Count -eq 1) { return $w[0] + ' paused' }
  (($w[0..($w.Count - 2)]) -join ', ') + ' and ' + $w[-1] + ' paused'
}

# ---- the services half (needs administrator: the tasks) ----
function Services-On {
  $st = Read-Json $stateFile
  $list = @(); $since = NowMs
  if ($st -and $st.on) { $list = @($st.services | Where-Object { $_ }); if ($st.since) { $since = [long]$st.since } }   # on twice: keep what the first run paused
  foreach ($n in $ServiceNames) {
    $s = Svc-State $n
    if ($s -ne 'Running') { Note ("{0}: {1}, left alone" -f $n, $(if ($s) { $s.ToLower() } else { 'not on this PC' })); continue }
    if ($Preview) { Note ("{0}: running, would stop it" -f $n); continue }
    try { Svc-Stop $n; if ($list -notcontains $n) { $list += $n }; Note ("{0}: stopped" -f $n) } catch { Note ("{0}: could not stop ({1})" -f $n, $_.Exception.Message) }
  }
  if (-not $Preview) { Put $stateFile ('{"on":true,"since":' + $since + ',"services":' + (JArr $list) + ',"at":' + (JStr (Get-Date -Format s)) + '}') }
}
function Services-Off {
  $st = Read-Json $stateFile
  if (-not $st -or -not $st.on) { Note 'services: Quiet PC was not on, nothing to hand back'; return }
  $failed = @()
  foreach ($n in @($st.services | Where-Object { $_ })) {
    $s = Svc-State $n
    if ($s -eq 'Running') { Note ("{0}: already running again" -f $n); continue }
    if ($Preview) { Note ("{0}: would start it again" -f $n); continue }
    try { Svc-Start $n; Note ("{0}: started again" -f $n) } catch { $failed += $n; Note ("{0}: could not start ({1})" -f $n, $_.Exception.Message) }
  }
  if (-not $Preview) { Put $stateFile ('{"on":false,"since":0,"services":[],"failed":' + (JArr $failed) + ',"offAt":' + (NowMs) + '}') }
}

# ---- the OneDrive half (never with administrator: OneDrive refuses that and would show a message on his screen) ----
function OneDrive-On {
  $od = Read-Json $odFile
  if ($od -and $od.paused) { Note 'OneDrive: already paused'; return }
  if (-not (Od-Running)) { Note 'OneDrive: not running, left alone'; if (-not $Preview) { Put $odFile '{"paused":false,"since":0}' }; return }
  if ($Preview) { Note 'OneDrive: running, would quit it (OneDrive.exe /shutdown)'; return }
  try { Od-Run '/shutdown'; Put $odFile ('{"paused":true,"since":' + (NowMs) + ',"path":' + (JStr $OneDrivePath) + '}'); Note 'OneDrive: quit' }
  catch { Note ('OneDrive: could not quit (' + $_.Exception.Message + ')') }
}
function OneDrive-Off {
  $od = Read-Json $odFile
  if (-not $od -or -not $od.paused) { Note 'OneDrive: was not paused, left alone'; return }
  if (Od-Running) { Note 'OneDrive: already running again' }
  elseif ($Preview) { Note 'OneDrive: would start it again (OneDrive.exe /background)'; return }
  else { try { Od-Run '/background'; Note 'OneDrive: started again' } catch { Note ('OneDrive: could not start (' + $_.Exception.Message + ')'); return } }
  if (-not $Preview) { Put $odFile '{"paused":false,"since":0}' }
}

# ---- what Status (and irdash's "quiet" part) says ----
function Sim-Prio {
  $mode = 'high'
  $ini = Join-Path $root 'dash\irdash.ini'
  if (Test-Path -LiteralPath $ini) { foreach ($l in Get-Content -LiteralPath $ini) { if ($l -match '^\s*sim_priority\s*=\s*normal') { $mode = 'normal' } } }
  if ($mode -ne 'high') { return 'off' }
  $p = @(Get-Process -Name iRacingSim64DX11 -ErrorAction SilentlyContinue)
  if ($p.Count -eq 0) { return 'on' }
  try { $c = [string]$p[0].PriorityClass; if ($c -eq 'High' -or $c -eq 'RealTime') { 'on' } else { 'off' } } catch { 'unknown' }
}
function Item-State($list) {
  $any = $false; $known = $false
  foreach ($n in $list) { $s = Svc-State $n; if ($s) { $known = $true; if ($s -eq 'Running') { $any = $true } } }
  if (-not $known) { 'unknown' } elseif ($any) { 'running' } else { 'paused' }
}
function Status-Json {
  $st = Read-Json $stateFile; $od = Read-Json $odFile
  $setupOk = Test-Path -LiteralPath $setupFile
  $svcOn = [bool]($st -and $st.on); $odOn = [bool]($od -and $od.paused)
  $on = $svcOn -or $odOn
  $since = 0
  foreach ($x in @($(if ($svcOn) { $st.since }), $(if ($odOn) { $od.since }))) { if ($x -and ($since -eq 0 -or [long]$x -lt $since)) { $since = [long]$x } }
  $upd = @($ServiceNames | Where-Object { $_ -ne 'WSearch' }); $srch = @($ServiceNames | Where-Object { $_ -eq 'WSearch' })
  $u = Item-State $upd; $s = Item-State $srch
  $o = if (Od-Running) { 'running' } else { 'paused' }
  if ($on -and $u -eq 'running') { Note 'Windows Update is running again while Quiet PC is on (Windows restarted it)' }
  $say = if (-not $setupOk) { "Quiet PC $([char]0xB7) not set up" }
         elseif ($on) { "Quiet PC on since " + ([DateTime]'1970-01-01').AddMilliseconds($since).ToLocalTime().ToString('HH:mm') + " $([char]0xB7) " + (Paused-Words $(if ($svcOn) { $st.services } else { @() }) $odOn) }
         else { "Quiet PC off $([char]0xB7) everything handed back" }
  '{"setup":' + $(if ($setupOk) { 'true' } else { 'false' }) + ',"on":' + $(if ($on) { 'true' } else { 'false' }) + ',"since":' + $since + ',"say":' + (JStr $say) +
  ',"items":[{"id":"update","name":"Windows Update","state":"' + $u + '"},{"id":"search","name":"Search indexing","state":"' + $s +
  '"},{"id":"onedrive","name":"OneDrive","state":"' + $o + '"},{"id":"simprio","name":"Sim priority","state":"' + (Sim-Prio) + '"}]}'
}

# ---- setup and undo (Peter's one click) ----
function Me { if ($ForUser) { $ForUser } else { [Security.Principal.WindowsIdentity]::GetCurrent().Name } }
function Restart-AsAdmin($what) {
  if ($isAdmin -or $Preview -or $m) { return }
  Note 'Windows will ask for permission once (administrator) in a new window.'
  Write-Log ($what.TrimStart('-').ToLower() + ', before administrator')
  Start-Process powershell -Verb RunAs -Wait -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" ' + $what + ' -ForUser "' + (Me) + '"')
  exit 0
}
function Task-Args($sw) { '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $PSScriptRoot 'quiet-pc.ps1') + '" ' + $sw }
function Do-Setup {
  Restart-AsAdmin '-Setup'
  $user = Me
  Note ("Quiet PC setup for {0}: two tasks, highest privileges, no trigger (irdash starts them at session start and end)" -f $user)
  foreach ($t in @(@($TaskOn, '-On'), @($TaskOff, '-Off'))) { Note ("  {0}: powershell.exe {1}" -f $t[0], (Task-Args $t[1])) }
  if ($Preview -or $m) { return }
  $logon = 'S4U'
  foreach ($t in @(@($TaskOn, '-On'), @($TaskOff, '-Off'))) {
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (Task-Args $t[1])
    try {
      # S4U: runs as Peter but out of sight (no window can ever appear on his screens); no password is stored
      $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Highest
      Register-ScheduledTask -TaskName $t[0] -Action $act -Principal $pr -Settings $set -Description 'Paddock: pauses Windows Update and search indexing while a session is on (quiet-pc-setup-UNDO.cmd removes it)' -Force | Out-Null
    } catch {
      # fallback: in his own session, the window hidden by the small launcher (wscript shows nothing)
      $logon = 'Interactive'
      $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B //Nologo "' + (Join-Path $PSScriptRoot 'quiet-pc-hidden.vbs') + '" ' + $t[1])
      $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
      Register-ScheduledTask -TaskName $t[0] -Action $act -Principal $pr -Settings $set -Description 'Paddock: pauses Windows Update and search indexing while a session is on (quiet-pc-setup-UNDO.cmd removes it)' -Force | Out-Null
    }
    Note ("  registered {0} ({1})" -f $t[0], $logon)
  }
  Put $setupFile ('{"at":' + (JStr (Get-Date -Format s)) + ',"user":' + (JStr $user) + ',"logon":"' + $logon + '","tasks":' + (JArr @($TaskOn, $TaskOff)) + '}')
  Note 'Done. From now on it happens by itself. To go back: quiet-pc-setup-UNDO.cmd'
}
function Do-Undo {
  if (-not $isAdmin) { OneDrive-Off; if (-not $Preview -and -not $m) { Remove-Item -LiteralPath $odFile -Force -ErrorAction SilentlyContinue } }
  Restart-AsAdmin '-Undo'
  Note 'Quiet PC undo: services handed back, both tasks and the setup removed'
  Services-Off
  foreach ($t in @($TaskOn, $TaskOff)) {
    if ($Preview -or $m) { Note ("  would delete task {0}" -f $t); continue }
    try { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop; Note ("  deleted task {0}" -f $t) } catch { Note ("  task {0}: not there" -f $t) }
  }
  if (-not $Preview -and -not $m) { foreach ($f in @($setupFile, $stateFile)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
}


if ($Setup) { Do-Setup }
elseif ($Undo) { Do-Undo }
elseif ($Status) { $j = Status-Json; $j | Select-Object -Last 1; Write-Log 'status'; exit 0 }
elseif ($On -or $Off -or $Preview) {
  $verb = if ($Off) { 'off' } else { 'on' }
  if ($Preview) { Note ("Preview of Quiet PC {0} (changes nothing): services {1}, then OneDrive ({2})" -f $verb, ($ServiceNames -join ', '), $OneDrivePath) }
  # the services half where there is administrator (or in a preview), the OneDrive half where there is not (or in a preview)
  if ($isAdmin -or $Preview) { if ($Off) { Services-Off } else { Services-On } } else { Note 'services: left to the setup task (needs administrator)' }
  if (-not $isAdmin -or $Preview) { if ($Off) { OneDrive-Off } else { OneDrive-On } } else { Note 'OneDrive: left to irdash (OneDrive refuses administrator rights)' }
}
else { 'quiet-pc.ps1 -Setup | -Undo | -On | -Off | -Status | -Preview'; exit 1 }
Write-Log $(if ($Setup) { 'setup' } elseif ($Undo) { 'undo' } elseif ($Off) { 'off' } else { 'on' })
