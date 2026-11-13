# ibt-cut.ps1 - copy part of an .ibt telemetry file into a smaller, valid .ibt (test fixtures, W0-8).
# Keeps the header, the variable list and the session YAML exactly, copies the chosen records and patches the
# record count (header offset 140). The source is only read, never written.
#   -From/-To       seconds from the start of the file (records at the file's own tick rate)
#   -AroundLap n    instead: -Seconds s (default 60) centred on the moment the lap counter first becomes n
param(
  [Parameter(Mandatory)][string]$Source,
  [Parameter(Mandatory)][string]$Out,
  [double]$From = 0, [double]$To = 180,
  [int]$AroundLap = 0, [double]$Seconds = 60
)
$ErrorActionPreference = 'Stop'
$in = [IO.File]::Open($Source, 'Open', 'Read', 'ReadWrite, Delete')
try {
  $h = New-Object byte[] 144; [void]$in.Read($h, 0, 144)
  $tick = [BitConverter]::ToInt32($h, 8); $nVars = [BitConverter]::ToInt32($h, 24); $varOff = [BitConverter]::ToInt32($h, 28)
  $bufLen = [BitConverter]::ToInt32($h, 36); $dataOff = [BitConverter]::ToInt32($h, 52)
  $records = [long](($in.Length - $dataOff) / $bufLen)
  if ($AroundLap -gt 0) {
    $vh = New-Object byte[] ($nVars * 144); $in.Position = $varOff; [void]$in.Read($vh, 0, $vh.Length)
    $lapOff = -1
    for ($i = 0; $i -lt $nVars; $i++) {
      $b = $i * 144; $e = [Array]::IndexOf($vh, [byte]0, $b + 16); $name = [Text.Encoding]::ASCII.GetString($vh, $b + 16, $e - $b - 16)
      if ($name -eq 'Lap') { $lapOff = [BitConverter]::ToInt32($vh, $b + 4); break }
    }
    if ($lapOff -lt 0) { throw 'no Lap channel in the file' }
    $first = -1; $rec = New-Object byte[] $bufLen
    $in.Position = $dataOff
    for ($r = 0L; $r -lt $records; $r++) {
      [void]$in.Read($rec, 0, $bufLen)
      if ([BitConverter]::ToInt32($rec, $lapOff) -eq $AroundLap) { $first = $r; break }
    }
    if ($first -lt 0) { throw "lap $AroundLap never starts in this file" }
    $From = [Math]::Max(0, $first / $tick - $Seconds / 2); $To = $From + $Seconds
  }
  $r0 = [long][Math]::Min($records, [Math]::Floor($From * $tick))
  $r1 = [long][Math]::Min($records, [Math]::Ceiling($To * $tick))
  $n = $r1 - $r0
  if ($n -le 0) { throw 'nothing to copy' }
  [Array]::Copy([BitConverter]::GetBytes([int]$n), 0, $h, 140, 4)
  $head = New-Object byte[] $dataOff; $in.Position = 0; [void]$in.Read($head, 0, $dataOff)
  [Array]::Copy($h, 0, $head, 0, 144)
  New-Item -ItemType Directory -Force (Split-Path -Parent $Out) | Out-Null
  $o = [IO.File]::Create($Out)
  try {
    $o.Write($head, 0, $head.Length)
    $in.Position = $dataOff + $r0 * $bufLen
    $buf = New-Object byte[] ($bufLen * 500); $left = $n
    while ($left -gt 0) {
      $want = [int][Math]::Min($left, 500) * $bufLen
      $got = $in.Read($buf, 0, $want); if ($got -le 0) { break }
      $o.Write($buf, 0, $got); $left -= [long]($got / $bufLen)
    }
  } finally { $o.Dispose() }
  "cut $Out : $n records ($([Math]::Round($n / $tick, 1)) s) from record $r0, $((Get-Item $Out).Length) bytes"
} finally { $in.Dispose() }
