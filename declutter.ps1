# Uninstalls apps this rig does not use (checked 2026-10-09: no Fanatec, SteelSeries or NZXT hardware
# is plugged in; the wheel is a Simucube; SimHub is not used). Asks once, then runs each app's own
# uninstaller silently. Log: backup\declutter.log. Asks for administrator approval once.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Start-Process powershell -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"')
  exit 0
}
Add-Type -AssemblyName System.Windows.Forms
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Start-Transcript -Path (Join-Path $root 'backup\declutter.log') -Append | Out-Null
if (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue) {
  [System.Windows.Forms.MessageBox]::Show('Close the iRacing race first, then run this again.', 'Remove unused apps') | Out-Null; Stop-Transcript | Out-Null; exit 1 }

# runs a command line like  "C:\x\y.exe" /a /b  (exe in quotes, then arguments) and waits
function RunLine([string]$line, [string]$extra) {
  if ($line -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $args0 = $Matches[2] }
  elseif (Test-Path -LiteralPath $line.Trim()) { $exe = $line.Trim(); $args0 = '' }   # unquoted path with spaces
  else { $exe, $args0 = $line -split '\s+', 2 }
  Start-Process -FilePath $exe -ArgumentList ((($args0, $extra) | Where-Object { $_ }) -join ' ') -Wait -PassThru
}
# name shown, uninstall-entry match, processes to close first, silent uninstall command
$apps = @(
  @{ Name = 'SimHub';                 Match = '^SimHub';                Procs = 'SimHubWPF';                          Cmd = { param($e) RunLine $e.UninstallString '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' } },
  @{ Name = 'Fanatec App';            Match = '^FanatecApp$';           Procs = 'FanatecApp','FanatecService';        Cmd = { param($e) RunLine $e.QuietUninstallString '/norestart' } },
  @{ Name = 'FanaLab';                Match = '^FanaLab$';              Procs = 'FanaLab';                            Cmd = { param($e) Start-Process 'msiexec.exe' ('/x ' + ($e.UninstallString -replace '^.*(\{[0-9A-F-]+\}).*$', '$1') + ' /qn /norestart') -Wait -PassThru } },
  @{ Name = 'Fanatec wheel driver';   Match = '^FANATEC driver package'; Procs = 'FWPnpService';                      Cmd = { param($e) Start-Process 'msiexec.exe' ('/x ' + ($e.UninstallString -replace '^.*(\{[0-9A-F-]+\}).*$', '$1') + ' /qn /norestart') -Wait -PassThru } },
  @{ Name = 'SteelSeries GG';         Match = '^SteelSeries GG';        Procs = 'SteelSeriesGG','SteelSeriesGGClient','SteelSeriesEngine'; Cmd = { param($e) RunLine $e.UninstallString '/S' } },
  @{ Name = 'NZXT CAM';               Match = '^NZXT CAM';              Procs = 'NZXT CAM';                           Cmd = { param($e) RunLine $e.QuietUninstallString '' } }
)
$entries = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
$todo = @(foreach ($a in $apps) { $e = $entries | Where-Object { $_.DisplayName -match $a.Match } | Select-Object -First 1; if ($e) { $a.Entry = $e; $a } })
if ($todo.Count -eq 0) { 'Nothing left to remove.'; [System.Windows.Forms.MessageBox]::Show('Nothing left to remove - already done.', 'Remove unused apps') | Out-Null; Stop-Transcript | Out-Null; exit 0 }

$list = ($todo | ForEach-Object { '  - ' + $_.Name }) -join "`n"
$msg = "This removes apps your rig doesn't use:`n`n$list`n`nNone of their hardware is plugged in. Your Simucube, Stream Deck, iRacing, CrewChief and overlays are not touched.`n`nTakes a few minutes. Click OK to start."
if ([System.Windows.Forms.MessageBox]::Show($msg, 'Remove unused apps', 'OKCancel', 'Question') -ne 'OK') { 'Cancelled.'; Stop-Transcript | Out-Null; exit 0 }

$results = @()
foreach ($a in $todo) {
  foreach ($p in $a.Procs) { Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
  "removing $($a.Name): $($a.Entry.UninstallString)"
  try { $proc = & $a.Cmd $a.Entry; $code = if ($proc) { $proc.ExitCode } else { '?' } } catch { $code = 'error: ' + $_.Exception.Message }
  $still = [bool](Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $a.Match })
  $line = '{0}: {1} (exit {2})' -f $a.Name, $(if ($still) { 'STILL INSTALLED' } else { 'removed' }), $code
  $line; $results += $line
}
Stop-Transcript | Out-Null
[System.Windows.Forms.MessageBox]::Show(($results -join "`n") + "`n`nRestart the PC when convenient to finish.", 'Remove unused apps') | Out-Null
