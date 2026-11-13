# tools-test.ps1 - offline: the W0-8 test tools (telemetry replay, pretend irdash, pretend Google).
# Pretend servers run on 8299 and 8399 only; nothing touches the real irdash, the sim or any app.
#   powershell -ExecutionPolicy Bypass -File tests\tools-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root 'tests\tools'; $fx = Join-Path $root 'tests\fixtures'
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }

# one GET/PUT/POST that never throws: returns code (0 = no answer / refused), body, headers
function Call($method, $url, $body = $null, $headers = @{}, $timeout = 8000) {
  $o = @{ code = 0; body = ''; h = @{}; err = '' }
  try {
    $r = [Net.HttpWebRequest]::Create($url); $r.Method = $method; $r.Timeout = $timeout; $r.ReadWriteTimeout = $timeout; $r.AllowAutoRedirect = $false
    $r.KeepAlive = $false
    foreach ($k in $headers.Keys) { if ($k -eq 'Content-Type') { $r.ContentType = $headers[$k] } else { $r.Headers[$k] = $headers[$k] } }
    if ($null -ne $body) {
      if ($body -is [string]) { $body = [Text.Encoding]::UTF8.GetBytes($body) }
      $r.ContentLength = $body.Length; $s = $r.GetRequestStream(); $s.Write($body, 0, $body.Length); $s.Close()
    } elseif ($method -ne 'GET') { $r.ContentLength = 0 }
    $resp = $r.GetResponse()
  } catch [Net.WebException] {
    $resp = $_.Exception.Response; $o.err = $_.Exception.Status.ToString()
    if (-not $resp) { return $o }
  } catch { $o.err = $_.Exception.Message; return $o }
  $o.code = [int]$resp.StatusCode
  foreach ($k in $resp.Headers.AllKeys) { $o.h[$k] = $resp.Headers[$k] }
  $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $o.body = $sr.ReadToEnd(); $sr.Dispose(); $resp.Close()
  return $o
}
function IsJson($s) { try { $null = $s | ConvertFrom-Json; return $true } catch { return $false } }

# read what an .ibt header says (same layout irdash's TrackMaps.OpenIbt uses)
function Ibt-Info($path) {
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
  try {
    $h = New-Object byte[] 144; [void]$fs.Read($h, 0, 144)
    $infoLen = [BitConverter]::ToInt32($h, 16); $infoOff = [BitConverter]::ToInt32($h, 20)
    $bufLen = [BitConverter]::ToInt32($h, 36); $dataOff = [BitConverter]::ToInt32($h, 52)
    $info = New-Object byte[] $infoLen; $fs.Position = $infoOff; [void]$fs.Read($info, 0, $infoLen)
    $z = [Array]::IndexOf($info, [byte]0); if ($z -lt 0) { $z = $infoLen }
    [pscustomobject]@{ Records = [long](($fs.Length - $dataOff) / $bufLen); Header = [BitConverter]::ToInt32($h, 140); Yaml = [Text.Encoding]::GetEncoding(28591).GetString($info, 0, $z); Len = $fs.Length }
  } finally { $fs.Dispose() }
}

'W0-8 test tools'
$source = 'C:\Users\peter\OneDrive\Documents\iRacing\telemetry\toyotagr86_roadatlanta full 2026-11-12 09-28-07.ibt'
$race = Join-Path $fx 'race-12nov.ibt'; $lap9 = Join-Path $fx 'race-12nov-lap9.ibt'
$havePair = $false
try {
  # ---------------------------------------------------------------- 1. fixtures and ibt-cut
  Assert-RigFree -Where '1. ibt-cut'
  'Section 1. the fixtures and ibt-cut'
  if ((-not (Test-Path $race)) -or (-not (Test-Path $lap9))) {
    if (Test-Path $source) {
      & (Join-Path $tools 'ibt-cut.ps1') -Source $source -Out $race -From 200 -To 380 | Out-Null
      & (Join-Path $tools 'ibt-cut.ps1') -Source $source -Out $lap9 -AroundLap 9 -Seconds 60 | Out-Null
    } else { '  skip the 12 Nov source file is not on this PC: no .ibt fixtures can be built' }
  }
  if ((Test-Path $race) -and (Test-Path $lap9) -and (Test-Path $source)) {
    $havePair = $true
    $src = Ibt-Info $source; $a = Ibt-Info $race; $b = Ibt-Info $lap9
    ok 'race-12nov.ibt: 3 minutes = 10800 records at 60 Hz' ($a.Records -eq 10800) "records $($a.Records)"
    ok 'race-12nov.ibt: header record count patched to match' ($a.Header -eq $a.Records) "header $($a.Header)"
    ok 'race-12nov.ibt: the session YAML is the same as the source' ($a.Yaml -eq $src.Yaml)
    ok 'race-12nov-lap9.ibt: 60 seconds = 3600 records, header patched' ($b.Records -eq 3600 -and $b.Header -eq 3600) "records $($b.Records) header $($b.Header)"
    ok 'race-12nov-lap9.ibt: the same YAML too' ($b.Yaml -eq $src.Yaml)
    ok 'the source was not touched and is bigger than the cut' ($src.Len -gt $a.Len * 5)
  } elseif (Test-Path $race) { $havePair = $true }

  # ---------------------------------------------------------------- 2. pretend irdash
  Assert-RigFree -Where '2. pretend irdash'
  'Section 2. pretend irdash'
  & (Join-Path $tools 'pretend-irdash.ps1') -Port 8299 | Out-Null
  $B = 'http://localhost:8299'
  $files = Get-ChildItem (Join-Path $fx 'irdash') -File
  ok 'the recorded routes are checked in (30 or more)' ($files.Count -ge 30) "$($files.Count) files"
  $bad = @()
  foreach ($f in $files) {
    $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $route = '/' + ($name -replace '~', '?' -replace '_', '/')
    $r = Call GET ($B + $route)
    $isJ = $f.Extension -eq '.json'
    if ($r.code -ne 200 -or ($isJ -and -not (IsJson $r.body))) { $bad += "$route ($($r.code))" }
  }
  ok "every recorded route answers 200 (JSON ones parse): $($files.Count) routes" ($bad.Count -eq 0) ($bad -join ', ')
  $r = Call GET "$B/no/such/route"; ok 'an unknown route answers 404' ($r.code -eq 404) "code $($r.code)"
  $null = Call GET "$B/__reset"
  1..5 | % { $null = Call GET "$B/showcase" }; $null = Call GET "$B/overlays"
  $st = (Call GET "$B/__stats").body | ConvertFrom-Json
  ok '/__stats counts per route' ($st.routes.'/showcase'.count -eq 5 -and $st.routes.'/overlays'.count -eq 1) ((Call GET "$B/__stats").body)
  ok '/__stats gives requests per second over the last 10 s' ($st.routes.'/showcase'.rps -ge 0.4 -and $st.routes.'/showcase'.rps -le 0.6) "rps $($st.routes.'/showcase'.rps)"
  $null = Call GET "$B/api/do?c=vkkeepall&a=r1"
  $st = (Call GET "$B/__stats").body | ConvertFrom-Json
  ok '/api/do answers ok and is logged' ((Call GET "$B/api/do?c=x").body -eq 'ok' -and ($st.do -join '|') -match 'c=vkkeepall&a=r1')
  $null = Call GET "$B/__reset"
  $st = (Call GET "$B/__stats").body | ConvertFrom-Json
  ok '/__reset clears the counts' ($st.total -le 1 -and $st.do.Count -eq 0)

  $null = Call GET "$B/__fault?mode=500"
  $r = Call GET "$B/showcase"; ok 'fault 500: every route answers 500' ($r.code -eq 500) "code $($r.code)"
  $null = Call GET "$B/__fault?mode=ok"
  $null = Call GET "$B/__fault?mode=500&route=/overlays"
  ok 'fault 500 for one route leaves the others alone' ((Call GET "$B/overlays").code -eq 500 -and (Call GET "$B/showcase").code -eq 200)
  $null = Call GET "$B/__fault?mode=ok&route=/overlays"
  ok 'a route fault clears with mode=ok&route=' ((Call GET "$B/overlays").code -eq 200)
  $null = Call GET "$B/__fault?mode=slow"
  $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Call GET "$B/showcase" $null @{} 12000; $sw.Stop()
  ok 'fault slow: the answer comes after 5 s' ($r.code -eq 200 -and $sw.Elapsed.TotalSeconds -ge 4.8 -and $sw.Elapsed.TotalSeconds -lt 8) "$([math]::Round($sw.Elapsed.TotalSeconds,1)) s code $($r.code)"
  $null = Call GET "$B/__fault?mode=ok"
  $null = Call GET "$B/__fault?mode=hung"
  $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Call GET "$B/showcase" $null @{} 5000; $sw.Stop()
  ok 'fault hung: no answer within 5 s' ($r.code -eq 0 -and $sw.Elapsed.TotalSeconds -ge 4.5) "code $($r.code) after $([math]::Round($sw.Elapsed.TotalSeconds,1)) s"
  $null = Call GET "$B/__fault?mode=ok"
  ok 'mode=ok after hung answers again' ((Call GET "$B/showcase").code -eq 200)
  $null = Call GET "$B/__fault?mode=down"
  $r = Call GET "$B/showcase" $null @{} 3000
  ok 'fault down: the connection is refused' ($r.code -eq 0) "code $($r.code) $($r.err)"
  $r = Call GET "http://localhost:8300/__fault?mode=ok" $null @{} 3000   # while down the control port (port+1) lifts it
  ok 'down is lifted by mode=ok on the control port (8300), the listener is back' ($r.code -eq 200 -and (Call GET "$B/showcase").code -eq 200) "control $($r.code)"

  # ---- /stream from the 12 Nov laps
  Assert-RigFree -Where '2b. stream'
  if ($havePair) {
    & (Join-Path $tools 'pretend-irdash.ps1') -Port 8299 -Ibt $race -Speed 20 | Out-Null
    $req = [Net.HttpWebRequest]::Create("$B/stream?hz=30&vars=Lap,SessionTime,Speed,IsOnTrack,CarIdxLapDistPct,SessionFlags"); $req.Timeout = 8000; $req.ReadWriteTimeout = 15000
    $resp = $req.GetResponse(); $sr = New-Object IO.StreamReader($resp.GetResponseStream())
    $sawSession = $false; $frames = 0; $maxLap = 0; $arrLen = 0; $first = ''; $evt = ''; $lastT = 0.0; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 14 -and $maxLap -lt 2) {
      $line = $sr.ReadLine(); if ($null -eq $line) { break }
      if ($line -like 'event: session') { $evt = 'session'; continue }
      if ($line -like 'data: *') {
        if ($evt -eq 'session') { $y = ($line.Substring(6) | ConvertFrom-Json); $sawSession = ($y -match 'WeekendInfo') ; $evt = ''; continue }
        $o = $line.Substring(6) | ConvertFrom-Json; $frames++
        if (-not $first) { $first = $line }
        if ($o.v.Lap -gt $maxLap) { $maxLap = $o.v.Lap }
        $arrLen = @($o.v.CarIdxLapDistPct).Count; $lastT = $o.v.SessionTime
      }
    }
    $sr.Dispose(); $resp.Close()
    ok '/stream sends the session YAML first (event: session)' $sawSession
    ok '/stream frames are in irdash wire format: {"seq":n,"v":{...}}' ($first -match '^data: \{"seq":\d+,"v":\{') $first
    ok '/stream carries the CarIdx arrays (64 slots)' ($arrLen -eq 64) "len $arrLen"
    ok '/stream plays the 12 Nov race at 20x: the lap counter reaches 2 inside the 3-minute fixture' ($maxLap -ge 2) "max lap $maxLap after $frames frames, session time $lastT"
    ok '/stream frames arrive at the page rate (not one burst)' ($frames -ge 20) "$frames frames"
    $st = (Call GET "$B/__stats").body | ConvertFrom-Json
    ok '/__stats counts the stream frames' ($st.frames -ge $frames) "$($st.frames)"
    & (Join-Path $tools 'pretend-irdash.ps1') -Port 8299 | Out-Null
  } else { '  skip /stream tests: no .ibt fixture' }

  # ---------------------------------------------------------------- 3. pretend Google
  Assert-RigFree -Where '3. pretend Google'
  'Section 3. pretend Google'
  & (Join-Path $tools 'pretend-google.ps1') -Port 8399 | Out-Null
  $G = 'http://localhost:8399'
  $r = Call POST "$G/token" 'grant_type=refresh_token' @{ 'Content-Type' = 'application/x-www-form-urlencoded' }
  ok '/token gives an access token' ($r.code -eq 200 -and ($r.body | ConvertFrom-Json).access_token -eq 't-1' -and ($r.body | ConvertFrom-Json).expires_in -eq 3600) $r.body
  $null = Call GET "$G/__fault?mode=invalid_grant"
  $r = Call POST "$G/token" 'x' @{ 'Content-Type' = 'application/x-www-form-urlencoded' }
  ok 'fault invalid_grant: /token answers 400 invalid_grant' ($r.code -eq 400 -and $r.body -match 'invalid_grant') $r.body
  $null = Call GET "$G/__reset"

  # a 40-line client: start, send in 8 MiB chunks, on any failure ask where the server is and go on from there
  $chunk = 8MB
  function Start-Upload($privacy, $total) {
    $snippet = '{"snippet":{"title":"t","categoryId":"20"},"status":{"privacyStatus":"' + $privacy + '"}}'
    $r = Call POST "$G/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status" $snippet @{ 'Content-Type' = 'application/json; charset=UTF-8'; Authorization = 'Bearer t-1'; 'X-Upload-Content-Length' = "$total" }
    return $r
  }
  function Send-All($loc, [byte[]]$data) {
    $total = $data.Length; $pos = 0L; $tries = 0; $last = $null
    $q0 = Call PUT $loc ([byte[]]@()) @{ 'Content-Range' = "bytes */$total" }      # always ask first where the server is
    if ($q0.code -eq 308 -and $q0.h['Range']) { $pos = [long]($q0.h['Range'] -replace '^bytes=0-', '') + 1 }
    while ($pos -lt $total) {
      $n = [int][Math]::Min($chunk, $total - $pos); $part = New-Object byte[] $n; [Array]::Copy($data, $pos, $part, 0, $n)
      $r = Call PUT $loc $part @{ 'Content-Range' = "bytes $pos-$($pos + $n - 1)/$total"; 'Content-Type' = 'video/mp4' } 20000
      $last = $r
      if ($r.code -eq 200 -or $r.code -eq 201) { return $r }
      if ($r.code -eq 308) { $pos = if ($r.h['Range']) { [long]($r.h['Range'] -replace '^bytes=0-', '') + 1 } else { 0 }; continue }
      if ($r.code -eq 404 -or ($r.code -ge 400 -and $r.code -lt 500 -and $r.code -ne 401)) { return $r }
      if (++$tries -gt 6) { return $r }
      $q = Call PUT $loc ([byte[]]@()) @{ 'Content-Range' = "bytes */$total" }     # 500, 503, 401 or a dead line: where are we?
      if ($q.code -eq 308) { $pos = if ($q.h['Range']) { [long]($q.h['Range'] -replace '^bytes=0-', '') + 1 } else { 0 } } elseif ($q.code -eq 200) { return $q }
    }
    return $last
  }

  $big = New-Object byte[] (25MB); (New-Object Random 42).NextBytes($big)
  $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($big)).Replace('-', '').ToLower()
  $s = Start-Upload 'private' $big.Length
  ok 'the start answers 200 with a Location: session URL' ($s.code -eq 200 -and $s.h['Location'] -match '/upload/session/\d+$') "code $($s.code)"
  $loc = $s.h['Location']
  # the first two chunks go through; the drop is queued, so it hits the third
  $p1 = New-Object byte[] $chunk; [Array]::Copy($big, 0, $p1, 0, $chunk)
  $r1 = Call PUT $loc $p1 @{ 'Content-Range' = "bytes 0-$($chunk - 1)/$($big.Length)" } 20000
  ok 'a non-final chunk answers 308 with Range: bytes=0-<last>' ($r1.code -eq 308 -and $r1.h['Range'] -eq "bytes=0-$($chunk - 1)") "code $($r1.code) range $($r1.h['Range'])"
  $q = Call PUT $loc ([byte[]]@()) @{ 'Content-Range' = "bytes */$($big.Length)" }
  ok 'a "bytes */total" query answers 308 and Range for what arrived' ($q.code -eq 308 -and $q.h['Range'] -eq "bytes=0-$($chunk - 1)") "code $($q.code) range $($q.h['Range'])"
  $p2 = New-Object byte[] $chunk; [Array]::Copy($big, $chunk, $p2, 0, $chunk)
  $r2 = Call PUT $loc $p2 @{ 'Content-Range' = "bytes $chunk-$(2 * $chunk - 1)/$($big.Length)" } 20000
  ok 'chunk 2 also answers 308' ($r2.code -eq 308 -and $r2.h['Range'] -eq "bytes=0-$(2 * $chunk - 1)") "code $($r2.code)"
  $null = Call GET "$G/__fault?mode=drop"
  $r = Send-All $loc $big      # starts again from the server's answer; chunk 3 is dropped half way, then resumed
  $st = (Call GET "$G/__stats").body | ConvertFrom-Json
  $sess = $st.sessions.($loc -replace '^.*/', '')
  ok 'after the drop the upload resumes and finishes with a video id' ($r.code -eq 200 -and ($r.body | ConvertFrom-Json).id -eq 'vid001') "code $($r.code) $($r.body)"
  ok 'the server really dropped the line once' ($st.dropped -eq 1)
  ok 'every byte arrived (bytes == total) and the content is identical' ($sess.bytes -eq $big.Length -and $sess.sha256 -eq $sha) "bytes $($sess.bytes) of $($big.Length)"
  $acc = @($sess.chunks | ? { $_.len -gt 0 -and ($_.result -eq 'ok' -or $_.result -like 'dropped*') } | sort from)
  $gap = $false; $over = $false; $next = 0L
  foreach ($c in $acc) { if ($c.from -gt $next) { $gap = $true }; if ($c.from -lt $next) { $over = $true }; $next = $c.from + $c.len }
  ok 'no byte arrived twice and there is no gap' (-not $gap -and -not $over -and $next -eq $big.Length -and -not $sess.rangeTwice) "next $next gap $gap over $over twice $($sess.rangeTwice)"
  ok 'the sent privacy comes back in the final JSON' (($sess.final | ConvertFrom-Json).status.privacyStatus -eq 'private')
  ok 'the snippet JSON was recorded' ($sess.snippet -match '"title":"t"')
  $resume = $acc | ? { $_.result -like 'dropped*' }
  ok 'the resume started at the offset the server said (a whole number of 256 KiB blocks)' ($resume -and (($resume.from + $resume.len) % 262144 -eq 0) -and ($acc | ? { $_.from -eq ($resume.from + $resume.len) })) ($acc | % { "$($_.from)+$($_.len)" }) -join ' '

  # the other faults
  $null = Call GET "$G/__reset"
  $small = New-Object byte[] (1MB); (New-Object Random 7).NextBytes($small)
  foreach ($f in '500once', '503once', '401once') {
    $null = Call GET "$G/__fault?mode=$f"; $s = Start-Upload 'unlisted' $small.Length
    $r = Send-All $s.h['Location'] $small
    ok "fault $f : the client recovers and the upload finishes" ($r.code -eq 200 -and ($r.body | ConvertFrom-Json).status.privacyStatus -eq 'unlisted') "code $($r.code)"
  }
  $null = Call GET "$G/__fault?mode=404session"; $s = Start-Upload 'private' $small.Length
  $r = Send-All $s.h['Location'] $small; ok 'fault 404session: the chunk answers 404' ($r.code -eq 404) "code $($r.code)"
  # a gap breaks the session
  $s = Start-Upload 'private' $small.Length; $part = New-Object byte[] 262144
  $r = Call PUT $s.h['Location'] $part @{ 'Content-Range' = "bytes 262144-524287/$($small.Length)" }
  $st = (Call GET "$G/__stats").body | ConvertFrom-Json; $sid = $s.h['Location'] -replace '^.*/', ''
  ok 'a chunk that does not continue answers 400 and the session is marked broken' ($r.code -eq 400 -and $st.sessions.$sid.broken -eq $true) "code $($r.code)"
  $null = Call GET "$G/__fault?mode=uploadLimitExceeded"; $r = Start-Upload 'private' 100
  ok 'fault uploadLimitExceeded: the start answers 400 uploadLimitExceeded' ($r.code -eq 400 -and $r.body -match 'uploadLimitExceeded') "code $($r.code)"
  $null = Call GET "$G/__reset"; $null = Call GET "$G/__fault?mode=forbiddenPrivacySetting"
  $r = Start-Upload 'public' 100; $r2 = Start-Upload 'private' 100
  ok 'fault forbiddenPrivacySetting: public is refused 403, private still works' ($r.code -eq 403 -and $r.body -match 'forbiddenPrivacySetting' -and $r2.code -eq 200) "codes $($r.code) $($r2.code)"
  $null = Call GET "$G/__reset"; $null = Call GET "$G/__fault?mode=thumb403"
  $r = Call POST "$G/upload/youtube/v3/thumbnails/set?videoId=vid001&uploadType=media" ([byte[]](1..50)) @{ 'Content-Type' = 'image/jpeg' }
  ok 'fault thumb403: thumbnails/set answers 403' ($r.code -eq 403) "code $($r.code)"
  $null = Call GET "$G/__reset"
  $r = Call POST "$G/upload/youtube/v3/thumbnails/set?videoId=vid001&uploadType=media" ([byte[]](1..50)) @{ 'Content-Type' = 'image/jpeg' }
  ok 'without the fault thumbnails/set answers 200' ($r.code -eq 200)

  # ---------------------------------------------------------------- 3b. irdash's IbtReplay class itself
  Assert-RigFree -Where '3b. IbtReplay'
  'Section 3b. irdash IbtReplay (the real class, cut out of irdash.cs, run against stand-ins)'
  if ($havePair) {
    $cs = Get-Content (Join-Path $root 'dash\src\irdash.cs') -Raw
    $i0 = $cs.IndexOf('    // ---------------- Telemetry replay'); $i1 = $cs.IndexOf('    // ---------------- iRacing SDK reader')
    ok 'IbtReplay sits right before the pretend-session pump in irdash.cs' ($i0 -gt 0 -and $i1 -gt $i0)
    $tmp = Join-Path $env:TEMP 'ibt-replay-harness'; New-Item -ItemType Directory -Force $tmp | Out-Null
    $h = (Get-Content (Join-Path $tools 'ibt-replay-harness.cs') -Raw).Replace('//IBTREPLAY//', $cs.Substring($i0, $i1 - $i0))
    $hs = Join-Path $tmp 'harness.cs'; [IO.File]::WriteAllText($hs, $h)
    & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -nologo -out:"$tmp\harness.exe" $hs | Out-Null
    ok 'IbtReplay compiles on its own with C# 5' ($LASTEXITCODE -eq 0)
    $out = & "$tmp\harness.exe" $race 20 11 2>$null
    $o = @{}; foreach ($l in $out) { $k, $v = $l -split ' ', 2; $o[$k] = $v }
    $stt = $o['STATUS'] | ConvertFrom-Json
    ok 'the replay ran to the end of the 3-minute fixture at 20x and says done' ($stt.done -eq $true -and $stt.records -eq 10800) $o['STATUS']
    ok 'it published many frames (pump rate), not one' ($stt.sent -ge 100) "sent $($stt.sent)"
    ok 'the lap counter climbed to 2 (green flag at 21 s into the fixture, lap 2 at 120 s)' ([int]$o['LAP'] -eq 2) "Lap $($o['LAP'])"
    ok 'the session YAML went in first' ([int]$o['YAMLLEN'] -gt 10000) $o['YAMLLEN']
    ok 'types are exact: SessionFlags bit field, SessionTime double, Lap int, OnPitRoad bool, Speed float' ($o['IBTTYPE_FLAGS'] -match '^3 IBTTYPE_TIME 5 IBTTYPE_LAP 2 IBTTYPE_ONPIT 1 IBTTYPE_SPEED 4') $o['IBTTYPE_FLAGS']
    ok 'SessionFlags came through whole (0x10040000 = 268697600 mid-race)' ([double]$o['FLAGS'] -eq 268697600) "flags $($o['FLAGS'])"
    ok 'no CarIdx arrays in an .ibt, so the car itself is in its own slot and the others are empty (-1)' ([double]($o['PLAYERSLOT'] -split ' ')[0] -gt 0 -and ($o['PLAYERSLOT'] -split ' ')[2] -eq '-1') $o['PLAYERSLOT']
    ok '/api/test/end stops it (Stop() ends the thread: running false)' (($o['STOPPED'] | ConvertFrom-Json).running -eq $false)
    $out = & "$tmp\harness.exe" 'C:\no\such.ibt' 20 1 2>$null
    ok 'a missing file is refused with a reason, nothing starts' ($out -match 'START-FAILED no such file')
  } else { '  skip IbtReplay: no .ibt fixture' }

  # ---------------------------------------------------------------- 4. the irdash route
  Assert-RigFree -Where '4. irdash route'
  'Section 4. the /api/test/ibt route in irdash'
  $cs = Get-Content (Join-Path $root 'dash\src\irdash.cs') -Raw
  $iGate = $cs.IndexOf('path == "/api/test/end" || path == "/api/test/ibt"')
  $iHook = $cs.IndexOf('if (!Sdk.TestHook)', $iGate)
  $iRoute = $cs.IndexOf('else if (path == "/api/test/ibt")', $iGate)
  $iClose = $cs.IndexOf('if (method == "GET")', $iGate)
  ok 'the route sits in the same gated block as /api/test/frame' ($iGate -gt 0 -and $iHook -gt $iGate -and $iRoute -gt $iHook -and $iRoute -lt $iClose)
  $block = $cs.Substring($iGate, $iRoute - $iGate)
  ok 'the gate answers 404 without test-hook.on and 409 while a real session is on, before the replay can start' ($block -match '409' -and $block -match '404' -and $block -match 'Sdk\.RealBusy\(\)')
  ok '/api/test/end also stops the replay' ($cs -match 'IbtReplay\.Stop\(\); Sdk\.FakeEnd\(\);')
  ok 'a real session ends the replay (the pump stops when Pretend goes false)' ($cs -match 'if \(!Sdk\.Pretend\) break;')
  & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'dash\build.ps1') -NoDeploy *> $null
  ok 'dash\build.ps1 -NoDeploy compiles irdash with the route' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
}
finally {
  & (Join-Path $tools 'pretend-irdash.ps1') -Port 8299 -Stop | Out-Null
  & (Join-Path $tools 'pretend-google.ps1') -Port 8399 -Stop | Out-Null
}
"tools-test: $script:pass ok, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }




