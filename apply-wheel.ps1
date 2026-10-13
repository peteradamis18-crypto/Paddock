# Writes the wheel buttons recorded by irlearn.exe (learn.txt) into iRacing's "Baseline" controls profile.
#   powershell -ExecutionPolicy Bypass -File apply-wheel.ps1 -DryRun   (show the plan, change nothing)
#   powershell -ExecutionPolicy Bypass -File apply-wheel.ps1           (backup, write, verify)
# Every control record in controls.cfg is a fixed 68 bytes after its name:
#   +8 type (0 none, 2 joystick button, 4 key) | +12.. button bit mask | +36 device instance GUID | +52 device product GUID
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$f = "$env:USERPROFILE\OneDrive\Documents\iRacing\profiles\controls\Baseline\controls.cfg"
if (-not $DryRun -and (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue)) { throw "Close the iRacing sim first - it rewrites this file when it exits." }

$learn = [ordered]@{}
foreach ($l in Get-Content (Join-Path $here 'learn.txt')) { $k, $v = $l.Split('=', 2); if ($k -and $v -and $k -notlike '*#check') { $learn[$k] = [int]$v } }
$b = [IO.File]::ReadAllBytes($f); $s = [Text.Encoding]::GetEncoding(28591).GetString($b)

function Off($n) {
  $m = [regex]::Match($s, '(?<=\x00|PIDVID)' + [regex]::Escape($n) + '\x00')
  if (-not $m.Success) { return -1 }
  $o = $m.Index + $m.Length
  if ([BitConverter]::ToInt32($b, $o + 4) -notin 6, 0x19, 0x1F) { return -1 }
  return $o
}
function MaskBit($o) { for ($w = 0; $w -lt 4; $w++) { $v = [BitConverter]::ToUInt32($b, $o + 12 + 4 * $w); for ($i = 0; $i -lt 32; $i++) { if ($v -band ([uint32]1 -shl $i)) { return $w * 32 + $i } } }; return -1 }

# HID usage -> iRacing button bit, calibrated on the shift paddles (already bound and working)
$offset = 1
$sd = Off 'ShiftDown'
if ($learn.Contains('ShiftDown') -and $sd -ge 0 -and (MaskBit $sd) -ge 0) { $offset = $learn['ShiftDown'] - (MaskBit $sd) }
$su = Off 'ShiftUp'
if ($learn.Contains('ShiftUp') -and $su -ge 0 -and ($learn['ShiftUp'] - $offset) -ne (MaskBit $su)) { throw "Shift paddles don't agree on the numbering - stopping without changes." }
"button numbering offset: $offset"

# the SC-Link Hub's device IDs, copied from a binding that already works
$pit = Off 'PitSpeedLimiter'
$guid = $b[($pit + 36)..($pit + 67)]
if ([Text.Encoding]::ASCII.GetString($b, $pit + 62, 6) -ne 'PIDVID' -or $b[$pit + 52] -ne 0xD0 -or $b[$pit + 53] -ne 0x16) { throw "PitSpeedLimiter isn't bound to the SC-Link Hub - stopping." }
function IsHub($o) { for ($i = 0; $i -lt 32; $i++) { if ($b[$o + 36 + $i] -ne $guid[$i]) { return $false } }; return $true }
function Clear($o) { [BitConverter]::GetBytes([int]0).CopyTo($b, $o + 8); for ($i = 12; $i -lt 68; $i++) { $b[$o + $i] = 0 } }

$plan = @(); $taken = @{}
foreach ($k in $learn.Keys) {
  if ($k -in 'ShiftDown', 'ShiftUp') { continue }
  $bit = $learn[$k] - $offset
  $o = Off $k
  if ($o -lt 0 -or $bit -lt 0 -or $bit -gt 127) { $plan += "SKIP  $k (record not found or button $($learn[$k]) out of range)"; continue }
  $taken[$bit] = $k
  $plan += "BIND  {0,-24} -> wheel button {1} (bit {2}){3}" -f $k, $learn[$k], $bit, $(if ($bit -ge 32) { '   <- above 32: verify in the sim' } else { '' })
}
# free up old wheel bindings that would collide or aren't wanted on triple screens
$ms = [regex]::Matches($s, '(?<=\x00|PIDVID)(?!PIDVID)([A-Z][A-Za-z0-9_]{2,40})\x00')
$clear = @()
foreach ($m in $ms) {
  $n = $m.Groups[1].Value; $o = $m.Index + $m.Length
  if ($o + 68 -gt $b.Length -or $learn.Contains($n) -or $n -in 'ShiftDown', 'ShiftUp') { continue }
  if ([BitConverter]::ToInt32($b, $o + 8) -ne 2 -or -not (IsHub $o)) { continue }
  $bit = MaskBit $o
  if ($n -like 'Look*' -or $taken.ContainsKey($bit)) { $clear += $o; $plan += "CLEAR {0,-24} (was wheel bit {1})" -f $n, $bit }
}
$plan
if ($DryRun) { "dry run - nothing written"; return }

Copy-Item -LiteralPath $f -Destination "$f.bak-wheel-$(Get-Date -f yyyyMMdd-HHmm)"
foreach ($o in $clear) { Clear $o }
foreach ($k in $learn.Keys) {
  if ($k -in 'ShiftDown', 'ShiftUp') { continue }
  $bit = $learn[$k] - $offset; $o = Off $k
  if ($o -lt 0 -or $bit -lt 0 -or $bit -gt 127) { continue }
  Clear $o
  [BitConverter]::GetBytes([int]2).CopyTo($b, $o + 8)
  [BitConverter]::GetBytes([uint32]1 -shl ($bit % 32)).CopyTo($b, $o + 12 + 4 * [Math]::Floor($bit / 32))
  for ($i = 0; $i -lt 32; $i++) { $b[$o + 36 + $i] = $guid[$i] }
}
$len = $b.Length
[IO.File]::WriteAllBytes($f, $b)
# verify from disk
$b = [IO.File]::ReadAllBytes($f); $s = [Text.Encoding]::GetEncoding(28591).GetString($b)
$bad = 0
foreach ($k in $learn.Keys) {
  if ($k -in 'ShiftDown', 'ShiftUp') { continue }
  $o = Off $k; if ($o -lt 0) { continue }
  $want = $learn[$k] - $offset
  if ([BitConverter]::ToInt32($b, $o + 8) -ne 2 -or (MaskBit $o) -ne $want -or -not (IsHub $o)) { "MISMATCH $k"; $bad++ }
}
"written and verified: $($learn.Count) learned, $bad mismatches, size unchanged: $($b.Length -eq $len)"
