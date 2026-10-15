# trackmap-test.ps1 - the map never blocks or lies (PX-05): /trackmap answers from cache, or 202 "building", fast,
# while the background builder works. Needs the current irdash on port 8199 (dash\build.ps1). Reads no telemetry itself.
#   powershell -ExecutionPolicy Bypass -File tests\trackmap-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
$script:pass = 0; $script:fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Section($t) { Assert-RigFree -Where $t; $t }
$root = Split-Path -Parent $PSScriptRoot
$api = 'http://localhost:8199'
function Get-Map($q) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { $r = Invoke-WebRequest -UseBasicParsing "$api/trackmap?$q" -TimeoutSec 30; $code = [int]$r.StatusCode; $body = $r.Content }
  catch { $code = [int]$_.Exception.Response.StatusCode; $body = '' }
  $sw.Stop()
  [pscustomobject]@{ code = $code; ms = $sw.Elapsed.TotalMilliseconds; body = $body }
}
Assert-RigFree

Section '1. a cached map answers from disk, fast'
$cached = Get-ChildItem (Join-Path $root 'dash\maps') -Filter 't*.json' | Where-Object { $_.Name -notmatch '\.gps\.json$' } | Select-Object -First 1
if ($cached) {
  $key = $cached.BaseName
  $null = Get-Map "key=$key&id=0&name=x"          # warm the connection
  $r = Get-Map "key=$key&id=0&name=x"
  $j = $r.body | ConvertFrom-Json
  Check "$key answers 200 with an outline in $([math]::Round($r.ms)) ms (<= 100)" ($r.code -eq 200 -and @($j.pts).Count -ge 200 -and $r.ms -le 100)
} else { Check 'there is a cached map to test with' $false }

Section '2. a track with no map: 202 building, never a made-up outline'
$unknown = 't999999-paddock-test-nowhere-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$r = Get-Map "key=$unknown&id=999999&name=paddock%20test%20nowhere"
$b = $null; try { $b = $r.body | ConvertFrom-Json } catch { }
Check "an unknown track answers 202 in $([math]::Round($r.ms)) ms with status building and a retry time" ($r.code -eq 202 -and $r.ms -le 100 -and $b.status -eq 'building' -and $b.retryAfter -ge 5)
Start-Sleep -Seconds 4
$r2 = Get-Map "key=$unknown&id=999999&name=paddock%20test%20nowhere"
$b2 = $null; try { $b2 = $r2.body | ConvertFrom-Json } catch { }
Check "after the builder tried, it still says building with its reason and a backed-off retry ($($b2.retryAfter) s: $($b2.lastError))" ($r2.code -eq 202 -and $b2.retryAfter -ge 30 -and $b2.lastError.Length -gt 0)
$log = Get-Content (Join-Path $root 'dash\irdash.log') -Tail 200
Check 'the builder logged the failure and its next try in plain words' (@($log | Where-Object { $_ -match [regex]::Escape("maps: $unknown not built") -and $_ -match 'next try in 1 min' }).Count -ge 1)
Remove-Item (Join-Path $root "dash\maps\$unknown.json") -ErrorAction SilentlyContinue

Section '3. the request path stays fast while the builder is busy'
# every telemetry-derived track whose cached map is not from telemetry gets queued; time other requests meanwhile
$keys = @(Get-ChildItem (Join-Path $root 'dash\maps') -Filter 't*.json' | Where-Object { $_.Name -notmatch '\.gps\.json$' } | ForEach-Object { $_.BaseName })
foreach ($k in $keys) { $null = Get-Map "key=$k&id=0&name=x" }
$worst = 0; for ($i = 0; $i -lt 20; $i++) { foreach ($k in $keys | Select-Object -First 3) { $t = (Get-Map "key=$k&id=0&name=x").ms; if ($t -gt $worst) { $worst = $t } } }
Check "60 map requests while builds may run: the slowest took $([math]::Round($worst)) ms (<= 100)" ($worst -le 100)

Section '4. the page draws no car on a missing outline (source check)'
$mapJs = Get-Content (Join-Path $root 'dash\www\v2\map.js') -Raw
$tvJs = Get-Content (Join-Path $root 'dash\www\v2\tv.js') -Raw
Check 'map.js has no straight lap bar placement any more' ($mapJs -notmatch 'x0 \+ \(\(\(pct % 1\) \+ 1\) % 1\) \* span' -and $mapJs -match 'if \(!this\.pts\) return;')
Check 'tv.js has no straight lap bar placement any more' ($tvJs -notmatch '40 \+ \(\(\(c\.pct % 1\) \+ 1\) % 1\)')

"$($script:pass) passed, $($script:fail) failed."
if ($script:fail -gt 0) { exit 1 }
