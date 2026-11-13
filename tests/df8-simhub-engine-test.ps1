# df8-simhub-engine-test.ps1 - runs tools\df8-flags.js in SimHub's OWN script engine (Jint.dll from its folder), fed with iRacing's real flag
# type (iRacingSDK.SessionFlags), because a browser accepting the script proves nothing about SimHub: if SimHub can't run it the box stays
# dark in a race. Offline: loads two DLLs read-only, touches no live app, safe while Peter races.
#   powershell -ExecutionPolicy Bypass -File tests\df8-simhub-engine-test.ps1
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
$sh = 'C:\Program Files (x86)\SimHub'; $raw = 'DataCorePlugin.GameRawData.Telemetry.SessionFlags'
[AppDomain]::CurrentDomain.add_AssemblyResolve({ param($s, $e) $p = Join-Path 'C:\Program Files (x86)\SimHub' (($e.Name -split ',')[0] + '.dll'); if (Test-Path $p) { [Reflection.Assembly]::LoadFrom($p) } })
$jint = [Reflection.Assembly]::LoadFrom("$sh\Jint.dll")
"  info  SimHub's engine: Jint $($jint.GetName().Version)"
$sdk = [Reflection.Assembly]::LoadFrom("$sh\iRacingSDK.dll")
$flagType = $sdk.GetType('iRacingSDK.SessionFlags')
$js = [IO.File]::ReadAllText((Join-Path $root 'tools\df8-flags.js'))
$engineType = $jint.GetType('Jint.Engine')
$engine = [Activator]::CreateInstance($engineType)
# a compiled helper, not a PowerShell delegate: PowerShell wraps values in its own object, and the script must see what SimHub hands it
Add-Type -ReferencedAssemblies "$sh\iRacingSDK.dll" @'
using System; using System.Collections.Generic;
public class FakeProps { public Dictionary<string, object> D = new Dictionary<string, object>(); public object Get(string k) { object v; return D.TryGetValue(k, out v) ? v : null; }
  public void Flag(string k, long bits) { D[k] = Enum.ToObject(typeof(iRacingSDK.SessionFlags), bits); } public void Bool(string k) { D[k] = true; } public void Int(string k) { D[k] = 1; } }
'@
$fake = New-Object FakeProps
$null = $engine.SetValue('$prop', [Delegate]::CreateDelegate([Func[string, object]], $fake, 'Get'))
$null = $engine.Execute("function __frame(){`n" + $js + "`n}")
function Lit([hashtable]$p) {
  $fake.D.Clear()
  foreach ($k in $p.Keys) { $v = $p[$k]; if ($v -is [bool]) { $fake.Bool($k) } elseif ($k -eq $raw) { $fake.Flag($k, [long]$v) } else { $fake.Int($k) } }
  $r = $engine.Evaluate("JSON.stringify({n:__frame().filter(function(c){return c!=='#FF000000'}).length, f:(globalThis.__ssgFlags||{}).cur, t:typeof `$prop('DataCorePlugin.GameRawData.Telemetry.SessionFlags')})")
  $r.ToString() | ConvertFrom-Json
}
function Reset { $null = $engine.Execute('globalThis.__ssgFlags=undefined;') }
function E([string]$names) { [long][Convert]::ToInt64([Enum]::Parse($flagType, $names)) }
try {
  Reset; $a = Lit @{ $raw = (E 'blue') }
  Check "the script runs in SimHub's engine" ($null -ne $a)
  "  info  iRacing's flag value reaches the script as: $($a.t)"
  Check "a blue flag from iRacing's own type is seen as blue ($($a.f))" ($a.f -eq 'blue')
  foreach ($c in @(@('green', 'green'), @('yellow', 'yellow'), @('debris', 'yellow'), @('white', 'white'), @('checkered', 'checkered'), @('black', 'black'), @('repair', 'orange'), @('red', 'red'))) {
    Reset; $r = Lit @{ $raw = (E $c[0]) }
    Check "iRacing's $($c[0]) shows $($c[1]) ($($r.f))" ($r.f -eq $c[1])
  }
  Reset; $r = Lit @{ $raw = (E 'servicible, green, startGo') }
  Check "green with the bits his real race start sets ($($r.f))" ($r.f -eq 'green')
  Reset; $r = Lit @{ $raw = (E 'blue, green, servicible') }
  Check "blue on top of green, as at 224.7 s in his race ($($r.f))" ($r.f -eq 'blue')
  Reset; $r = Lit @{ $raw = (E 'servicible, startHidden') }
  Check "no flag: dark ($($r.n) lights)" ($r.n -eq 0 -and $r.f -eq '')
  Reset; $r = Lit @{ 'GameRawData.Telemetry.SessionFlagsDetails.IsBlue' = $true }
  Check "raw value missing: SimHub's IsBlue signal still shows blue ($($r.f))" ($r.f -eq 'blue')
  Reset; $r = Lit @{ 'Flag_Green' = 1 }
  Check "raw value missing: SimHub's Flag_Green still shows green ($($r.f))" ($r.f -eq 'green')
} catch { Check 'the script runs in SimHub''s engine' $false $_.Exception.ToString().Substring(0, [Math]::Min(400, $_.Exception.ToString().Length)) }
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
