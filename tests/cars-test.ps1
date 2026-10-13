# CP-1 CAR PICTURES (dash\src\cars.cs, dash\www\v2\carpics.js, tools\cars-build.ps1, paddock\cars\): iRacing's OWN car pictures, nothing drawn.
#   1. the files: every manifest entry is a real JPEG of a sane size, the key is the CarPath, the source is iRacing's image server, no two files alike
#   2. the mapping of Peter's cars (Corvette Z06 GT3.R, Ferrari 296 GT3, BMW M4 GT3 EVO, BMW M4 G82 GT4 EVO, Toyota GR86): CarPath and CarID read from his
#      own .ibt session text, and the picture really is that car (its colours)
#   3. irdash serves them: /cars/manifest.json, /cars/<key>.jpg, 404 for a car without a picture, no way out of the folder
#   4. the on-demand fetch (sandbox folder, pictures served from this PC): refused while a session is on, done when it is not, kept, no second fetch,
#      refuses addresses that are not iRacing's image server, the real folder is never touched
#   5. the pictures in a browser: a car without a picture shows NOTHING and no broken-image icon, a car with one shows the real file at the right size
#   powershell -ExecutionPolicy Bypass -File tests\cars-test.ps1 [-NoPage]
# Out of the car only (guard.ps1). Sections 3 to 5 need the irdash built from cars.cs (dash\build.ps1).
param([switch]$NoPage)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = if ($env:VAULT_TEST_API) { $env:VAULT_TEST_API } else { 'http://localhost:8199' }
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Note($what) { "  info  $what" }
function Raw($path) {
  try { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 30; $ms = New-Object IO.MemoryStream; $r.RawContentStream.CopyTo($ms); return @{ code = [int]$r.StatusCode; type = [string]$r.Headers['Content-Type']; cache = [string]$r.Headers['Cache-Control']; bytes = $ms.ToArray(); text = [Text.Encoding]::UTF8.GetString($ms.ToArray()) } }
  catch [Net.WebException] { if ($_.Exception.Response) { return @{ code = [int]$_.Exception.Response.StatusCode; type = ''; cache = ''; bytes = @(); text = '' } } return @{ code = 0; type = ''; cache = ''; bytes = @(); text = '' } }
}
function J($path) { $r = Raw $path; if ($r.code -ne 200) { return $null }; return $r.text | ConvertFrom-Json }
function Hash($bytes) { $sha = [Security.Cryptography.SHA256]::Create(); return ([BitConverter]::ToString($sha.ComputeHash([byte[]]$bytes))) }
function Key($p) { return ((("$p").ToLower()) -replace '[^a-z0-9]+', '_').Trim('_') }

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }
$swAll = [Diagnostics.Stopwatch]::StartNew()
Add-Type -AssemblyName System.Drawing
$dir = Join-Path $root 'paddock\cars'
$hook = Join-Path $root 'dash\test-hook.on'; $lock = Join-Path $root 'dash\deploy.lock'
$testDir = Join-Path $root 'paddock\cars-test'
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$hookMade = $false; $lockMade = $false; $script:cdp = $null

# ---- headless Chrome (the same small harness as the other page tests; its own port) ----
function Cdp($method, $params) {
  $c = $script:cdp; $c.id++
  $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $c.id; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
  $null = $c.ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
  while ($true) {
    $buf = New-Object byte[] 262144; $sb = New-Object Text.StringBuilder
    do { $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf); $r = $c.ws.ReceiveAsync($seg, [Threading.CancellationToken]::None); $null = $r.Wait(); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Result.Count)) } while (-not $r.Result.EndOfMessage)
    $o = $sb.ToString() | ConvertFrom-Json
    if ($o.method -eq 'Runtime.exceptionThrown') { $c.errors.Add($o.params.exceptionDetails.exception.description) }
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('cars-test-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9381
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', 'about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  if (-not $page) { throw 'headless Chrome did not start' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0; errors = New-Object System.Collections.Generic.List[string] }
  $null = Cdp 'Page.enable' @{}; $null = Cdp 'Runtime.enable' @{}
  $null = Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $false }
  $null = Cdp 'Page.navigate' @{ url = $url }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return "js error: " + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Json($expr) { return (Cdp-Eval "JSON.stringify($expr)") | ConvertFrom-Json }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
function Wait-Until($js, $sec = 10) { for ($i = 0; $i -lt $sec * 4; $i++) { if ((Cdp-Eval $js) -eq $true) { return $true }; Start-Sleep -Milliseconds 250 }; return $false }

# the session text at the top of a telemetry file: the driver's own CarPath / CarID / CarScreenName
$enc = [Text.Encoding]::GetEncoding(28591)
function Yaml-Of($file) {
  $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
  try { $h = New-Object byte[] 32; [void]$fs.Read($h, 0, 32); $len = [BitConverter]::ToInt32($h, 16); $off = [BitConverter]::ToInt32($h, 20); if ($len -le 0 -or $len -gt 3000000) { return '' }; $b = New-Object byte[] $len; [void]$fs.Seek($off, 'Begin'); [void]$fs.Read($b, 0, $len); return $enc.GetString($b) } finally { $fs.Close() }
}
function Me-Of($y) {
  $idx = [regex]::Match($y, '(?m)^ DriverCarIdx: (\d+)').Groups[1].Value; if ($idx -eq '') { return $null }
  $blk = [regex]::Match($y, "(?s)- CarIdx: $idx\r?\n.*?(?=\r?\n - CarIdx|\r?\n\w)").Value; if (-not $blk) { return $null }
  return @{ path = [regex]::Match($blk, 'CarPath: (.*)').Groups[1].Value.Trim(); id = [int][regex]::Match($blk, 'CarID: (\d+)').Groups[1].Value; name = [regex]::Match($blk, 'CarScreenName: (.*)').Groups[1].Value.Trim() }
}

try {
  # =====================================================================================================
  Section '1. the files and the manifest'
  $man = Get-Content (Join-Path $dir 'manifest.json') -Raw | ConvertFrom-Json
  $cars = @($man.cars); $none = @($man.missing)
  Check "the manifest lists $($cars.Count) cars with a picture and says why $($none.Count) have none; it names iRacing's image server as the source ($($man.source))" ($cars.Count -ge 5 -and $man.source -like '*images-static.iracing.com*')
  $bad = @(); $hashes = @{}; $dims = @()
  foreach ($c in $cars) {
    $f = Join-Path $dir $c.file
    if (-not (Test-Path $f)) { $bad += "$($c.key): no file"; continue }
    $b = [IO.File]::ReadAllBytes($f); $im = [Drawing.Image]::FromFile($f); $w = $im.Width; $h = $im.Height; $im.Dispose()
    $ar = $w / $h
    if ($b.Length -lt 3 -or $b[0] -ne 0xFF -or $b[1] -ne 0xD8 -or $b[2] -ne 0xFF) { $bad += "$($c.key): not a JPEG" }
    if ($w -lt 400 -or $w -gt 2000 -or $h -lt 220 -or $h -gt 1200 -or $ar -lt 1.7 -or $ar -gt 1.85) { $bad += "$($c.key): size ${w}x$h" }
    if ($b.Length -lt 12000 -or $b.Length -gt 400000) { $bad += "$($c.key): $($b.Length) bytes" }
    if ($w -ne $c.width -or $h -ne $c.height -or $b.Length -ne $c.bytes) { $bad += "$($c.key): the manifest says $($c.width)x$($c.height) $($c.bytes) bytes" }
    if ($c.key -cne (Key $c.carpath) -or $c.file -cne ($c.key + '.jpg')) { $bad += "$($c.key): key is not the CarPath '$($c.carpath)'" }
    if ($c.url -notmatch '^https://images-static\.iracing\.com/img/cars/[a-z0-9_]+/[a-z0-9_]+-small\.jpg$') { $bad += "$($c.key): source $($c.url)" }
    if ($null -eq $c.carid -or [int]$c.carid -lt 1) { $bad += "$($c.key): no CarID" }
    $hh = Hash $b; if ($hashes.ContainsKey($hh)) { $bad += "$($c.key) is the same picture as $($hashes[$hh])" } else { $hashes[$hh] = $c.key }
  }
  Check "every manifest entry is a real JPEG file of iRacing's 16:9 size, 12 to 400 KB, with the CarPath as its key, a CarID and an image-server address, as the manifest says ($($bad -join '; '))" ($bad.Count -eq 0 -and $cars.Count -gt 0)
  Check "no two pictures are the same file (no stand-in used for several cars: $($hashes.Count) different pictures for $($cars.Count) cars)" ($hashes.Count -eq $cars.Count)
  $onDisk = @(Get-ChildItem $dir -Filter *.jpg | ForEach-Object { $_.BaseName }); $inMan = @($cars | ForEach-Object { $_.key })
  $fetched = if (Test-Path (Join-Path $dir 'fetched.txt')) { @(Get-Content (Join-Path $dir 'fetched.txt') | ForEach-Object { ($_ -split "`t")[1] }) } else { @() }
  $stray = @($onDisk | Where-Object { $inMan -notcontains $_ -and $fetched -notcontains $_ })
  Check "every picture on disk is in the manifest or in fetched.txt (the later on-demand ones), nothing unaccounted for ($($stray -join ', '))" ($stray.Count -eq 0)
  $noneWithFile = @($none | Where-Object { Test-Path (Join-Path $dir ((Key $_.carpath) + '.jpg')) })
  Check "a car the manifest lists as having NO picture has no file at all ($(@($none | ForEach-Object { $_.carpath }) -join ', '))" ($noneWithFile.Count -eq 0)
  $cat = Get-Content (Join-Path $dir 'catalog.json') -Raw | ConvertFrom-Json; $catBy = @{}; foreach ($e in $cat.cars) { $catBy[$e.key] = $e }
  $catBad = @($cars | Where-Object { -not $catBy.ContainsKey($_.key) -or $catBy[$_.key].url -ne $_.url })
  Check "catalog.json ($(@($cat.cars).Count) cars iRacing's server has a picture for) agrees with the manifest on every address ($(@($catBad | ForEach-Object { $_.key }) -join ', '))" ($catBad.Count -eq 0 -and @($cat.cars).Count -gt 100)
  Check 'the Internet Archive list the file names came from is kept beside the pictures (paddock\cars\source-wayback-list.txt)' ((Get-Item (Join-Path $dir 'source-wayback-list.txt')).Length -gt 5000)

  # =====================================================================================================
  Section "2. Peter's cars: CarPath and CarID from his own .ibt files, and the picture is that car"
  $want = @(
    @{ name = 'Chevrolet Corvette Z06 GT3.R'; path = 'chevyvettez06rgt3'; id = 184; url = 'https://images-static.iracing.com/img/cars/carid_184/chevyvettez06rgt3-small.jpg'; hue = 'yellow' },
    @{ name = 'Ferrari 296 GT3'; path = 'ferrari296gt3'; id = 173; url = 'https://images-static.iracing.com/img/cars/carid_173/ferrari296gt3-small.jpg'; hue = 'red' },
    @{ name = 'BMW M4 GT3 EVO'; path = 'bmwm4gt3'; id = 132; url = 'https://images-static.iracing.com/img/cars/carid_132/bmwm4gt3evo-small.jpg'; hue = '' },
    @{ name = 'BMW M4 G82 GT4 EVO'; path = 'bmwm4evogt4'; id = 189; url = 'https://images-static.iracing.com/img/cars/carid_189/bmwm4evogt4-small.jpg'; hue = '' },
    @{ name = 'Toyota GR86'; path = 'toyotagr86'; id = 160; url = 'https://images-static.iracing.com/img/cars/toyotagr86/toyotagr86-small.jpg'; hue = '' })
  $seen = @{}
  foreach ($f in (Get-ChildItem $tel -Filter *.ibt | Sort-Object LastWriteTime -Descending)) {
    $m = Me-Of (Yaml-Of $f.FullName); if (-not $m) { continue }
    if (-not $seen.ContainsKey($m.name)) { $seen[$m.name] = $m; $seen[$m.name].file = $f.Name }
  }
  foreach ($w in $want) {
    $m = $seen[$w.name]; $e = @($cars | Where-Object { $_.carpath -ceq $w.path })[0]
    Check "$($w.name): his own telemetry file ($($m.file)) says CarPath '$($m.path)', CarID $($m.id); that is $($w.path) / $($w.id)" ($m -and $m.path -ceq $w.path -and $m.id -eq $w.id)
    Check "$($w.name): the manifest maps $($w.path) / CarID $($w.id) to $($w.url) and the file is there" ($e -and $e.carid -eq $w.id -and $e.url -ceq $w.url -and (Test-Path (Join-Path $dir "$($w.path).jpg")))
    if ($w.hue) {          # the car in the picture is the right one: the Corvette is yellow, the Ferrari red (the middle of the car, not the floor)
      $bmp = New-Object Drawing.Bitmap (Join-Path $dir "$($w.path).jpg"); $r = 0; $g = 0; $b = 0; $n = 0
      for ($x = [int]($bmp.Width * 0.30); $x -lt [int]($bmp.Width * 0.70); $x += 3) { for ($y = [int]($bmp.Height * 0.42); $y -lt [int]($bmp.Height * 0.70); $y += 3) { $p = $bmp.GetPixel($x, $y); if (($p.R + $p.G + $p.B) -gt 150 -and ($p.R + $p.G + $p.B) -lt 700) { $r += $p.R; $g += $p.G; $b += $p.B; $n++ } } }
      $bmp.Dispose(); $r = $r / [math]::Max(1, $n); $g = $g / [math]::Max(1, $n); $b = $b / [math]::Max(1, $n)
      $isHue = if ($w.hue -eq 'yellow') { $r -gt $b + 40 -and $g -gt $b + 25 } else { $r -gt $g + 40 -and $r -gt $b + 40 }
      Check "$($w.name): the picture's own colours are $($w.hue) (mean of the car body: R $([math]::Round($r)) G $([math]::Round($g)) B $([math]::Round($b)))" $isHue
    }
  }
  # every car in his telemetry is either in the manifest or listed as having no picture
  $all = @{}
  foreach ($f in (Get-ChildItem $tel -Filter *.ibt)) {
    $y = Yaml-Of $f.FullName
    foreach ($m in [regex]::Matches($y, '(?s)- CarIdx: \d+.*?CarID: (\d+).*?(?=\r?\n - CarIdx|\r?\n\w)')) { $p = [regex]::Match($m.Value, 'CarPath: (.*)').Groups[1].Value.Trim(); if ($p) { $all[(Key $p)] = $p } }
  }
  # Every car (his own and the other drivers in a session) lands in one of three honest places: a picture on disk (the manifest's or one fetched later,
  # fetched.txt), a picture iRacing's server has that the page fetches the first time the car is shown (it is in catalog.json), or NO picture to be had
  # (not in catalog.json: a retired car such as the Mercedes AMG GT3 before the 2020 EVO). For the last group the server must say so, without fetching anything.
  $pic = @($all.Keys | Where-Object { $onDisk -contains $_ }); $later = @($all.Keys | Where-Object { $onDisk -notcontains $_ -and $catBy.ContainsKey($_) }); $nothing = @($all.Keys | Where-Object { $onDisk -notcontains $_ -and -not $catBy.ContainsKey($_) })
  $badAsk = @(); foreach ($k in $nothing) { $a = J "/cars/need?path=$([uri]::EscapeDataString($all[$k]))"; if (-not $a -or $a.have -or $a.queued -or $a.why -notmatch 'no picture') { $badAsk += $k } }
  Check "all $($all.Count) cars that appear in his telemetry files are accounted for: $($pic.Count) with a picture, $($later.Count) fetched when first shown, $($nothing.Count) with none to be had and the server says so ($($badAsk -join ', '))" ($badAsk.Count -eq 0 -and $all.Count -ge 10 -and ($pic.Count + $later.Count + $nothing.Count) -eq $all.Count)

  # =====================================================================================================
  Section '3. irdash serves the pictures'
  $st = Raw '/cars/status'
  if ($st.code -ne 200) { Note "SKIPPED sections 3 to 5: the running irdash has no /cars routes yet (answer $($st.code)). Deploy with dash\build.ps1 when the sim is off, then run this test again." }
  else {
    $mj = J '/cars/manifest.json'
    $ordDisk = [string[]]@($onDisk); [array]::Sort($ordDisk, [StringComparer]::Ordinal)
    Check "/cars/manifest.json lists exactly the pictures on disk ($(@($mj.keys).Count) keys)" ((@($mj.keys) -join ',') -ceq ($ordDisk -join ','))
    $badServe = @()
    foreach ($c in $cars) {
      $r = Raw "/cars/$($c.key).jpg"; $disk = [IO.File]::ReadAllBytes((Join-Path $dir $c.file))
      if ($r.code -ne 200 -or $r.type -notlike 'image/jpeg*' -or (Hash $r.bytes) -ne (Hash $disk)) { $badServe += "$($c.key): $($r.code) $($r.type)" }
    }
    Check "every picture is served as image/jpeg and is byte for byte the file on disk ($($badServe -join '; '))" ($badServe.Count -eq 0)
    $one = Raw "/cars/$($cars[0].key).jpg"
    Check "pictures may be cached by the browser ($($one.cache))" ($one.cache -like '*max-age*')
    $c404 = @('/cars/unknowncar99.jpg', '/cars/safety_pcsedan.jpg', '/cars/..%2f..%2firdash.ini', '/cars/%2e%2e/irdash.ini', '/cars/CHEVYVETTEZ06RGT3.jpg', '/cars/manifest.jpg') | ForEach-Object { "$_ " + (Raw $_).code }
    Check "a car without a picture, a path out of the folder and an upper-case key all answer 404 ($($c404 -join '; '))" (@($c404 | Where-Object { $_ -notmatch ' 404$' }).Count -eq 0)
    $nd = J '/cars/need?path=chevyvettez06rgt3'
    Check "asking for a car that has its picture answers have=true and does not fetch anything ($($nd | ConvertTo-Json -Compress))" ($nd.have -eq $true -and $nd.queued -eq $false -and $nd.key -eq 'chevyvettez06rgt3')

    # =====================================================================================================
    Section '4. the on-demand fetch: never during a session, kept for good (sandbox folder paddock\cars-test, pictures from this PC)'
    Enter-TestLock 'cars'
    for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { Write-Host ('  waiting for the deploy lock (' + (Get-Content $lock) + ')'); Start-Sleep -Seconds 30 }
    Assert-RigFree -Where 'before the fetch part'
    Set-Content $lock ('cars-test ' + (Get-Date).ToString('HH:mm:ss')); $lockMade = $true
    Set-Content $hook 'on for the test'; $hookMade = $true
    Start-Sleep -Milliseconds 400
    $realBefore = (Get-ChildItem $dir | Sort-Object Name | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
    New-Item -ItemType Directory -Force $testDir | Out-Null
    # the "image server" of this test is irdash itself: three real pictures are copied into the sandbox folder under other names and the catalog points at them
    Copy-Item (Join-Path $dir 'chevyvettez06rgt3.jpg') (Join-Path $testDir 'srcpic_a.jpg'); Copy-Item (Join-Path $dir 'ferrari296gt3.jpg') (Join-Path $testDir 'srcpic_b.jpg'); Copy-Item (Join-Path $dir 'toyotagr86.jpg') (Join-Path $testDir 'srcpic_c.jpg')
    $entries = @(('testcar_one|' + $api + '/cars/srcpic_a.jpg'), ('testcar_two|' + $api + '/cars/srcpic_b.jpg'), ('mx5_mx52016|' + $api + '/cars/srcpic_c.jpg'), 'badhost|https://example.com/x.jpg')
    $rows = @(); foreach ($en in $entries) { $p = $en -split '\|'; $rows += ('{"key":"' + $p[0] + '","carid":null,"url":"' + $p[1] + '"}') }
    $catJson = '{"cars":[' + ($rows -join ',') + ']}'
    [IO.File]::WriteAllText((Join-Path $testDir 'catalog.json'), $catJson, (New-Object Text.UTF8Encoding($false)))
    $sb0 = J '/api/test/cars?sandbox=1'
    Check "the test hook switches the pictures to the sandbox folder ($($sb0 | ConvertTo-Json -Compress))" ($sb0.sandbox -eq $true -and $sb0.catalog -eq 4 -and $sb0.have -eq 3)
    # a pretend session is on: nothing may be fetched
    $null = Raw '/api/test/frame?SessionTime=100&IsOnTrack=0'; Start-Sleep -Milliseconds 600
    $n1 = J '/cars/need?path=testcar_one'; Start-Sleep -Seconds 4
    $s1 = J '/cars/status'
    Check "while a session is on (the test hook's pretend session) a car with a catalog entry is NOT fetched: need says queued=false ('$($n1.why)'), refused=$($s1.refused), busy='$($s1.busy)', nothing in the folder" ($n1.queued -eq $false -and $n1.why -like 'not now*' -and $s1.refused -ge 1 -and $s1.busy -and -not (Test-Path (Join-Path $testDir 'testcar_one.jpg')) -and $s1.fetched -eq 0)
    $null = Raw '/api/test/end'; Start-Sleep -Milliseconds 800
    $n2 = J '/cars/need?path=testcar_one'
    $got = $false; for ($i = 0; $i -lt 40 -and -not $got; $i++) { Start-Sleep -Milliseconds 250; $got = Test-Path (Join-Path $testDir 'testcar_one.jpg') }
    $s2 = J '/cars/status'
    $fb = if ($got) { [IO.File]::ReadAllBytes((Join-Path $testDir 'testcar_one.jpg')) } else { @() }
    Check "with no session on, the same car is fetched in the background (queued=$($n2.queued)) and kept as a real JPEG identical to its source ($($fb.Length) bytes, fetched=$($s2.fetched))" ($n2.queued -eq $true -and $got -and $fb.Length -gt 12000 -and $fb[0] -eq 0xFF -and $fb[1] -eq 0xD8 -and (Hash $fb) -eq (Hash ([IO.File]::ReadAllBytes((Join-Path $dir 'chevyvettez06rgt3.jpg')))) -and $s2.fetched -eq 1)
    $ft = if (Test-Path (Join-Path $testDir 'fetched.txt')) { Get-Content (Join-Path $testDir 'fetched.txt') } else { '' }
    Check "the fetch is written down with its source ($(@($ft)[0]))" (@($ft)[0] -like '*testcar_one*http://*')
    $mjT = J '/cars/manifest.json'
    Check 'the sandbox manifest lists the new picture, and /cars/testcar_one.jpg serves it' (@($mjT.keys) -contains 'testcar_one' -and (Raw '/cars/testcar_one.jpg').code -eq 200)
    $n3 = J '/cars/need?path=testcar_one'; Start-Sleep -Seconds 1; $s3 = J '/cars/status'
    Check "asking again is answered have=true and fetches nothing more (fetched stays $($s3.fetched))" ($n3.have -eq $true -and $s3.fetched -eq 1)
    $n4 = J '/cars/need?path=nocatalogcar99'; Start-Sleep -Milliseconds 800
    Check "a car iRacing's list has no picture for: no fetch, the answer says so ('$($n4.why)'), no file" ($n4.queued -eq $false -and $n4.have -eq $false -and $n4.why -like '*no picture*' -and -not (Test-Path (Join-Path $testDir 'nocatalogcar99.jpg')))
    $n5 = J '/cars/need?path=badhost'; Start-Sleep -Seconds 3; $s5 = J '/cars/status'
    Check "an address that is not iRacing's image server is refused ($($s5.why)): failed=$($s5.failed), no file" ($n5.queued -eq $true -and $s5.failed -ge 1 -and $s5.why -like '*not allowed*' -and -not (Test-Path (Join-Path $testDir 'badhost.jpg')))
    $n6 = J ('/cars/need?path=' + [uri]::EscapeDataString('MX5 mx52016'))
    $got6 = $false; for ($i = 0; $i -lt 40 -and -not $got6; $i++) { Start-Sleep -Milliseconds 250; $got6 = Test-Path (Join-Path $testDir 'mx5_mx52016.jpg') }
    Check "a CarPath with a space ('MX5 mx52016') becomes the key mx5_mx52016 and is fetched under it ($($n6.key))" ($n6.key -eq 'mx5_mx52016' -and $got6)
    $realAfter = (Get-ChildItem $dir | Sort-Object Name | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
    Check 'the real folder paddock\cars was not touched by any of this (same files, sizes and times)' ($realBefore -ceq $realAfter)
    $null = J '/api/test/cars?sandbox=0'
    Check 'the sandbox is switched off again: the manifest is the real one' ((@((J '/cars/manifest.json').keys) -join ',') -ceq (@($mj.keys) -join ','))
    Remove-Item $hook -Force -ErrorAction SilentlyContinue; $hookMade = $false
    Check 'without the test hook file /api/test/cars does not exist (404)' ((Raw '/api/test/cars?sandbox=1').code -in 404, 409)
    Remove-Item $lock -Force -ErrorAction SilentlyContinue; $lockMade = $false
    Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue

    # =====================================================================================================
    Section '5. in a browser: a car with a picture shows the real file, a car without one shows nothing'
    if ($NoPage) { Note 'skipped (-NoPage)' }
    else {
      Cdp-Open "$api/v2/"
      $ready = Wait-Until "!!window.PCarPic && !!PCarPic.known()" 20
      Check 'carpics.js is on the page and has read the list of pictures' $ready
      $js = @'
(function () {
  var K = PCarPic.known(), box = document.createElement('div'); box.id = 'cpTest'; box.style.cssText = 'position:fixed;left:40px;top:40px;z-index:9999;background:#060606;padding:20px;display:flex;gap:20px;align-items:center';
  var withPic = PCarPic.html({ path: 'chevyvettez06rgt3', w: 64, title: 'Corvette' }), none = PCarPic.html({ path: 'unknowncar99', w: 64 }), blank = PCarPic.html({ path: '', w: 64 }), old = PCarPic.html({ w: 64 });
  box.innerHTML = '<span>[</span>' + withPic + '<span>]</span><span>[</span>' + none + '<span>]</span>' + PCarPic.html({ path: 'ferrari296gt3', w: 210 });
  document.body.appendChild(box);
  return { n: Object.keys(K).length, withPic: withPic.indexOf('<img') > 0, none: none, blank: blank, old: old, frames: box.querySelectorAll('.cpic').length };
})()
'@
      $probe = Cdp-Json $js
      Check "the page knows every picture on disk, the manifest's and the ones fetched later ($($probe.n)); for a car without one PCarPic.html gives '' ('$($probe.none)'), for no CarPath at all too ('$($probe.blank)' '$($probe.old)'), for a car with one a frame with a real img" ($probe.n -eq @(Get-ChildItem $dir -Filter *.jpg).Count -and $probe.none -eq '' -and $probe.blank -eq '' -and $probe.old -eq '' -and $probe.withPic -and $probe.frames -eq 2)
      $js = @'
[].every.call(document.querySelectorAll('#cpTest img'), function (i) { return i.complete && i.naturalWidth > 0; }) && document.querySelectorAll('#cpTest img').length === 2
'@
      $loaded = Wait-Until $js 10
      $js = @'
[].map.call(document.querySelectorAll('#cpTest .cpic'), function (f) { var i = f.querySelector('img'), r = f.getBoundingClientRect(), ir = i.getBoundingClientRect(), cs = getComputedStyle(f); return { w: r.width, h: r.height, nat: i.naturalWidth, natH: i.naturalHeight, src: i.getAttribute('src'), imgW: ir.width, radius: cs.borderTopLeftRadius, k: f.getAttribute('data-k') }; })
'@
      $pi = Cdp-Json $js
      Check "the pictures are loaded from iRacing's files (naturalWidth $($pi[0].nat) x $($pi[0].natH), /cars/chevyvettez06rgt3.jpg) and drawn in a $([math]::Round($pi[0].w)) x $([math]::Round($pi[0].h)) frame (2.75 : 1) and a $([math]::Round($pi[1].w)) x $([math]::Round($pi[1].h)) one" ($loaded -and $pi[0].nat -eq 480 -and $pi[0].natH -eq 270 -and $pi[0].src -eq '/cars/chevyvettez06rgt3.jpg' -and [math]::Abs($pi[0].w - 64) -lt 0.6 -and [math]::Abs($pi[0].h - 23.3) -lt 0.8 -and [math]::Abs($pi[1].w - 210) -lt 0.6 -and [math]::Abs($pi[1].h - 76.4) -lt 1 -and $pi[0].imgW -gt 64 -and $pi[0].radius -ne '0px')
      # frames that were drawn before the list was read: refresh() fills those that have a picture and removes the rest
      $js = @'
(function () {
  var d = document.createElement('div'); d.id = 'cpRf';
  d.innerHTML = '<div class="cpic" data-k="bmwm4evogt4" data-p="bmwm4evogt4" style="width:64px;height:23px"></div><div class="cpic" data-k="unknowncar99" data-p="unknowncar99" style="width:64px;height:23px"></div>';
  document.body.appendChild(d); PCarPic.refresh();
  return { frames: d.querySelectorAll('.cpic').length, imgs: d.querySelectorAll('img').length, k: d.querySelector('.cpic') ? d.querySelector('.cpic').getAttribute('data-k') : '' };
})()
'@
      $rf = Cdp-Json $js
      Check "refresh() puts the picture into the empty frame of a car that has one and removes the frame of a car that has none ($($rf.frames) frame left, key $($rf.k))" ($rf.frames -eq 1 -and $rf.imgs -eq 1 -and $rf.k -eq 'bmwm4evogt4')
      # a picture that cannot be loaded takes its frame away: no broken-image icon
      $js = @'
(function () { var d = document.createElement('div'); d.id = 'cpBr'; d.innerHTML = PCarPic.html({ path: 'toyotagr86', w: 64 }); document.body.appendChild(d); d.querySelector('img').src = '/cars/nope_nope.jpg'; return true; })()
'@
      $null = Cdp-Json $js
      Start-Sleep -Milliseconds 800
      $js = @'
({ frames: document.querySelectorAll('#cpBr .cpic').length, broken: [].filter.call(document.querySelectorAll('img'), function (i) { return i.complete && i.naturalWidth === 0; }).length })
'@
      $brn = Cdp-Json $js
      Check "a picture that fails to load removes its frame: no broken-image icon on the page (frames $($brn.frames), broken images $($brn.broken))" ($brn.frames -eq 0 -and $brn.broken -eq 0)
      $js = @'
performance.getEntriesByType('resource').filter(function (e) { return e.name.indexOf('unknowncar99.jpg') >= 0; }).length
'@
      Check 'the browser asked for no picture of a car without one (no request for /cars/unknowncar99.jpg)' ((Cdp-Eval $js) -eq 0)
      Cdp-Shot (Join-Path $shots 'cars-frames.png')
      Check 'no JavaScript error on the page' ($script:cdp.errors.Count -eq 0)
      Cdp-Close
    }
  }
} finally {
  try { [void](Raw '/api/test/end') } catch { }
  try { [void](Raw '/api/test/cars?sandbox=0') } catch { }
  try { if ($script:cdp) { Cdp-Close } } catch { }
  if ($hookMade) { Remove-Item $hook -Force -ErrorAction SilentlyContinue }
  if ($lockMade) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
  Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
  Exit-TestLock
}
"cars-test: $pass passed, $fail failed. Picture in $shots (cars-frames.png). $([math]::Round($swAll.Elapsed.TotalSeconds, 0)) s"
if ($fail -gt 0) { exit 1 }
