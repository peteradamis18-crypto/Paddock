# Builds irdeck.exe and irdeck-cli.exe with the C# compiler that ships with Windows, then puts them in place:
# both go to the iRacingDeck folder, and every key named in keys\keys.map gets the new exe as keys\<name>.exe.
#   powershell -ExecutionPolicy Bypass -File build-irdeck.ps1             build + deploy (refuses while a sim session is running)
#   powershell -ExecutionPolicy Bypass -File build-irdeck.ps1 -NoDeploy   only compile (to %TEMP%\ird), changes nothing else
#   -KeysOnly -From <exe> -KeysDir <dir>                                   only the key-copy step (tests\build-irdeck-test.ps1)
# New .cs file? Add it to $src below (and to the build block in docs\SPEC-next.md).
# Exit codes: 0 done, 1 build failed or a session is running, 3 some key copies are still old (named in the output).
param([switch]$NoDeploy, [switch]$KeysOnly, [string]$From = '', [string]$KeysDir = '')
$r = Split-Path -Parent $MyInvocation.MyCommand.Path

# Every name in keys.map gets the new exe. (It used to update only copies whose hash matched the OLD irdeck.exe: a copy that
# was busy once never matched again and stayed old for ever.) A busy copy is retried three times, a second apart.
function Update-KeyCopies([string]$exe, [string]$dir) {
  $map = Join-Path $dir 'keys.map'
  if (-not (Test-Path -LiteralPath $map)) { "no keys.map in $dir - no key copies to update"; return 0 }
  $names = @(Get-Content -LiteralPath $map | Where-Object { $_ -match '^\s*([^#=\s][^=]*)=' } | ForEach-Object { ($_ -split '=', 2)[0].Trim() } | Select-Object -Unique)
  $want = (Get-FileHash -LiteralPath $exe).Hash
  $old = @()
  foreach ($n in $names) {
    $dst = Join-Path $dir "$n.exe"
    $ok = $false
    for ($try = 1; $try -le 4 -and -not $ok; $try++) {
      try { Copy-Item -LiteralPath $exe -Destination $dst -Force -ErrorAction Stop; $ok = ((Get-FileHash -LiteralPath $dst).Hash -eq $want) } catch { }
      if (-not $ok -and $try -lt 4) { Start-Sleep -Seconds 1 }
    }
    if (-not $ok) { $old += $n }
  }
  "updated $($names.Count - $old.Count) of $($names.Count) key copies"
  if ($old.Count -gt 0) { "STILL OLD (in use; press nothing and run this again): $($old -join ', ')"; return 3 }
  return 0
}

if ($KeysOnly) {
  if (-not $From -or -not $KeysDir) { 'KeysOnly needs -From <exe> and -KeysDir <dir>'; exit 1 }
  $out = @(Update-KeyCopies $From $KeysDir); $code = $out[-1]; $out[0..($out.Count - 2)]; exit $code
}

$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"; $wpf = "$fw\WPF"; $out = Join-Path $env:TEMP 'ird'
New-Item -ItemType Directory -Force $out | Out-Null
$refs = @('-r:System.dll', '-r:System.Core.dll', '-r:System.Drawing.dll', '-r:System.Windows.Forms.dll', '-r:System.Web.Extensions.dll',
          "-r:$wpf\UIAutomationClient.dll", "-r:$wpf\UIAutomationTypes.dll", "-r:$wpf\WindowsBase.dll")
$src = @("$r\src\irdeck.cs", "$r\src\deckstate.cs", "$r\src\guest.cs", "$r\src\testdrive.cs", "$r\src\overlays.cs", "$r\src\mydrive.cs", "$r\src\actions.cs", "$r\src\official.cs", "$r\src\sound.cs", "$r\src\tunerbox.cs", "$r\src\kids.cs", "$r\src\deckrules.cs", "$r\src\keymsg.cs", "$r\src\ac.cs", "$r\src\spot.cs", "$r\src\deckguard.cs", "$r\src\deckprofile.cs")   # add new src files here
& "$fw\csc.exe" -nologo -optimize+ -target:winexe "-out:$out\irdeck.exe" @refs @src
if ($LASTEXITCODE -ne 0) { 'build failed (irdeck.exe)'; exit 1 }
& "$fw\csc.exe" -nologo -optimize+ -target:exe -define:CLI "-out:$out\irdeck-cli.exe" @refs @src
if ($LASTEXITCODE -ne 0) { 'build failed (irdeck-cli.exe)'; exit 1 }
if ($NoDeploy) { "built in $out (not deployed)"; exit 0 }
if (Test-Path "$r\irdeck-cli.exe") { if ((& "$r\irdeck-cli.exe" state) -match 'telemetry=on') { 'iRacing is in a session - deploy when you are out of the car.'; exit 1 } }
Copy-Item "$out\irdeck.exe" "$r\irdeck.exe" -Force; Copy-Item "$out\irdeck-cli.exe" "$r\irdeck-cli.exe" -Force
$res = @(Update-KeyCopies "$r\irdeck.exe" "$r\keys"); $code = $res[-1]
"deployed irdeck.exe and irdeck-cli.exe"; $res[0..($res.Count - 2)]
exit $code
