# Kids mode (K-01): one deck key locks the keyboard and mouse, and every other deck key does nothing.
# The hook is real, so this script refuses while the sim is running (tests\guard.ps1) and every lock
# expires on its own within a few seconds if the script is cut off. It does not start the sim, deploy,
# or touch Stream Deck. The wheel is not hooked; that is checked in the source.
#   powershell -ExecutionPolicy Bypass -File tests\kids-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
Enter-TestLock 'kids-test' 0
# every hook this test starts ends by itself within 30 s, whatever command started it (2026-10-23: a hung run kept Peter's
# keyboard and mouse locked for 9 minutes). Child processes inherit this; the deck keys never have it.
$env:IRDECK_KIDS_TEST_MAXSEC = '30'
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "  ok    $what" } else { $script:fail++; Write-Host "  FAIL  $what" } }
function Note($what) { Write-Host "  info  $what" }
function Section($title) { Assert-RigFree -Where $title; Write-Host $title }

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class KidsInject {
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int cb);
  public static uint F23() {
    INPUT[] a = new INPUT[2];
    a[0].type = 1; a[0].u.ki.wVk = 0x86;
    a[1].type = 1; a[1].u.ki.wVk = 0x86; a[1].u.ki.dwFlags = 2;
    return SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
  }
}
'@

$iso = Join-Path $env:TEMP 'paddock-k01'
$cli = $null
$realLock = Join-Path $root 'dash\kids.lock'
$realStop = Join-Path $root 'dash\kids.stop'
function Ir {
  $o = & $cli @args 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join "`n") }
}
function Read-Hook {
  $h = @{ pid = 0; kb = 0; mouse = 0; vk = -1; n = 0; pass = 0 }
  $p = Join-Path $iso 'dash\kids.hook'
  if (-not (Test-Path -LiteralPath $p)) { return $h }
  foreach ($line in [IO.File]::ReadAllLines($p)) {
    $i = $line.IndexOf('='); if ($i -lt 1) { continue }
    $k = $line.Substring(0, $i).Trim(); $v = 0
    [void][int]::TryParse($line.Substring($i + 1).Trim(), [ref]$v)
    if ($h.ContainsKey($k)) { $h[$k] = $v }
  }
  return $h
}
function Stop-Iso {
  if ($cli -and (Test-Path -LiteralPath $cli)) {
    & $cli kids off 2>&1 | Out-Null
  }
  $h = Read-Hook
  if ($h.pid -gt 0) {
    $p = Get-Process -Id $h.pid -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -like 'irdeck*') { try { $p.Kill() } catch { } }
  }
}

try {
  $cands = @(
    (Join-Path $env:TEMP 'ird\irdeck-cli.exe'),
    (Join-Path $root 'irdeck-cli.exe')
  ) | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending
  if ($cands.Count -eq 0) { Check 'irdeck-cli.exe exists (build-irdeck.ps1)' $false; throw 'no cli' }
  $srcCli = $cands[0]
  if (Test-Path -LiteralPath $iso) { Remove-Item -LiteralPath $iso -Recurse -Force }
  New-Item -ItemType Directory -Force (Join-Path $iso 'keys') | Out-Null
  New-Item -ItemType Directory -Force (Join-Path $iso 'dash') | Out-Null
  Copy-Item -LiteralPath $srcCli -Destination (Join-Path $iso 'irdeck-cli.exe') -Force
  Copy-Item -LiteralPath $srcCli -Destination (Join-Path $iso 'keys\probe.exe') -Force
  foreach ($k in 'tow', 'smartdry', 'restart', 'home') { Copy-Item -LiteralPath $srcCli -Destination (Join-Path $iso "keys\$k.exe") -Force }
  [IO.File]::WriteAllText((Join-Path $iso 'keys\keys.map'), "probe=state`r`nkids=kids`r`ntow=tow --pretend 0.4`r`nsmartdry=smart --dry`r`nrestart=confirm restart-race restartrace`r`nhome=rigon`r`n", (New-Object Text.UTF8Encoding $false))
  $cli = Join-Path $iso 'irdeck-cli.exe'

  'Kids mode test'
  Section '1. flag file'
  $r = Ir kids status
  Check 'status is a kids line and starts off' ($r.rc -eq 0 -and $r.out -match 'kids: off hook=off boot=\d+' -and $r.out -notmatch 'unknown command')
  $boot = [regex]::Match($r.out, 'boot=(\d+)').Groups[1].Value
  Check 'this boot has an id' ($boot -match '^\d+$' -and [int64]$boot -ne 0)
  $r2 = Ir kids status
  Check 'the boot id stays the same' ($r2.out -match [regex]::Escape("boot=$boot"))
  [IO.File]::WriteAllText((Join-Path $iso 'dash\kids.lock'), "boot=1`r`nuntil=0`r`n")
  $r = Ir kids status
  Check 'a lock from another boot is off' ($r.out -match 'kids: off')
  Check 'that stale lock file is removed' (-not (Test-Path -LiteralPath (Join-Path $iso 'dash\kids.lock')))
  # 2026-10-23: kids drive while the sim runs, so arming is never refused any more (the old --pretend-sim flag does nothing)
  $r = Ir kids on --pretend-sim --for 12
  Check 'arming is not refused when the sim would be running' ($r.rc -eq 0 -and $r.out -match 'kids: locked' -and $r.out -notmatch 'refused')
  Check 'the lock is written' (Test-Path -LiteralPath (Join-Path $iso 'dash\kids.lock'))
  $r = Ir kids off
  Check 'kids off clears it again' ($r.rc -eq 0 -and $r.out -match 'kids: unlocked')
  $r = Ir kids on --for 12
  Check 'kids on locks and the hook is up' ($r.rc -eq 0 -and $r.out -match 'kids: locked')
  $h = Read-Hook
  Check 'the hook file says keyboard and mouse' ($h.kb -eq 1 -and $h.mouse -eq 1 -and $h.pid -gt 0)
  $alive = Get-Process -Id $h.pid -ErrorAction SilentlyContinue
  Check 'the hook process is running' ($alive -and -not $alive.HasExited)
  $r = Ir kids on --for 12
  Check 'a second on while it is already locked does nothing new' ($r.rc -eq 0 -and $r.out -match 'kids: already locked')
  $r = Ir kids status
  Check 'status stays on with the hook' ($r.out -match 'kids: on hook=on')

  Section '2. key ignore'
  $probe = & (Join-Path $iso 'keys\probe.exe') 2>&1 | ForEach-Object { "$_" }
  $probe = $probe -join "`n"
  Check 'a locked deck key is ignored' ($probe -match 'kids mode: ignored' -and $probe -notmatch 'state: sim=')
  # the keys a child needs while driving still run (they refuse or act harmlessly here: no sim)
  $pt = (& (Join-Path $iso 'keys\tow.exe') 2>&1 | ForEach-Object { "$_" }) -join "`n"
  Check 'TOW still runs while locked' ($pt -notmatch 'kids mode: ignored' -and $pt -match 'tow: stationary')
  $ps = (& (Join-Path $iso 'keys\smartdry.exe') 2>&1 | ForEach-Object { "$_" }) -join "`n"
  Check 'GET IN (smart) still runs while locked' ($ps -notmatch 'kids mode: ignored' -and $ps -match 'smart --dry: get in plan')
  $pr = (& (Join-Path $iso 'keys\restart.exe') 2>&1 | ForEach-Object { "$_" }) -join "`n"
  Check 'RESTART still runs while locked, in one press' ($pr -notmatch 'kids mode: ignored' -and $pr -match 'one press, no arming')
  $r = Ir kids off
  Check 'kids off unlocks' ($r.rc -eq 0 -and $r.out -match 'kids: unlocked')
  Start-Sleep -Milliseconds 200
  $r = Ir kids status
  Check 'status is off after kids off' ($r.out -match 'kids: off hook=off')
  Check 'the lock file is gone' (-not (Test-Path -LiteralPath (Join-Path $iso 'dash\kids.lock')))
  $probe = & (Join-Path $iso 'keys\probe.exe') 2>&1 | ForEach-Object { "$_" }
  $probe = $probe -join "`n"
  Check 'the same key runs again once the lock is off' ($probe -match 'state: sim=' -and $probe -notmatch 'kids mode: ignored')

  Section '3. hook start, swallow, stop, and a dead hook'
  # injected input (SendInput, what irdeck itself uses for GET IN, RESTART and chat) must pass the hook
  $r = Ir kids on --for 12
  Check 'the hook starts again' ($r.rc -eq 0 -and $r.out -match 'kids: locked')
  $beforeN = (Read-Hook).n; $beforeP = (Read-Hook).pass
  $sent = [KidsInject]::F23()
  $passed = $false
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 50
    $h = Read-Hook
    if ($h.vk -eq 134 -and $h.pass -gt $beforeP) { $passed = $true; break }
  }
  Check 'an injected key (SendInput F23) passes the keyboard hook' ($sent -ge 1 -and $passed -and (Read-Hook).n -eq $beforeN)
  $r = Ir kids off
  # real input is swallowed. A test cannot press real hardware, so the test switch makes the hook treat injected input as real
  $env:IRDECK_KIDS_BLOCK_INJECTED = '1'
  try { $r = Ir kids on --for 12 } finally { Remove-Item Env:\IRDECK_KIDS_BLOCK_INJECTED -ErrorAction SilentlyContinue }
  Check 'the hook starts with the test switch' ($r.rc -eq 0 -and $r.out -match 'kids: locked')
  $before = (Read-Hook).n
  $sent = [KidsInject]::F23()
  $saw = $false
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 50
    $h = Read-Hook
    if ($h.vk -eq 134 -and $h.n -gt $before) { $saw = $true; break }
  }
  Check 'a keyboard hook swallowed F23' ($sent -ge 1 -and $saw)
  $pidHook = (Read-Hook).pid
  $logPath = Join-Path $iso 'irdeck.log'
  $logBefore = ''
  if (Test-Path -LiteralPath $logPath) { $logBefore = [IO.File]::ReadAllText($logPath) }
  $r = Ir kids off
  $gone = $false
  for ($i = 0; $i -lt 20; $i++) {
    $p = Get-Process -Id $pidHook -ErrorAction SilentlyContinue
    if (-not $p -or $p.HasExited) { $gone = $true; break }
    Start-Sleep -Milliseconds 50
  }
  $log = ''
  if (Test-Path -LiteralPath $logPath) { $log = [IO.File]::ReadAllText($logPath) }
  $fresh = if ($log.Length -ge $logBefore.Length) { $log.Substring($logBefore.Length) } else { $log }
  Check 'kids off stops the hook process' ($r.out -match 'kids: unlocked' -and $gone)
  Check 'the hook stopped itself (the message loop ended)' ($fresh -match 'kids hook: stopped')
  $r = Ir kids on --for 12
  Check 'locked once more for the crash path' ($r.rc -eq 0 -and $r.out -match 'kids: locked')
  $pidHook = (Read-Hook).pid
  $hp = Get-Process -Id $pidHook -ErrorAction SilentlyContinue
  if ($hp -and $hp.ProcessName -like 'irdeck*') { $hp.Kill(); $hp.WaitForExit(2000) | Out-Null }
  Start-Sleep -Milliseconds 200
  Check 'killing the hook process removes the keyboard hook' (-not (Get-Process -Id $pidHook -ErrorAction SilentlyContinue))
  Check 'the lock file is still there after the crash' (Test-Path -LiteralPath (Join-Path $iso 'dash\kids.lock'))
  $probe = & (Join-Path $iso 'keys\probe.exe') 2>&1 | ForEach-Object { "$_" }
  $probe = $probe -join "`n"
  Check 'deck keys stay ignored after the hook has died' ($probe -match 'kids mode: ignored')
  $r = Ir kids off
  Check 'one kids off clears the flag with the hook already dead' ($r.rc -eq 0 -and $r.out -match 'kids: unlocked' -and -not (Test-Path -LiteralPath (Join-Path $iso 'dash\kids.lock')))
  $probe = & (Join-Path $iso 'keys\probe.exe') 2>&1 | ForEach-Object { "$_" }
  $probe = $probe -join "`n"
  Check 'the deck key works after that one press' ($probe -match 'state: sim=' -and $probe -notmatch 'kids mode: ignored')
  $r = Ir kids --for 30   # 30 s: the HOME step below must never meet an expired lock (rigon would then really run)
  Check 'the key command (toggle) locks' ($r.rc -eq 0 -and $r.out -match 'kids: locked')
  $r = Ir kids
  Check 'a second toggle inside 0.7 s is one press' ($r.rc -eq 0 -and $r.out -match 'repeat press ignored' -and $r.out -notmatch 'kids: unlocked')
  $r = Ir kids status
  Check 'it is still locked after the bounce' ($r.out -match 'kids: on')
  Start-Sleep -Milliseconds 800
  $r = Ir kids
  Check 'a second KIDS press does not unlock: it asks for HOME within 4 s (a child mashing the deck hit KIDS)' ($r.rc -eq 0 -and $r.out -match 'press HOME within 4 seconds' -and $r.out -notmatch 'kids: unlocked')
  $still = (Ir kids status).out -match 'kids: on'
  Check 'still locked after that press' $still
  # HOME goes through a deck key exe (the unlock is a deck rule). Only while still locked: an unlocked HOME would really run RIG ON.
  if ($still) { $homeOut = (& (Join-Path $iso 'keys\home.exe') 2>&1 | ForEach-Object { "$_" }) -join "`n"; $hlog = [IO.File]::ReadAllText((Join-Path $iso 'irdeck.log')) }
  Check 'HOME within 4 s unlocks, and RIG ON itself does not run' ($still -and $hlog -match 'kids: unlocked \(KIDS then HOME\)' -and $hlog -notmatch 'rigon: ')
  Check 'unlocked: the lock file is gone' (-not (Test-Path -LiteralPath (Join-Path $iso 'dash\kids.lock')))

  Section '4. top screen and the deck key'
  $kidsCs = [IO.File]::ReadAllText((Join-Path $root 'src\kids.cs'))
  $ir = [IO.File]::ReadAllText((Join-Path $root 'src\irdeck.cs'))
  $ui = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\ui.js'))
  $css = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\style.css'))
  $dash = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
  $deck = [IO.File]::ReadAllText((Join-Path $root 'build-deck.ps1'))
  Check 'the hook is keyboard and mouse only (the wheel is not blocked)' ($kidsCs -match 'WH_KEYBOARD_LL' -and $kidsCs -match 'WH_MOUSE_LL' -and $kidsCs -notmatch 'BlockInput' -and $kidsCs -notmatch 'RegisterRawInputDevices')
  Check 'deck keys check the lock before they run' ($ir -match 'KidsLocked\(\)' -and $ir -match 'kids mode: ignored')
  Check 'the top screen says KIDS MODE and how to unlock (KIDS, then HOME)' ($ui.Contains('KIDS MODE  -  keyboard and deck locked  -  to unlock press KIDS, then HOME') -and $dash.Contains('KIDS MODE  -  keyboard and deck locked  -  to unlock press KIDS, then HOME') -and $css -match '#kidsMode')
  Check 'MAIN keeps a KIDS key at 6,0 that runs kids' ($deck -match "'6,0'\s*=\s*K 'KIDS'" -and $deck -match "\(L 'kids'\s+'kids'\)")
  $page = $null; $cssPage = $null; $api = $null; $httpErr = ''
  try {
    $page = (Invoke-WebRequest 'http://localhost:8199/v2/ui.js' -UseBasicParsing -TimeoutSec 3).Content
    $cssPage = (Invoke-WebRequest 'http://localhost:8199/v2/style.css' -UseBasicParsing -TimeoutSec 3).Content
  } catch { $httpErr = $_.Exception.Message }
  Check 'the running top screen has the line' ($httpErr -eq '' -and $page.Contains('KIDS MODE  -  keyboard and deck locked  -  to unlock press KIDS, then HOME') -and $cssPage -match '#kidsMode')
  if ($httpErr) { Note $httpErr }
  $until = [DateTime]::UtcNow.AddSeconds(8).Ticks
  [IO.File]::WriteAllText($realLock, ("boot={0}`r`nuntil={1}`r`n" -f $boot, $until))
  try {
    $api = Invoke-RestMethod 'http://localhost:8199/api/kids' -TimeoutSec 3
    Check 'the top screen API says KIDS MODE and how to unlock, for this boot' ($api.on -eq $true -and $api.text -eq 'KIDS MODE  -  keyboard and deck locked  -  to unlock press KIDS, then HOME')
  } catch {
    Check 'the top screen API says KIDS MODE and how to unlock, for this boot' $false
    Note $_.Exception.Message
  } finally {
    if (Test-Path -LiteralPath $realLock) { Remove-Item -LiteralPath $realLock -Force -ErrorAction SilentlyContinue }
  }
  try {
    $api = Invoke-RestMethod 'http://localhost:8199/api/kids' -TimeoutSec 3
    Check 'the line is off once the flag is gone' ($api.on -eq $false)
  } catch {
    Check 'the line is off once the flag is gone' $false
    Note $_.Exception.Message
  }

  $r = Ir kids on --for 2
  Check 'a short test lock arms' ($r.rc -eq 0 -and $r.out -match 'kids: locked')
  $expired = $false
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 200
    $r = Ir kids status
    if ($r.out -match 'kids: off') { $expired = $true; break }
  }
  Check 'the test lock ends by itself' ($expired -and -not (Test-Path -LiteralPath (Join-Path $iso 'dash\kids.lock')))
}
finally {
  Stop-Iso
  if (Test-Path -LiteralPath $realLock) { Remove-Item -LiteralPath $realLock -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $realStop) { Remove-Item -LiteralPath $realStop -Force -ErrorAction SilentlyContinue }
  Exit-TestLock
}

Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
