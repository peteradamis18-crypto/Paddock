$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$pass = 0; $fail = 0
function Section($s) { Assert-RigFree -Where $s; Write-Host $s }
function Check($n, $yes) { if ($yes) { $script:pass++; Write-Host "  ok    $n" } else { $script:fail++; Write-Host "  FAIL  $n" } }
$tmp = Join-Path $env:TEMP ('deckstate-test-' + $PID)
New-Item -ItemType Directory -Force $tmp | Out-Null
$driver = Join-Path $tmp 'driver.cs'
$exe = Join-Path $tmp 'driver.exe'
@'
using System;
using IRDeck;
class Driver {
  static void Main(string[] a) {
    if (a.Length > 0 && a[0] == "pair") {
      Console.WriteLine(DeckStateResolver.TelemetryAdvanced(int.Parse(a[1]), int.Parse(a[2])) ? "FRESH" : "WAIT");
      return;
    }
    Snapshot s = new Snapshot();
    s.Sim=bool.Parse(a[0]); s.Ui=bool.Parse(a[1]); s.Fresh=bool.Parse(a[2]); s.Connected=bool.Parse(a[3]);
    s.SessionKnown=bool.Parse(a[4]); s.OnTrack=bool.Parse(a[5]); s.Speed=double.Parse(a[6],System.Globalization.CultureInfo.InvariantCulture);
    s.Replay=bool.Parse(a[7]); s.TestOrAi=bool.Parse(a[8]);
    DeckState d=DeckStateResolver.Resolve(s);
    Console.WriteLine(d.Primary+"|"+d.Label+"|"+d.Action);
  }
}
'@ | Set-Content -LiteralPath $driver -Encoding ASCII
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -nologo -target:exe "-out:$exe" (Join-Path $root 'src\deckstate.cs') $driver
if ($LASTEXITCODE -ne 0) { throw 'could not compile the production resolver harness' }
Section '1. execute shared production resolver snapshots'
$pair = (& $exe @('pair','120','121') | Out-String).Trim()
Check 'one-shot pair sees SDK tick advance' ($pair -eq 'FRESH')
$frozen = (& $exe @('pair','120','120') | Out-String).Trim()
Check 'one-shot frozen SDK tick stays stale' ($frozen -eq 'WAIT')
$wrapped = (& $exe @('pair','2147483647','-2147483648') | Out-String).Trim()
Check 'SDK signed tick rollover still advances' ($wrapped -eq 'FRESH')
$rows = @(
  @{n='RIGON'; a=@('false','false','false','false','false','false','0','false','false'); e='RIGON|RIG ON|rigon'},
  @{n='HOME'; a=@('false','true','false','false','false','false','0','false','false'); e='HOME|HOME|home'},
  @{n='stale tick'; a=@('true','true','false','true','true','false','0','false','false'); e='WAIT|WAIT|'},
  @{n='loading metadata'; a=@('true','true','true','true','false','false','0','false','false'); e='WAIT|WAIT|'},
  @{n='unknown disconnected'; a=@('true','true','true','false','true','false','0','false','false'); e='WAIT|WAIT|'},
  @{n='GETIN'; a=@('true','true','true','true','true','false','0','false','false'); e='GETIN|GET IN|drive-only'},
  @{n='DRIVE'; a=@('true','true','true','true','true','true','1','false','false'); e='DRIVE|DRIVE|'},
  @{n='RESET'; a=@('true','true','true','true','true','true','0.5','false','false'); e='RESET|RESET|tow'},
  @{n='RESET at 2 m/s becomes DRIVE'; a=@('true','true','true','true','true','true','2','false','false'); e='DRIVE|DRIVE|'},
  @{n='SKIP Test'; a=@('true','true','true','true','true','false','0','false','true'); e='SKIP|SKIP|confirm skip skip'},
  @{n='replay'; a=@('true','true','true','true','true','false','0','true','true'); e='WAIT|WAIT|'},
  @{n='official session'; a=@('true','true','true','true','true','false','0','false','false'); e='GETIN|GET IN|drive-only'}
)
foreach ($row in $rows) { $actual = (& $exe @($row.a) | Out-String).Trim(); Check $row.n ($actual -eq $row.e) }
$build = & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-irdeck.ps1') -NoDeploy 2>&1
if ($LASTEXITCODE -ne 0) { throw ('irdeck no-deploy compile failed: ' + ($build -join ' ')) }
Section '2. SMART fake snapshot dispatch'
$cli = Join-Path $env:TEMP 'ird\irdeck-cli.exe'
$armed = Join-Path (Split-Path $cli) 'armed-skip.txt'
$log = Join-Path (Split-Path $cli) 'irdeck.log'
Remove-Item -LiteralPath $armed -Force -ErrorAction SilentlyContinue
$logStart = if (Test-Path $log) { (Get-Content $log).Count } else { 0 }
$fixture = '{"sim":true,"ui":true,"fresh":true,"connected":true,"sessionKnown":true,"onTrack":false,"speed":0,"replay":false,"testOrAi":true}'
$dry = '{"sim":true,"ui":true,"fresh":true,"connected":true,"sessionKnown":true,"onTrack":false,"speed":0,"replay":false,"testOrAi":false}'
$dryOut = & $cli smart --dry --fake $dry 2>&1
Check 'smart --dry prints resolved state, label, and action' (($dryOut -join ' ') -match 'GETIN \| GET IN \| drive-only')
$out = & $cli smart --fake $fixture 2>&1
Check 'one SKIP press writes armed-skip.txt' (Test-Path $armed)
Check 'one SKIP press reports armed' (($out -join ' ') -match 'armed')
Section '3. SMART SKIP bounce stays arm only'
Assert-RigFree -Where 'SMART SKIP bounce'
Remove-Item -LiteralPath $armed -Force -ErrorAction SilentlyContinue
$bounce = & $cli smart --fake-bounce --fake $fixture 2>&1
$firstArm = if (Test-Path $armed) { Get-Content $armed -Raw } else { '' }
$afterBounce = if (Test-Path $armed) { Get-Content $armed -Raw } else { '' }
$newLog = if (Test-Path $log) { @(Get-Content $log | Select-Object -Skip $logStart) -join "`n" } else { '' }
Check 'bounce leaves the original arm expiry intact' ($afterBounce -eq $firstArm)
Check 'first press and bounce never confirm or dispatch SKIP' ($newLog -notmatch 'confirm skip: confirmed' -and $newLog -notmatch 'skip: no session is running' -and $newLog -notmatch 'skip: now in session')
Section '4. deliberate second SMART SKIP press is the only dispatch'
Start-Sleep -Milliseconds 200
$second = & $cli smart --fake $fixture 2>&1
$newLog = if (Test-Path $log) { @(Get-Content $log | Select-Object -Skip $logStart) -join "`n" } else { '' }
Check 'deliberate second press confirms the armed command' ($newLog -match 'confirm skip: confirmed')
Check 'second press reaches guarded skip action without a session' ($newLog -match 'skip: no session is running')
Check 'no successful Next action or session advance occurred' ($newLog -notmatch 'skip: now in session' -and $newLog -notmatch 'skip: the session did not advance')
Remove-Item -LiteralPath $armed -Force -ErrorAction SilentlyContinue
Write-Host "$pass ok, $fail FAIL"
if ($fail) { exit 1 }
