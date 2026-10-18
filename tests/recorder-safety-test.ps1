# Regression for two recorder bugs found from Peter's real logs (2026-10-18):
#  1. The recorder's test picture used drawtext without a font file -> "Fontconfig error: Cannot load default config file" -> ffmpeg died
#     (25 log lines, 10-12 / 10-15 / 10-18, all in test runs).
#  2. Retention deleted Peter's REAL session videos while a test had the scratch vault on: the in-memory session list kept the real
#     files, a pretend session pushed the count past "keep 3" and the oldest REAL file was deleted (10-15 11:20 and 11:21, 10-18 08:53 and
#     08:54: four real race videos gone).
# Offline: reads source, runs ffmpeg for 4 s on a made-up picture in a temp folder. Touches no vault, no screens, no irdash.
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Section($title) { Assert-RigFree -Where $title; $title }
function Check($name, $ok) { if ($ok) { Write-Host "ok   $name" } else { Write-Host "FAIL $name"; $script:fail++ } }

Section '1. the test picture needs no fontconfig'
Assert-RigFree -Where 'ffmpeg test picture'
$rec = Get-Content (Join-Path $root 'dash\src\recorder.cs') -Raw
Check 'drawtext in recorder.cs names a font file' ($rec -match "drawtext=fontfile='C\\\\\\\\:/Windows/Fonts/arial\.ttf'" -or $rec -match 'drawtext=fontfile=')
Check 'the font file exists on this PC' (Test-Path 'C:\Windows\Fonts\arial.ttf')
$ff = Join-Path $root 'vault\bin\ffmpeg.exe'
$tmp = Join-Path $env:TEMP ('rec-safety-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $base = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000
  $fc = "testsrc2=size=1280x720:rate=60,realtime,settb=1/1000000,setpts=RTCTIME-$base,split=2[a][b];[b]crop=640:32:0:0,format=yuv420p,geq=lum='255*mod(floor(floor(T*1000)/pow(2,floor(X/20))),2)':cb=128:cr=128[c];[a][c]overlay=0:0,drawtext=fontfile='C\:/Windows/Fonts/arial.ttf':text='%{pts\:hms}':x=10:y=60:fontsize=48:fontcolor=white:box=1:boxcolor=black@0.7,hflip,vflip"
  $psi = New-Object Diagnostics.ProcessStartInfo $ff
  $psi.Arguments = "-hide_banner -y -loglevel error -t 4 -threads 1 -filter_complex `"$fc`" -c:v libx264 -preset ultrafast -pix_fmt yuv420p -b:v 4M -g 60 -bf 0 -enc_time_base 1/1000000 -fps_mode passthrough -f segment -segment_time 2 -segment_format mpegts `"$tmp\t-%05d.ts`""
  $psi.UseShellExecute = $false; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $p = [Diagnostics.Process]::Start($psi); try { $p.PriorityClass = 'BelowNormal' } catch { }
  $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  $bytes = (Get-ChildItem $tmp -Filter *.ts | Measure-Object Length -Sum).Sum
  Check 'ffmpeg exits 0 on the exact test-picture filter' ($p.ExitCode -eq 0)
  Check 'no Fontconfig message' ($err -notmatch 'Fontconfig')
  Check 'video was written' ($bytes -gt 100000)
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Section '2. retention never deletes files outside the active vault'
Assert-RigFree -Where 'retention source checks'
Check 'RetainSessions only lists sessions inside the active vault' ($rec -match 'InActiveVault\(s\.File\)\) un\.Add\(s\)')
Check 'disk-pressure clean-up only picks sessions inside the active vault' ($rec -match 'InActiveVault\(s\.File\) && WallMs\(\) - s\.Created > 600000')
$vault = Get-Content (Join-Path $root 'dash\src\vault.cs') -Raw
Check 'the sandbox switch re-reads the recorder sessions' ($vault -match 'Recorder\.VaultRootChanged\(\)')
Check 'the recorder re-read leaves an open session alone' ($rec -match 's\.Open \|\| s\.Saving\) return')

Section '3. a blip does not take a last-3 slot from a real race'
Assert-RigFree -Where 'blip source checks'
Check 'a closed session under 90 s with no lap is removed first and not counted toward the last few' ($rec -match 's\.Duration < 90 && s\.LapRows\.Count == 0 && WallMs\(\) - s\.Created > 600000\) del\.Add\(s\)' -and $rec -match 'int n = real\.Count;')

if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'all ok' }
