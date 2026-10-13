# Frame-rate report from an iRacing telemetry file (.ibt). Read-only.
#   fps-report.ps1            newest .ibt in Documents\iRacing\telemetry
#   fps-report.ps1 <file>     a specific file
# Uses only on-track samples, skips the first 5 s after each time you get in the car (loading hitch).
# FrameRate is iRacing's 1-second average; CpuUsageFG / GpuUsage are 0..1 shares of the frame budget.
param([string]$File)
$dir = Join-Path $env:USERPROFILE 'OneDrive\Documents\iRacing\telemetry'
if (-not $File) { $File = (Get-ChildItem $dir -Filter *.ibt | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName }
$b = [IO.File]::ReadAllBytes($File)
$tick = [BitConverter]::ToInt32($b, 8); $nv = [BitConverter]::ToInt32($b, 24); $vho = [BitConverter]::ToInt32($b, 28)
$bl = [BitConverter]::ToInt32($b, 36); $bo = [BitConverter]::ToInt32($b, 52); $rc = [BitConverter]::ToInt32($b, 140)
$vars = @{}
for ($i = 0; $i -lt $nv; $i++) { $o = $vho + 144 * $i; $vars[[Text.Encoding]::ASCII.GetString($b, $o + 16, 32).Trim([char]0)] = @([BitConverter]::ToInt32($b, $o), [BitConverter]::ToInt32($b, $o + 4)) }
function V($n, $base) { $t = $vars[$n][0]; $o = $base + $vars[$n][1]
  switch ($t) { 1 { return [int]$b[$o] } 2 { return [BitConverter]::ToInt32($b, $o) } 4 { return [BitConverter]::ToSingle($b, $o) } 5 { return [BitConverter]::ToDouble($b, $o) } default { return [BitConverter]::ToInt32($b, $o) } } }
$step = [math]::Max(1, [int]($tick / 10))   # 10 samples a second is plenty for 1-second averages
$s = New-Object System.Collections.Generic.List[object]; $onSince = -1
for ($r = 0; $r -lt $rc; $r += $step) {
  $base = $bo + $r * $bl
  if ((V 'IsOnTrack' $base) -eq 0) { $onSince = -1; continue }
  if ($onSince -lt 0) { $onSince = $r }
  if (($r - $onSince) -lt 5 * $tick) { continue }
  $fps = V 'FrameRate' $base; if ($fps -le 1) { continue }
  $s.Add([pscustomobject]@{ t = $r / $tick; fps = $fps; cpu = (V 'CpuUsageFG' $base); gpu = (V 'GpuUsage' $base); lap = (V 'Lap' $base); pct = (V 'LapDistPct' $base) })
}
if ($s.Count -eq 0) { "No on-track driving in $File"; exit 1 }
function Sum($set, $label) {
  $f = @($set | ForEach-Object fps | Sort-Object)
  "{0,-8} avg {1,5:N0} fps   1% low {2,5:N0}   worst {3,5:N0}   CPU {4,3:N0}% (peak {5,3:N0}%)   GPU {6,3:N0}% (peak {7,3:N0}%)   {8,4:N0}s" -f $label,
    ($f | Measure-Object -Average).Average, $f[[int][math]::Floor($f.Count * 0.01)], $f[0],
    (($set | Measure-Object cpu -Average).Average * 100), (($set | Measure-Object cpu -Maximum).Maximum * 100),
    (($set | Measure-Object gpu -Average).Average * 100), (($set | Measure-Object gpu -Maximum).Maximum * 100), ($set.Count / 10) }
"Frame-rate report: $(Split-Path $File -Leaf)"
''
Sum $s 'whole'
$s | Group-Object lap | Sort-Object { [int]$_.Name } | ForEach-Object { Sum $_.Group ('lap ' + $_.Name) }
''
$cap = [math]::Round(($s | Measure-Object fps -Maximum).Maximum)
$below = @($s | Where-Object { $_.fps -lt $cap - 5 }).Count
"Time below the frame limit ($cap): {0:N0}%" -f (100 * $below / $s.Count)
''
'Worst moments (lap, % around the lap):'
$s | Sort-Object fps | Select-Object -First 400 | Group-Object { "{0}|{1}" -f $_.lap, [math]::Floor($_.pct * 20) } |
  Sort-Object { ($_.Group | Measure-Object fps -Minimum).Minimum } | Select-Object -First 5 | ForEach-Object {
    $g = $_.Group; "  lap {0}, {1:N0}%: {2:N0} fps  CPU {3:N0}%  GPU {4:N0}%" -f $g[0].lap, ($g[0].pct * 100), ($g | Measure-Object fps -Minimum).Minimum, (($g | Measure-Object cpu -Average).Average * 100), (($g | Measure-Object gpu -Average).Average * 100) }
''
$cpuP = ($s | Measure-Object cpu -Average).Average; $gpuP = ($s | Measure-Object gpu -Average).Average
$avg = ($s | Measure-Object fps -Average).Average
if ($avg -ge $cap - 3 -and $gpuP -lt 0.7 -and $cpuP -lt 0.7) { 'Verdict: held the limit with room to spare - graphics can go up.' }
elseif ($gpuP -ge 0.9) { 'Verdict: graphics card is the limit - lower GPU-heavy settings (MSAA, shadows, SSR/SSAO).' }
elseif ($cpuP -ge 0.85) { 'Verdict: processor is the limit - lower car counts (cars drawn, mirror cars), mirrors, crowds.' }
else { 'Verdict: close to the limit - leave settings as they are.' }
