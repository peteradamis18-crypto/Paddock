# Copies iRacing's own track drawings out of the irdashies app on this PC into data\iracing-maps\<trackId>.json, one file a
# track: 720 points, one per 1/720th of a lap, starting at the start/finish line (same spacing as dash\maps). irdash uses them
# for a track with no telemetry map yet (Peter 2026-11-01: "ofc iracing has it, why dont you just pull theirs"). Read-only on
# irdashies; no internet, no login. The drawings are iRacing's: data\ is in .gitignore, never push them.
#   powershell -ExecutionPolicy Bypass -File tools\extract-iracing-maps.ps1
$root = Split-Path -Parent $PSScriptRoot
$app = Get-ChildItem "$env:LOCALAPPDATA\irdashies" -Directory -Filter 'app-*' | Sort-Object { [version]($_.Name -replace 'app-', '') } -Descending | Select-Object -First 1
if (-not $app) { 'irdashies is not installed.'; exit 1 }
$asar = Join-Path $app.FullName 'resources\app.asar'
$fs = [IO.File]::OpenRead($asar)
try {
  $b = New-Object byte[] 16; $null = $fs.Read($b, 0, 16)
  $hs = [BitConverter]::ToUInt32($b, 12); $base = [BitConverter]::ToUInt32($b, 4) + 8
  $h = New-Object byte[] $hs; $null = $fs.Read($h, 0, $hs)
  $hdr = [Text.Encoding]::UTF8.GetString($h)
  # the drawings sit in the biggest script of the app
  $big = [regex]::Matches($hdr, '"[^"]+\.js":\{"size":(\d+),"offset":"(\d+)"') | Sort-Object { [long]$_.Groups[1].Value } -Descending | Select-Object -First 1
  $size = [int]$big.Groups[1].Value; $fs.Position = $base + [long]$big.Groups[2].Value
  $buf = New-Object byte[] $size; $got = 0; while ($got -lt $size) { $n = $fs.Read($buf, $got, $size - $got); if ($n -le 0) { break }; $got += $n }
} finally { $fs.Close() }
$s = [Text.Encoding]::UTF8.GetString($buf)
$out = Join-Path $root 'data\iracing-maps'; New-Item -ItemType Directory -Force $out | Out-Null
Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = 50000000
$ci = [Globalization.CultureInfo]::InvariantCulture
$ok = 0; $bad = 0
foreach ($m in [regex]::Matches($s, "(\d+):JSON\.parse\('(\{""active"":(?:[^'\\]|\\.)*)'\)")) {
  $id = $m.Groups[1].Value
  try {
    $o = $ser.DeserializeObject(($m.Groups[2].Value -replace "\\'", "'" -replace '\\\\', '\'))
    $pp = $o['active']['trackPathPoints']; $total = [double]$o['active']['totalLength']
    $sf = [double]$o['startFinish']['point']['length']; $anti = $o['startFinish']['direction'] -eq 'anticlockwise'
    $c = $pp.Count
    if ($c -lt 50 -or $total -le 0) { $bad++; continue }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('{"id":').Append($id).Append(',"length":').Append($total.ToString('0.0', $ci)).Append(',"pts":[')
    for ($i = 0; $i -lt 720; $i++) {
      # the same walk along the drawing irdashies uses to place a car at a lap percentage
      $d = $total * $i / 720.0
      if ($anti) { $l = ($sf + $d) % $total } else { $l = ($sf - $d + $total) % $total }
      $f = $l / $total * ($c - 1); $r = [Math]::Floor($f); $r2 = [Math]::Min($r + 1, $c - 1); $t = $f - $r
      $x = [double]$pp[[int]$r]['x'] + ([double]$pp[[int]$r2]['x'] - [double]$pp[[int]$r]['x']) * $t
      $y = [double]$pp[[int]$r]['y'] + ([double]$pp[[int]$r2]['y'] - [double]$pp[[int]$r]['y']) * $t
      if ($i -gt 0) { [void]$sb.Append(',') }
      [void]$sb.Append('[').Append($x.ToString('0.0', $ci)).Append(',').Append($y.ToString('0.0', $ci)).Append(']')
    }
    [void]$sb.Append(']}')
    [IO.File]::WriteAllText((Join-Path $out "$id.json"), $sb.ToString())
    $ok++
  } catch { $bad++ }
}
"iRacing track drawings saved: $ok (skipped $bad) from irdashies $($app.Name)"
if ($ok -lt 100) { exit 1 }
