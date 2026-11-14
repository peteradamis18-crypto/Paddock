# design-lint-test.ps1 - offline, a few seconds: the design rules, checked by reading the files.
#   1. no colour literal (#hex, rgb(), rgba(), hsl()) outside dash\www\app\design.css, in dash\www\app and on the converted list
#   2. no font-size under 24 px on a seat page or under 20 px on a lean-in page (px / rem / em; 1 rem = 16 px; var(--t-*) is looked up)
#   3. no second :root block in dash\www\app or on the converted list
#   powershell -ExecutionPolicy Bypass -File tests\design-lint-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot

# ---- ADD A PAGE HERE THE DAY IT IS CONVERTED (relative to the repo root) ----
# every file of a converted page (html, css, js); the lint holds them to rules 1-3
# (everything under dash\www\app is checked anyway: the shell, its pages and libs, W3-1)
$converted = @('dash/www/v2/race.html', 'dash/www/v2/race.css')
# seat pages (read from the driver's seat, nothing under 24 px) and lean-in pages (nothing under 20 px)
$seat = @('dash/www/v2/race.html', 'dash/www/v2/race.css', 'dash/www/app/pages/race.js',
  'dash/www/app/index.html', 'dash/www/app/shell.css', 'dash/www/app/shell.js', 'dash/www/app/pages/races.js', 'dash/www/app/pages/races.css',
  'dash/www/app/pages/home.js', 'dash/www/app/pages/review.js', 'dash/www/app/pages/rig.js')
$seat += @('dash/www/app/pages/home.css')   # W3-3: HOME's files
$seat += @('dash/www/app/pages/review.css')   # W4-3: REVIEW's card
$seat += @('dash/www/app/pages/review-laps.js', 'dash/www/app/pages/review-laps.css')   # W4-4: REVIEW screen 2
$leanIn = @()
# ------------------------------------------------------------------------------
$designCss = 'dash/www/app/design.css'

function Strip-Comments([string]$t, [string]$ext) {
  $t = [regex]::Replace($t, '(?s)/\*.*?\*/', { param($m) ($m.Value -replace '[^\r\n]', ' ') })
  if ($ext -eq '.js') { $t = [regex]::Replace($t, '(?m)(^|[^:"''\\])//.*$', '$1') }
  if ($ext -eq '.html') { $t = [regex]::Replace($t, '(?s)<!--.*?-->', { param($m) ($m.Value -replace '[^\r\n]', ' ') }) }
  return $t
}
function Read-Rel([string]$rel) { [IO.File]::ReadAllText((Join-Path $root ($rel -replace '/', '\'))) }

$files = @{}
Get-ChildItem (Join-Path $root 'dash\www\app') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.css', '.js', '.html' } | ForEach-Object {
  $files[$_.FullName.Substring($root.Length + 1).Replace('\', '/')] = $true }
foreach ($c in $converted) { $files[$c] = $true }
$files.Remove($designCss)

$pass = 0; $fail = 0
function Ok($what) { $script:pass++; "  ok    $what" }
function Bad($what) { $script:fail++; "  FAIL  $what" }

# token sizes from design.css, so var(--t-body) can be checked like a number
$tok = @{}
foreach ($m in [regex]::Matches((Read-Rel $designCss), '--(t-[a-z]+)\s*:\s*([\d.]+)px')) { $tok[$m.Groups[1].Value] = [double]$m.Groups[2].Value }

'design lint test'
Assert-RigFree -Where '1. colours'
Ok ("design.css gives " + $tok.Count + " type sizes, checking " + $files.Count + " files")
$colorRx = '(?i)(#[0-9a-f]{3,8}\b|\brgba?\s*\(|\bhsla?\s*\()'
foreach ($rel in ($files.Keys | Sort-Object)) {
  $path = Join-Path $root ($rel -replace '/', '\')
  if (-not (Test-Path $path)) { Bad "$rel is on the converted list but does not exist"; continue }
  $ext = [IO.Path]::GetExtension($rel).ToLower()
  $t = Strip-Comments (Read-Rel $rel) $ext
  # an id selector or an href="#x" anchor is not a colour: only look where a colour can be written
  $hits = @()
  foreach ($m in [regex]::Matches($t, $colorRx)) {
    $v = $m.Value
    if ($v.StartsWith('#')) {
      # a hex word right after a colon / comma / bracket / quote is a value; "#list {" at a selector position is an id
      $line = $t.Substring(0, $m.Index).Split("`n")[-1]
      $isValue = ($line -match ':[^{};]*$') -or ($line -match "['""(,]\s*$")
      if (-not $isValue) { continue }
    }
    $hits += $v
  }
  if ($hits.Count) { Bad ("$rel has a colour literal: " + (($hits | Select-Object -Unique) -join ' ')) } else { Ok "$rel has no colour literal" }
}

Assert-RigFree -Where '2. font sizes'
function Min-Px([string]$t, [double]$min, [string]$rel) {
  $bad = @()
  foreach ($m in [regex]::Matches($t, '(?i)font-size\s*:\s*([^;}"'']+)')) {
    $v = $m.Groups[1].Value.Trim()
    $px = $null
    if ($v -match '^var\(--(t-[a-z]+)') { if ($tok.ContainsKey($Matches[1])) { $px = $tok[$Matches[1]] } else { $bad += "$v (unknown token)"; continue } }
    elseif ($v -match '^([\d.]+)\s*px') { $px = [double]$Matches[1] }
    elseif ($v -match '^([\d.]+)\s*r?em') { $px = [double]$Matches[1] * 16 }
    elseif ($v -match '^[\d.]+\s*%') { $bad += "$v (percent sizes are not allowed on converted pages)"; continue }
    if ($null -ne $px -and $px -lt $min) { $bad += "$v = $px px" }
  }
  return $bad
}
foreach ($rel in $seat) {
  $t = Strip-Comments (Read-Rel $rel) ([IO.Path]::GetExtension($rel).ToLower())
  $b = @(Min-Px $t 24 $rel)
  if ($b.Count) { Bad "$rel (seat page) has text under 24 px: $($b -join '; ')" } else { Ok "$rel (seat page) has nothing under 24 px" }
}
foreach ($rel in $leanIn) {
  $t = Strip-Comments (Read-Rel $rel) ([IO.Path]::GetExtension($rel).ToLower())
  $b = @(Min-Px $t 20 $rel)
  if ($b.Count) { Bad "$rel (lean-in page) has text under 20 px: $($b -join '; ')" } else { Ok "$rel (lean-in page) has nothing under 20 px" }
}
if (-not $leanIn.Count) { Ok 'no lean-in page is converted yet (list is empty)' }

Assert-RigFree -Where '3. one :root'
foreach ($rel in ($files.Keys | Sort-Object)) {
  $t = Strip-Comments (Read-Rel $rel) ([IO.Path]::GetExtension($rel).ToLower())
  $n = [regex]::Matches($t, '(?m):root\s*\{').Count
  if ($n -gt 0) { Bad "$rel has its own :root (only design.css may)" }
}
$dc = Strip-Comments (Read-Rel $designCss) '.css'
$plain = [regex]::Matches($dc, '(?m)(^|[\s,}]):root\s*\{').Count
if ($plain -eq 1) { Ok 'design.css has exactly one plain :root block (plus the data-gold override)' } else { Bad "design.css has $plain plain :root blocks" }
if ($fail -eq 0) { Ok 'no other file has a :root' }

# the lint must actually bite: feed it bad text and see it complain
Assert-RigFree -Where '4. the lint bites'
$sample = 'p { color: #abc; font-size: 18px; } q { background: rgba(1,2,3,.5); }'
if ([regex]::Matches($sample, $colorRx).Count -ge 2) { Ok 'sample with #abc and rgba( is caught' } else { Bad 'colour lint missed the sample' }
if ((Min-Px $sample 24 'x').Count -eq 1 -and (Min-Px 'a { font-size: 1.25rem }' 24 'x').Count -eq 1 -and (Min-Px 'a { font-size: var(--t-label) }' 24 'x').Count -eq 1 -and (Min-Px 'a { font-size: var(--t-body) }' 24 'x').Count -eq 0) { Ok 'small sizes in px, rem and tokens are caught' } else { Bad 'size lint missed a case' }

"$pass passed, $fail failed."
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
