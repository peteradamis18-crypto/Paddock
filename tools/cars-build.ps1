# CP-1: builds paddock\cars\ - iRacing's OWN car pictures (the 480x270 "small" image iRacing's UI and website show for each car).
#   powershell -ExecutionPolicy Bypass -File tools\cars-build.ps1            (catalog + download what Peter's data needs)
#   powershell -ExecutionPolicy Bypass -File tools\cars-build.ps1 -CatalogOnly
# Source: https://images-static.iracing.com/img/cars/<folder>/<name>-small.jpg  ("folder" = carid_<CarID> for newer cars, the old
# folder name for older ones). The file names come from the Internet Archive's list of that server (paddock\cars\source-wayback-list.txt;
# iRacing's own /data/car/assets JSON needs a member login and is closed to new apps). Every file is checked with a real request.
# Politeness: one file at a time, 1.5 s apart. Never while the sim runs or a START key was pressed (tests\guard.ps1).
param([switch]$CatalogOnly, [string]$Only = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\guard.ps1')
Add-Type -AssemblyName System.Drawing
$dir = Join-Path $root 'paddock\cars'
New-Item -ItemType Directory -Force $dir | Out-Null
$base = 'https://images-static.iracing.com/img/cars/'
function Key($p) { return ((("$p").ToLower()) -replace '[^a-z0-9]+', '_').Trim('_') }

# ---- 1. the catalog: key (= iRacing CarPath, lower case) -> picture URL, from the archived file list ----
$list = Join-Path $dir 'source-wayback-list.txt'
$cat = @{}; $dup = @{}
foreach ($ln in (Get-Content $list)) {
  $u = ($ln -split '\s+')[0]
  if ($u -notmatch '^https://images-static\.iracing\.com/img/cars/([^/]+)/([^/]+?)[-_]small\.jpg$') { continue }
  $folder = $Matches[1].ToLower(); $name = $Matches[2].ToLower(); $carid = $null
  if ($folder -match '^carid_(\d+)$') { $carid = [int]$Matches[1]; $k = Key $name } else { $k = Key $folder }
  if ($cat.ContainsKey($k)) { $dup[$k] = 1; continue }
  $cat[$k] = [pscustomobject]@{ key = $k; carid = $carid; url = $u }
}
foreach ($k in $dup.Keys) { $cat.Remove($k) }           # two cars share the name (street stock bodies, formula vee bodies): no guess
# CarPaths whose picture has another name - each one read from Peter's own session text (CarID + CarPath + CarScreenName) and the picture checked by eye
$alias = @{
  'bmwm4gt3'          = 'bmwm4gt3evo'                    # CarID 132, BMW M4 GT3 EVO
  'lamborghinievogt3' = 'lamborghinihuracangt3evo'       # CarID 133, Lamborghini Huracan GT3 EVO
  'porsche991rsr'     = 'porsche911rsr'                  # CarID 102, Porsche 991 RSR (iRacing's "Porsche 911 RSR")
}
foreach ($a in $alias.Keys) { if ($cat.ContainsKey($alias[$a]) -and -not $cat.ContainsKey($a)) { $c = $cat[$alias[$a]]; $cat[$a] = [pscustomobject]@{ key = $a; carid = $c.carid; url = $c.url } } }
$lines = foreach ($k in ($cat.Keys | Sort-Object)) { $c = $cat[$k]; '{"key":"' + $k + '","carid":' + $(if ($null -ne $c.carid) { $c.carid } else { 'null' }) + ',"url":"' + $c.url + '"}' }
$json = "{`"source`":`"images-static.iracing.com (iRacing's public image server), file names from the Internet Archive list`",`"cars`":[`n" + ($lines -join ",`n") + "`n]}"
[IO.File]::WriteAllText((Join-Path $dir 'catalog.json'), $json, (New-Object Text.UTF8Encoding($false)))
"catalog: $($cat.Count) cars with a known picture ($($dup.Count) ambiguous names left out)"
if ($CatalogOnly) { return }

# ---- 2. the cars Peter's data has: every driver's CarID / CarPath / CarScreenName in every telemetry file's session text, and every race log ----
Assert-RigFree
$enc = [Text.Encoding]::GetEncoding(28591); $seen = @{}
$tdir = Join-Path $env:USERPROFILE 'OneDrive\Documents\iRacing\telemetry'
if (-not (Test-Path $tdir)) { $tdir = Join-Path $env:USERPROFILE 'Documents\iRacing\telemetry' }
foreach ($f in (Get-ChildItem $tdir -Filter *.ibt -ErrorAction SilentlyContinue)) {
  $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
  try {
    $h = New-Object byte[] 32; [void]$fs.Read($h, 0, 32)
    $len = [BitConverter]::ToInt32($h, 16); $off = [BitConverter]::ToInt32($h, 20)
    if ($len -le 0 -or $len -gt 3000000) { continue }
    $b = New-Object byte[] $len; [void]$fs.Seek($off, 'Begin'); [void]$fs.Read($b, 0, $len)
    $y = $enc.GetString($b)
    foreach ($m in [regex]::Matches($y, '(?s)- CarIdx: \d+.*?CarID: (\d+).*?(?=\r?\n - CarIdx|\r?\n\w)')) {
      $blk = $m.Value; $p = [regex]::Match($blk, 'CarPath: (.*)').Groups[1].Value.Trim(); $n = [regex]::Match($blk, 'CarScreenName: (.*)').Groups[1].Value.Trim()
      if ($p -and -not $seen.ContainsKey((Key $p))) { $seen[(Key $p)] = [pscustomobject]@{ carpath = $p; key = (Key $p); carid = [int]$m.Groups[1].Value; name = $n } }
    }
  } finally { $fs.Close() }
}
foreach ($f in (Get-ChildItem (Join-Path $root 'vault\field') -Filter f*.json -ErrorAction SilentlyContinue)) {   # race logs: the car paths only
  foreach ($m in [regex]::Matches([IO.File]::ReadAllText($f.FullName), '"path":"([^"]+)"')) { $p = $m.Groups[1].Value; if (-not $seen.ContainsKey((Key $p))) { $seen[(Key $p)] = [pscustomobject]@{ carpath = $p; key = (Key $p); carid = $null; name = '' } } }
}
"cars in Peter's data: $($seen.Count)"

# ---- 3. download what is missing, one at a time ----
$cars = @(); $missing = @()
foreach ($c in ($seen.Values | Sort-Object key)) {
  if ($Only -and $c.key -ne $Only) { continue }
  $e = $cat[$c.key]
  if (-not $e) { $missing += [pscustomobject]@{ carpath = $c.carpath; carid = $c.carid; name = $c.name; why = 'no picture on iRacing''s image server list' }; continue }
  $file = Join-Path $dir ($c.key + '.jpg')
  if (-not (Test-Path $file)) {
    Assert-RigFree -Where "download $($c.key)"
    try { Invoke-WebRequest -Uri $e.url -OutFile $file -UseBasicParsing -TimeoutSec 30 } catch { $missing += [pscustomobject]@{ carpath = $c.carpath; carid = $c.carid; name = $c.name; why = "download failed: $($_.Exception.Message)" }; if (Test-Path $file) { Remove-Item $file }; continue }
    Start-Sleep -Milliseconds 1500
  }
  $bytes = [IO.File]::ReadAllBytes($file); $w = 0; $hh = 0
  if ($bytes.Length -gt 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) { $im = [Drawing.Image]::FromFile($file); $w = $im.Width; $hh = $im.Height; $im.Dispose() }
  if ($w -lt 300 -or $bytes.Length -lt 8000) { $missing += [pscustomobject]@{ carpath = $c.carpath; carid = $c.carid; name = $c.name; why = 'not a usable JPEG'; }; Remove-Item $file; continue }
  $cars += [pscustomobject]@{ key = $c.key; carpath = $c.carpath; carid = $c.carid; name = $c.name; url = $e.url; file = ($c.key + '.jpg'); width = $w; height = $hh; bytes = $bytes.Length }
}
if (-not $Only) {
  $m = [ordered]@{ source = "iRacing's public image server images-static.iracing.com (the 'small' car picture iRacing's own UI shows); iRacing's images, not recoloured"; fetched = (Get-Date -Format 'yyyy-MM-dd'); cars = $cars; missing = $missing }
  [IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), ($m | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}
"downloaded / present: $($cars.Count); without a picture: $($missing.Count)"
$missing | ForEach-Object { "  none: $($_.carpath) ($($_.name)) - $($_.why)" }
