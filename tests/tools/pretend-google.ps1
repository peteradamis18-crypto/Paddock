# pretend-google.ps1 - build, start and stop the pretend Google (tests\tools\pretend-google.cs, W0-8). Default port 8399.
#   pretend-google.ps1          start      pretend-google.ps1 -Stop     stop
param([int]$Port = 8399, [switch]$Stop)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$bin = Join-Path $here 'bin'; $exe = Join-Path $bin 'pretend-google.exe'; $src = Join-Path $here 'pretend-google.cs'
$pf = Join-Path $bin "pretend-google.$Port.pid"
if ($Port -eq 8199) { throw 'port 8199 is the real irdash' }
if ($Stop) {
  if (Test-Path $pf) { Stop-Process -Id ([int](Get-Content $pf)) -Force -ErrorAction SilentlyContinue; Remove-Item $pf }
  'stopped'; return
}
New-Item -ItemType Directory -Force $bin | Out-Null
if (-not ((Test-Path $exe) -and (Get-Item $exe).LastWriteTime -gt (Get-Item $src).LastWriteTime)) {
  & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -nologo -optimize+ -target:exe "-out:$exe" -r:System.dll -r:System.Core.dll $src
  if ($LASTEXITCODE -ne 0) { throw 'pretend-google.cs does not compile' }
}
if (Test-Path $pf) { Stop-Process -Id ([int](Get-Content $pf)) -Force -ErrorAction SilentlyContinue }
$p = Start-Process -FilePath $exe -ArgumentList "$Port" -WindowStyle Hidden -PassThru
$p.Id | Set-Content $pf
for ($i = 0; $i -lt 40; $i++) {
  try { $null = (New-Object Net.WebClient).DownloadString("http://localhost:$Port/__stats"); "pretend google up on http://localhost:$Port/ (pid $($p.Id))"; return } catch { Start-Sleep -Milliseconds 150 }
}
throw 'pretend google did not start'
