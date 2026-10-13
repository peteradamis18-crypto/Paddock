# The cross-test lock (tests\guard.ps1: Enter-TestLock / Exit-TestLock). No sim, no irdash, no hook: it uses its own mutex
# name, so it never waits for a real live test. It starts child copies of itself (-Child) that take turns on the lock:
#   1. a holder releases the lock, a waiter that gives up says NOT RUN and exits 3
#   2. a waiter gets the lock when the holder releases it, and a holder that dies without releasing does not block the next test
# About 45 s.
param([string]$Child = '', [string]$MutexName = 'Global\PaddockLockSelfTest', [double]$Minutes = 1)
if ($Child) {
  # a child copy: takes the lock the way a live test does, then ends the way its test case says
  . (Join-Path $PSScriptRoot 'guard.ps1')
  if ($Child -eq 'hold') { Enter-TestLock 'holder' -WaitMinutes $Minutes -Name $MutexName; Write-Output 'HELD'; Start-Sleep -Seconds 20; Exit-TestLock; Write-Output 'RELEASED'; exit 0 }
  if ($Child -eq 'crash') { Enter-TestLock 'crasher' -WaitMinutes $Minutes -Name $MutexName; Write-Output 'GOT'; exit 0 }   # ends WITHOUT Exit-TestLock, like a test that dies
  Enter-TestLock $Child -WaitMinutes $Minutes -Name $MutexName; Write-Output 'GOT'; Exit-TestLock; exit 0
}

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$script:ok = 0; $script:fail = 0
function Check($label, $cond, $detail = '') { if ($cond) { $script:ok++; Write-Output "  ok    $label" } else { $script:fail++; Write-Output "  FAIL  $label $detail" } }
function Section($t) { Assert-RigFree -Where $t; Write-Output ''; Write-Output $t }
$mutex = 'Global\PaddockLockSelfTest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$self = $PSCommandPath
function Start-Child([string]$role, [double]$mins) {
  $out = Join-Path $env:TEMP ('lock-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
  # cmd.exe is the process we wait on: Windows PowerShell 5.1 gives no ExitCode for a process whose output Start-Process redirects
  $cmdArgs = '/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $self + '" -Child ' + $role + ' -MutexName ' + $mutex + ' -Minutes ' + $mins.ToString([Globalization.CultureInfo]::InvariantCulture) + ' > "' + $out + '" 2>&1'
  $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs -PassThru -WindowStyle Hidden
  return @{ p = $p; out = $out; t0 = Get-Date }
}
function Finish-Child($c, [int]$maxSecs) {
  $done = $c.p.WaitForExit($maxSecs * 1000)
  $code = -1; if ($done) { $code = $c.p.ExitCode }
  $text = @(Get-Content $c.out -ErrorAction SilentlyContinue); Remove-Item $c.out -Force -ErrorAction SilentlyContinue
  return @{ code = $code; text = ($text -join ' / '); secs = ((Get-Date) - $c.t0).TotalSeconds }
}

Section '1. a holder releases the lock; a waiter that gives up says so'
$holder = Start-Child 'hold' 1
Start-Sleep -Seconds 6                      # the holder has the lock by now
$short = Start-Child 'short' 0.15           # gives up after about 9 s
$rs = Finish-Child $short 40
Check 'a waiter that gives up says NOT RUN and exits 3' ($rs.code -eq 3 -and $rs.text -match 'NOT RUN' -and $rs.text -notmatch 'GOT') "exit $($rs.code): $($rs.text)"
Check 'it waited about its 9 s, not the full 15 minutes' ($rs.secs -ge 7 -and $rs.secs -lt 20) ("{0:N1} s" -f $rs.secs)
Check 'it said plainly that it was waiting' ($rs.text -match 'waiting: another live test holds the test lock')

Section '2. a waiter gets the lock when the holder releases it; a dead holder does not block the next test'
$crash = Start-Child 'crash' 1               # waits for the holder, takes the lock, then dies without releasing it
$rh = Finish-Child $holder 60
Check 'the holder released the lock (RELEASED)' ($rh.code -eq 0 -and $rh.text -match 'RELEASED') "exit $($rh.code): $($rh.text)"
$rc = Finish-Child $crash 60
Check 'the waiter got the lock after the holder released it' ($rc.code -eq 0 -and $rc.text -match 'GOT') "exit $($rc.code): $($rc.text)"
$after = Start-Child 'after' 1               # the lock was left behind by a dead process: this one must still get it
$ra = Finish-Child $after 60
Check 'after a dead holder, the next test still gets the lock' ($ra.code -eq 0 -and $ra.text -match 'GOT') "exit $($ra.code): $($ra.text)"

Write-Output ''
Write-Output "$script:ok passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
