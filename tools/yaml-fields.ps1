# P0-08: prove the exact session-YAML field names for iRating / licence / results (the fact list W-14/W-15 consume).
#
# iRacing's own .ibt files are only ever READ. Five OLD ones (nothing written in the last 2 minutes, so never the
# live session) are copied to a scratch folder (%TEMP%\paddock-yaml-fields) first and the COPIES are read, at
# BelowNormal priority, <= 2 cores.
#
# Method (same as dash\src\irdash.cs OpenIbt / ReadYaml): the .ibt header is 144 bytes; int32 at offset 16 is the
# session-info length and int32 at offset 20 its offset; that block is the session YAML text (NUL-terminated, read
# as code page 28591). No C# change, no iRacing file written.
#
#   powershell -ExecutionPolicy Bypass -File tools\yaml-fields.ps1            (a real official session first, AI ones fill up to five)
#   powershell -ExecutionPolicy Bypass -File tools\yaml-fields.ps1 -Count 5 -Scratch <dir>
param([int]$Count = 5, [string]$Scratch = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\guard.ps1')
Assert-RigFree

$me = Get-Process -Id $PID
$me.PriorityClass = 'BelowNormal'
$cores = [Environment]::ProcessorCount
if ($cores -gt 2) {
  $mask = [int64]0
  for ($i = 0; $i -lt 2; $i++) { $mask = $mask -bor ([int64]1 -shl ($cores - 1 - $i)) }
  $me.ProcessorAffinity = [IntPtr]$mask
}

$srcDir = Join-Path $env:USERPROFILE 'OneDrive\Documents\iRacing\telemetry'
if (-not (Test-Path -LiteralPath $srcDir)) { $srcDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry' }
if (-not (Test-Path -LiteralPath $srcDir)) { Write-Host "telemetry folder not found: $srcDir"; exit 2 }
if (-not $Scratch) { $Scratch = Join-Path $env:TEMP 'paddock-yaml-fields' }
New-Item -ItemType Directory -Force $Scratch | Out-Null

# The session YAML block from an .ibt (original or copy): header[16]=length, header[20]=offset (dash\src\irdash.cs OpenIbt).
function Read-SessionYaml([string]$path) {
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite,Delete')
  try {
    $h = New-Object byte[] 144
    $got = 0
    while ($got -lt 144) { $n = $fs.Read($h, $got, 144 - $got); if ($n -le 0) { break }; $got += $n }
    if ($got -lt 144) { return $null }
    $len = [BitConverter]::ToInt32($h, 16); $off = [BitConverter]::ToInt32($h, 20)
    if ($len -le 0 -or $len -gt 4000000 -or $off -le 0) { return $null }
    $b = New-Object byte[] $len
    [void]$fs.Seek($off, 'Begin')
    $read = 0
    while ($read -lt $len) { $n = $fs.Read($b, $read, $len - $read); if ($n -le 0) { break }; $read += $n }
    $z = [Array]::IndexOf($b, [byte]0); if ($z -lt 0) { $z = $len }
    return [Text.Encoding]::GetEncoding(28591).GetString($b, 0, $z)
  } finally { $fs.Close() }
}

function Get-YamlValue([string]$yaml, [string]$key) {
  $m = [regex]::Match($yaml, '(?m)^[ \t]*' + [regex]::Escape($key) + ':[ \t]*(.*?)[ \t\r]*$')
  if ($m.Success) { return $m.Groups[1].Value.Trim('"') }
  return ''
}

# The DriverInfo.Drivers[<idx>] block: its fields are 3-space indented, the next "- CarIdx:" marker is not (bench.cs uses this shape).
function Get-DriverFields([string]$yaml, [int]$idx) {
  $order = New-Object System.Collections.ArrayList
  $val = New-Object 'System.Collections.Specialized.OrderedDictionary'
  foreach ($m in [regex]::Matches($yaml, '- CarIdx: (\d+)[ \t]*\r?\n((?:   [^\r\n]*\r?\n?)*)')) {
    if ([int]$m.Groups[1].Value -ne $idx) { continue }
    foreach ($ln in ($m.Groups[2].Value -split "\r?\n")) {
      if ($ln.Trim().Length -eq 0) { continue }
      $c = $ln.IndexOf(':'); if ($c -lt 0) { continue }
      $k = $ln.Substring(0, $c).Trim(); $v = $ln.Substring($c + 1).Trim().Trim('"')
      if ($k -and -not $val.Contains($k)) { [void]$order.Add($k); $val[$k] = $v }
    }
    break
  }
  return @{ Order = $order; Val = $val }
}

# The ResultsPositions block (SessionInfo.Sessions[]): find the one whose next line is a "- Position:" row, then read the rows.
function Get-ResultsBlock([string]$yaml) {
  $lines = $yaml -split "\r?\n"
  $start = -1; $indent = 0
  for ($i = 0; $i -lt $lines.Count - 1; $i++) {
    if ($lines[$i] -match '^([ \t]*)ResultsPositions:[ \t]*$') {
      $keyIndent = $Matches[1].Length
      if ($lines[$i + 1] -match '^[ \t]*- Position:') { $start = $i + 1; $indent = $keyIndent; break }
    }
  }
  if ($start -lt 0) { return $null }
  $rows = New-Object System.Collections.ArrayList
  $cur = $null
  for ($i = $start; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln.Trim().Length -eq 0) { continue }
    $ind = ([regex]::Match($ln, '^([ \t]*)')).Groups[1].Length
    $isItem = $ln -match '^[ \t]*-[ \t]'
    if ($ind -le $indent) {
      if ($isItem) {
        if ($cur) { [void]$rows.Add($cur) }
        $cur = New-Object 'System.Collections.Specialized.OrderedDictionary'
        Add-YamlPair $cur ($ln -replace '^[ \t]*-[ \t]*', '')
      } else { break }
    } elseif ($cur) {
      Add-YamlPair $cur $ln
    }
  }
  if ($cur) { [void]$rows.Add($cur) }
  if ($rows.Count -eq 0) { return $null }
  return $rows
}

function Add-YamlPair($h, [string]$line) {
  $c = $line.IndexOf(':'); if ($c -lt 0) { return }
  $k = $line.Substring(0, $c).Trim(); $v = $line.Substring($c + 1).Trim().Trim('"')
  if ($k) { $h[$k] = $v }
}

function Has-ResultRow([string]$yaml) {
  return ($yaml -match '(?m)^[ \t]*ResultsPositions:[ \t]*\r?\n[ \t]*- Position:')
}

$out = New-Object System.Collections.ArrayList
function Say([string]$s) { [void]$out.Add($s); Write-Host $s }

Say "P0-08 session YAML field names  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
Say "telemetry: $srcDir"
Say "method: dash\src\irdash.cs OpenIbt/ReadYaml - header[16]=info length, header[20]=info offset, Latin-1 (28591), NUL-terminated"
Say ""

$cut = (Get-Date).AddMinutes(-2)
$cands = @(Get-ChildItem -LiteralPath $srcDir -Filter '*.ibt' -ErrorAction SilentlyContinue |
           Where-Object { $_.LastWriteTime -lt $cut } | Sort-Object LastWriteTime -Descending)

# Peek the player's IRating to tell a real official session (IRating > 1) from an AI/offline one (the placeholder "IRating: 1").
function Get-PlayerIRating([string]$yaml) {
  $idx = 0; [void][int]::TryParse((Get-YamlValue $yaml 'DriverCarIdx'), [ref]$idx)
  $ir = 0; [void][int]::TryParse((Get-DriverFields $yaml $idx).Val['IRating'], [ref]$ir)
  return $ir
}

$real = New-Object System.Collections.ArrayList
$dummy = New-Object System.Collections.ArrayList
foreach ($f in $cands) {
  if ($real.Count -ge $Count) { break }
  $peek = Read-SessionYaml $f.FullName
  if (-not $peek) { continue }
  if ($peek -notmatch '(?m)^[ \t]*IRating:') { continue }
  if (-not (Has-ResultRow $peek)) { continue }
  $rec = [pscustomobject]@{ Name = $f.Name; Src = $f; Real = ((Get-PlayerIRating $peek) -gt 1) }
  if ($rec.Real) { [void]$real.Add($rec) } else { [void]$dummy.Add($rec) }
}
# real official sessions first (that is where iRating / licences are meaningful), AI placeholders fill the rest up to Count.
$chosen = New-Object System.Collections.ArrayList
foreach ($rec in @($real) + @($dummy)) {
  if ($chosen.Count -ge $Count) { break }
  $copy = Join-Path $Scratch $rec.Name
  Copy-Item -LiteralPath $rec.Src.FullName -Destination $copy -Force
  [void]$chosen.Add([pscustomobject]@{ Name = $rec.Name; Copy = $copy; Src = $rec.Src; Real = $rec.Real })
}

if ($chosen.Count -lt $Count) { Say "need $Count old .ibt with iRating + a results block, found $($chosen.Count)"; exit 3 }

$n = 0
$nReal = 0
foreach ($c in $chosen) {
  $n++
  if ($c.Real) { $nReal++ }
  $yaml = Read-SessionYaml $c.Copy
  $fi = Get-Item -LiteralPath $c.Copy
  $track = Get-YamlValue $yaml 'TrackDisplayName'
  $cfg = Get-YamlValue $yaml 'TrackConfigName'
  $car = Get-YamlValue $yaml 'CarScreenName'
  if (-not $car) { $car = Get-YamlValue $yaml 'CarPath' }
  $idx = 0; [void][int]::TryParse((Get-YamlValue $yaml 'DriverCarIdx'), [ref]$idx)
  $sessType = Get-YamlValue $yaml 'EventType'
  $kind = if ($c.Real) { 'official (real iRating)' } else { 'AI/offline (placeholder iRating 1)' }

  Say ("=== {0}/{1}: {2}  ({3:N1} MB, {4})  [{5}] ===" -f $n, $Count, $c.Name, ($fi.Length / 1MB), $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $kind)
  Say ("  Track: {0}{1}   Car: {2}   Type: {3}" -f $track, $(if ($cfg) { ' - ' + $cfg } else { '' }), $car, $sessType)
  Say ("  PlayerCarIdx (DriverCarIdx): {0}" -f $idx)

  $drv = Get-DriverFields $yaml $idx
  if ($drv.Order.Count -eq 0) { Say "  DriverInfo.Drivers[$idx] NOT FOUND"; $script:bad = $true }
  else {
    Say ("  DriverInfo.Drivers[] field names: " + ($drv.Order -join ', '))
    foreach ($k in @('IRating', 'LicString', 'LicLevel', 'LicSubLevel', 'LicColor')) {
      if ($drv.Val.Contains($k)) { Say ("    {0,-11} = {1}" -f $k, $drv.Val[$k]) }
      else { Say ("    {0,-11} = (missing)" -f $k); $script:bad = $true }
    }
  }

  $res = Get-ResultsBlock $yaml
  if (-not $res) { Say "  Results block NOT FOUND"; $script:bad = $true }
  else {
    $names = @($res[0].Keys)
    Say ("  Results block field names: " + ($names -join ', '))
    $row = foreach ($k in $names) { "$k=$($res[0][$k])" }
    Say ("  Results row 1: " + ($row -join '  '))
  }
  Say ""
}

Say ("CHECK: {0} files ({1} official, {2} AI/offline), 5 iRating/licence fields + results fields, method = OpenIbt header[16]/header[20]" -f $chosen.Count, $nReal, ($chosen.Count - $nReal))
# Save the transcript next to the other test logs so the lead can read it.
$log = Join-Path $root 'tests\last\yaml-fields.txt'
New-Item -ItemType Directory -Force (Split-Path -Parent $log) | Out-Null
[IO.File]::WriteAllLines($log, $out, (New-Object Text.UTF8Encoding($false)))
Say "transcript: $log"
Say "copies: $Scratch"

if ($script:bad) { Write-Host "FAIL: one or more requested names were missing"; exit 1 }
Write-Host "PASS"
exit 0
