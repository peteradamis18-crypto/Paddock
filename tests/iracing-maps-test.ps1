# iracing-maps-test.ps1 - are iRacing's drawings (tools\extract-iracing-maps.ps1) the right shape AND do cars land in the right
# place on them? Compares each drawing, point by point at the same lap percentage, with the map built from Peter's own
# telemetry (dash\maps). Offline: reads files, touches nothing, safe while he races.
#   powershell -ExecutionPolicy Bypass -File tests\iracing-maps-test.ps1
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object Web.Script.Serialization.JavaScriptSerializer; $ser.MaxJsonLength = 50000000
$dir = Join-Path $root 'data\iracing-maps'
$files = @(Get-ChildItem $dir -Filter *.json -ErrorAction SilentlyContinue)
Check "iRacing drawings on disk: $($files.Count)" ($files.Count -ge 100)
Check 'Laguna Seca (586) is there' (Test-Path (Join-Path $dir '586.json'))
Check 'the drawings are kept out of the public repo (/data/ is ignored)' ((Get-Content (Join-Path $root '.gitignore')) -contains '/data/')
foreach ($f in (Get-ChildItem (Join-Path $root 'dash\maps') -Filter 't*.json' | Where-Object { $_.Name -notmatch '\.gps\.' })) {
  $id = [regex]::Match($f.Name, '^t(\d+)-').Groups[1].Value; $shape = Join-Path $dir "$id.json"
  if (-not (Test-Path $shape)) { "  info  $($f.Name): no drawing"; continue }
  $a = $ser.DeserializeObject([IO.File]::ReadAllText($f.FullName)); $b = $ser.DeserializeObject([IO.File]::ReadAllText($shape))
  if ($a['source'] -eq 'iracing') { "  info  $($f.Name): already the drawing, nothing to compare"; continue }
  $p = $a['pts']; $q = $b['pts']; $n = [Math]::Min($p.Count, $q.Count)
  # best move + turn + scale of the drawing onto the telemetry map (y flipped: the drawing's y runs down the page)
  $mx = 0.0; $my = 0.0; $wx = 0.0; $wy = 0.0
  for ($i = 0; $i -lt $n; $i++) { $mx += $p[$i][0]; $my += $p[$i][1]; $wx += $q[$i][0]; $wy -= $q[$i][1] }
  $mx /= $n; $my /= $n; $wx /= $n; $wy /= $n
  $re = 0.0; $im = 0.0; $den = 0.0
  for ($i = 0; $i -lt $n; $i++) {
    $zx = $p[$i][0] - $mx; $zy = $p[$i][1] - $my; $ux = $q[$i][0] - $wx; $uy = - $q[$i][1] - $wy
    $re += $ux * $zx + $uy * $zy; $im += $ux * $zy - $uy * $zx; $den += $ux * $ux + $uy * $uy
  }
  $re /= $den; $im /= $den; $err = 0.0; $worst = 0.0
  for ($i = 0; $i -lt $n; $i++) {
    $ux = $q[$i][0] - $wx; $uy = - $q[$i][1] - $wy
    $dx = $re * $ux - $im * $uy - ($p[$i][0] - $mx); $dy = $im * $ux + $re * $uy - ($p[$i][1] - $my)
    $d = $dx * $dx + $dy * $dy; $err += $d; if ($d -gt $worst) { $worst = $d }
  }
  $rms = [Math]::Sqrt($err / $n); $worst = [Math]::Sqrt($worst); $scale = [Math]::Sqrt($re * $re + $im * $im)
  Check ("{0}: typical miss {1:n0} m, worst {2:n0} m, scale {3:n2}" -f $f.BaseName, $rms, $worst, $scale) ($rms -lt 40) 'the drawing and the real laps do not line up'
}
$src = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
Check 'a track with no map file gets iRacing''s drawing first' ($src -match 'json = FromIracing\(key, name\) \?\? FromLibrary\(key, name, true\)')
Check 'clean laps still replace the drawing (builder only keeps source ibt)' ($src -match 'have\.Contains\("\\"source\\":\\"ibt\\""\)')
Check 'the wind arrow is hidden on a drawing (not turned to north)' ([IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\ui.js')) -match "TrackMap\.source === 'iracing' \? 'none'")
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
