# Builds irdeck.exe and irdeck-cli.exe with the C# compiler that ships with Windows, then puts them in place:
# both go to the iRacingDeck folder, and every keys\*.exe that was a copy of the old irdeck.exe gets the new one.
#   powershell -ExecutionPolicy Bypass -File build-irdeck.ps1             build + deploy (refuses while a sim session is running)
#   powershell -ExecutionPolicy Bypass -File build-irdeck.ps1 -NoDeploy   only compile (to %TEMP%\ird), changes nothing else
# New .cs file? Add it to $src below (and to the build block in docs\SPEC-next.md).
param([switch]$NoDeploy)
$r = Split-Path -Parent $MyInvocation.MyCommand.Path
$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"; $wpf = "$fw\WPF"; $out = Join-Path $env:TEMP 'ird'
New-Item -ItemType Directory -Force $out | Out-Null
$refs = @('-r:System.dll', '-r:System.Core.dll', '-r:System.Drawing.dll', '-r:System.Windows.Forms.dll', '-r:System.Web.Extensions.dll',
          "-r:$wpf\UIAutomationClient.dll", "-r:$wpf\UIAutomationTypes.dll", "-r:$wpf\WindowsBase.dll")
$src = @("$r\src\irdeck.cs", "$r\src\deckstate.cs", "$r\src\guest.cs", "$r\src\testdrive.cs", "$r\src\overlays.cs", "$r\src\mydrive.cs", "$r\src\actions.cs", "$r\src\official.cs", "$r\src\sound.cs", "$r\src\tunerbox.cs", "$r\src\kids.cs", "$r\src\deckrules.cs", "$r\src\keymsg.cs", "$r\src\ac.cs")   # add new src files here
& "$fw\csc.exe" -nologo -optimize+ -target:winexe "-out:$out\irdeck.exe" @refs @src
if ($LASTEXITCODE -ne 0) { 'build failed (irdeck.exe)'; exit 1 }
& "$fw\csc.exe" -nologo -optimize+ -target:exe -define:CLI "-out:$out\irdeck-cli.exe" @refs @src
if ($LASTEXITCODE -ne 0) { 'build failed (irdeck-cli.exe)'; exit 1 }
if ($NoDeploy) { "built in $out (not deployed)"; exit 0 }
if ((& "$r\irdeck-cli.exe" state) -match 'telemetry=on') { 'iRacing is in a session - deploy when you are out of the car.'; exit 1 }
$old = (Get-FileHash "$r\irdeck.exe").Hash
$keys = @(Get-ChildItem "$r\keys" -Filter *.exe | Where-Object { (Get-FileHash $_.FullName).Hash -eq $old })
Copy-Item "$out\irdeck.exe" "$r\irdeck.exe" -Force; Copy-Item "$out\irdeck-cli.exe" "$r\irdeck-cli.exe" -Force
$n = 0
foreach ($k in $keys) { try { Copy-Item "$r\irdeck.exe" $k.FullName -Force; $n++ } catch { Write-Warning "key $($k.Name) is in use; it keeps the old exe until the next build" } }
"deployed irdeck.exe and irdeck-cli.exe; updated $n of $($keys.Count) key copies"
