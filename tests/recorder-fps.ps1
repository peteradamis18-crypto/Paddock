# Frame-rate cost of Paddock's video recorder (C-06): two Test Drives sitting in the pit box, recorder OFF then ON,
# read from iRacing's own FrameRate / GpuUsage / CpuUsageFG. Starts the real sim, so it only runs when nobody has used
# the PC for 10 minutes. Puts recorder= in dash\irdash.ini back as it found it (unless -LeaveOn) and restarts irdash.
#   powershell -ExecutionPolicy Bypass -File tests\recorder-fps.ps1 [-Secs 90] [-LeaveOn]
# Note: alone in the pit box the sim may sit at the 160 fps cap in both runs; then GPU use is the cost to read.
param([int]$Secs = 90, [switch]$LeaveOn)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree -NeedAway
$cli = Join-Path $root 'irdeck-cli.exe'; $ini = Join-Path $root 'dash\irdash.ini'; $dash = Join-Path $root 'dash\irdash.exe'
function Ir { $o = & $cli @args 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join "`n") } }
function SimOn { [bool](Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue) }
if (SimOn) { 'The sim is running - nothing done.'; exit 3 }
$env:RIG_TEST_OWNS_SIM = '1'   # our own Test Drive start must not stop the second run

# iRacing shared memory: newest buffer's value of a float variable
function ReadVars([string[]]$names) {
  $res = @{}
  try { $mm = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting('Local\IRSDKMemMapFileName') } catch { return $res }
  $a = $mm.CreateViewAccessor(0, 0, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
  try {
    $numVars = $a.ReadInt32(24); $varHdr = $a.ReadInt32(28); $numBuf = $a.ReadInt32(32)
    $best = -1; $off = 0
    for ($b = 0; $b -lt $numBuf; $b++) { $tc = $a.ReadInt32(48 + $b * 16); if ($tc -gt $best) { $best = $tc; $off = $a.ReadInt32(52 + $b * 16) } }
    $bytes = New-Object byte[] 32
    for ($i = 0; $i -lt $numVars; $i++) {
      $h = $varHdr + $i * 144; [void]$a.ReadArray($h + 16, $bytes, 0, 32)
      $n = [Text.Encoding]::ASCII.GetString($bytes); $z = $n.IndexOf([char]0); if ($z -ge 0) { $n = $n.Substring(0, $z) }
      if ($names -contains $n) { $res[$n] = [double]$a.ReadSingle($off + $a.ReadInt32($h + 4)) }
    }
  } finally { $a.Dispose(); $mm.Dispose() }
  return $res
}
function SetRecorder($v) {
  $t = [IO.File]::ReadAllText($ini)
  $t = [regex]::Replace($t, '(?m)^recorder=.*$', "recorder=$v")
  [IO.File]::WriteAllText($ini, $t, (New-Object Text.UTF8Encoding $false))
}
function RestartDash {
  Get-Process irdash -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 2
  Start-Process explorer.exe -ArgumentList "`"$dash`""   # outside this app's sandbox, as build.ps1 does
  for ($i = 0; $i -lt 30; $i++) { try { Invoke-WebRequest http://localhost:8199/vault/recorder -UseBasicParsing -TimeoutSec 2 | Out-Null; return } catch { Start-Sleep 1 } }
}
function Pct($v, $p) { $s = @($v | Sort-Object); if ($s.Count -eq 0) { return 0 }; $s[[math]::Min($s.Count - 1, [math]::Floor($s.Count * $p))] }

function Phase($label) {
  if ((Get-RigBusy) -and -not (SimOn)) { throw "NOT SAFE: $(Get-RigBusy)" }
  Write-Host "$label : starting a Test Drive"
  $r = Ir startlast td
  if ($r.rc -ne 0) { Write-Host "  Test Drive did not start (rc $($r.rc)): $($r.out)"; return $null }
  Start-Sleep 15
  $fps = New-Object Collections.Generic.List[double]; $gpu = New-Object Collections.Generic.List[double]; $cpu = New-Object Collections.Generic.List[double]
  $ff0 = (Get-Process ffmpeg -ErrorAction SilentlyContinue | Measure-Object CPU -Sum).Sum
  $end = (Get-Date).AddSeconds($Secs)
  while ((Get-Date) -lt $end) {
    $v = ReadVars @('FrameRate', 'GpuUsage', 'CpuUsageFG', 'IsOnTrack')
    if ($v['IsOnTrack'] -gt 0 -and $v['FrameRate'] -gt 0) { $fps.Add($v['FrameRate']); $gpu.Add($v['GpuUsage'] * 100); $cpu.Add($v['CpuUsageFG'] * 100) }
    Start-Sleep -Milliseconds 500
  }
  $ff1 = (Get-Process ffmpeg -ErrorAction SilentlyContinue | Measure-Object CPU -Sum).Sum
  $rec = try { (Invoke-WebRequest http://localhost:8199/vault/recorder -UseBasicParsing -TimeoutSec 5).Content } catch { '(no reply)' }
  [void](Ir quitmain)
  for ($i = 0; $i -lt 90 -and (SimOn); $i++) { Start-Sleep 1 }
  $o = [pscustomobject]@{
    label = $label; n = $fps.Count
    avg = [math]::Round(($fps | Measure-Object -Average).Average, 1); low1 = [math]::Round((Pct $fps 0.01), 1)
    gpu = [math]::Round(($gpu | Measure-Object -Average).Average, 1); cpu = [math]::Round(($cpu | Measure-Object -Average).Average, 1)
    ffmpegCpuPctOfCore = if ($ff0 -ne $null -and $ff1 -ne $null) { [math]::Round(($ff1 - $ff0) / $Secs * 100, 1) } else { 0 }
    recorder = $rec
  }
  Write-Host "  samples $($o.n)  fps avg $($o.avg)  lowest 1 % $($o.low1)  GPU $($o.gpu) %  CPU(main thread) $($o.cpu) %  ffmpeg $($o.ffmpegCpuPctOfCore) % of a core"
  Write-Host "  recorder: $rec"
  return $o
}

$was = if ([IO.File]::ReadAllText($ini) -match '(?m)^recorder=(.*)$') { $Matches[1].Trim() } else { '0' }
"Recorder frame-rate check $(Get-Date -Format 'yyyy-MM-dd HH:mm') (recorder= was $was)"
try {
  SetRecorder 0; RestartDash
  $a = Phase 'A recorder OFF'
  SetRecorder 1; RestartDash
  $b = Phase 'B recorder ON'
} finally {
  if (SimOn) { [void](Ir quitmain) }
  if (-not $LeaveOn) { SetRecorder $was } ; RestartDash
}
if ($a -and $b) {
  "RESULT  fps avg $($a.avg) -> $($b.avg) ($([math]::Round($b.avg - $a.avg, 1)))  lowest 1 % $($a.low1) -> $($b.low1)  GPU $($a.gpu) -> $($b.gpu) %"
}
