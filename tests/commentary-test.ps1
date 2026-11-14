# commentary-test.ps1 - offline: TALK OVER IT (W1-6, dash\src\commentary.cs, dash\www\v2\player.*, races.js, deck-intro\plugin.html).
#   0. the media: a 3-second test video, a 9-second one, two "voices" (made here with the real vault\bin\ffmpeg.exe; never a real race)
#   1. the rules and the whole talk in a throw-away exe (dash\src + tests\commentary-main.cs in tests\commentary-scratch): the mix arguments
#      for D = +0.8 / -0.3 / 0, the filter string, the title suffix, the state JSON per kind, refused in a session, STOP allowed in one,
#      the voice kept for after the session, the mix with the real ffmpeg, SHARE as "<id>:c", no microphone, a player that never starts
#   2. the player in headless Chrome (fake microphone) against a pretend irdash on port 9462: "started", the microphone's name, STOP from
#      irdash, the voice posted with D between -0.5 and 0.5 and secs about 3, the silent warning (a silent fake microphone), no microphone,
#      a PC that cannot play the video
#   3. the mix's sound: the game is at least 6 dB quieter where the voice is; two streams; as long as the video
#   4. the RACES page states (preparing, talking, silent, mixing, ready, shared, failed, no mic) and the deck's talking view (STOP sends
#      racetalkstop, EXIT does not)
# Pictures: tests\shots\rework\talk-<state>.png. Nothing reaches the real irdash (8199), Stream Deck, YouTube or the rig.
#   powershell -ExecutionPolicy Bypass -File tests\commentary-test.ps1 [-Only 1,2] [-Keep]
param([string]$Only = '', [switch]$Keep)
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what $(if ($why) { '-> ' + $why })" } }
function Section($t) { Assert-RigFree -Where $t; $t }
function Want($n) { return (-not $Only) -or (($Only -split ',') -contains "$n") }
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
$scratch = Join-Path $PSScriptRoot 'commentary-scratch'; $bin = Join-Path $scratch 'bin'; $media = Join-Path $scratch 'media'
Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $bin, $media | Out-Null
# the real ffmpeg: this checkout's vault\bin, else the live checkout's (read and run only; every file it writes is in the scratch)
$ff = @((Join-Path $root 'vault\bin\ffmpeg.exe'), 'C:\Users\peter\iRacingDeck\vault\bin\ffmpeg.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
$fp = if ($ff) { Join-Path (Split-Path $ff) 'ffprobe.exe' } else { $null }
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
'W1-6 TALK OVER IT'

function FF([string[]]$a) { $p = Start-Process -FilePath $ff -ArgumentList $a -NoNewWindow -PassThru -Wait -RedirectStandardError (Join-Path $media 'ff-err.txt'); return $p.ExitCode }
# mean level of one band (Hz) in a stretch of a file, in dB
function Band([string]$file, [double]$ss, [double]$t, [int]$hz) {
  $o = & $ff -hide_banner -ss $ss -t $t -i $file -af "bandpass=f=$($hz):width_type=q:w=8,volumedetect" -f null - 2>&1 | Out-String
  if ($o -match 'mean_volume: (-?[\d.]+)') { return [double]$Matches[1] } else { return $null }
}

try {
  Section 'Section 0. the media'
  ok '0. the real ffmpeg and ffprobe are there' ($ff -and (Test-Path $fp)) $ff
  if (-not $ff) { throw 'no ffmpeg' }
  # h264 so headless Chrome plays it (the rig's HEVC is the LIVE check); the game sound is a 440 Hz tone
  $null = FF @('-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=duration=3:size=320x180:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=3', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-ac', '2', '-shortest', "`"$media\v3.mp4`"")
  $null = FF @('-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=duration=9:size=320x180:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=9', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-ac', '2', '-shortest', "`"$media\v9.mp4`"")
  # the voices: a 1 kHz tone all along, and one that starts after 1 s (silence before it); a silent wav for the silent microphone
  $null = FF @('-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'sine=frequency=1000:duration=3', '-af', 'volume=4', '-ac', '1', '-ar', '48000', '-c:a', 'libopus', "`"$media\voice.webm`"")
  $null = FF @('-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'aevalsrc=if(gte(t\,1)\,0.8*sin(2*PI*1000*t)\,0):s=48000:d=3', '-ac', '1', '-c:a', 'libopus', "`"$media\voice-late.webm`"")
  $null = FF @('-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=mono', '-t', '12', '-c:a', 'pcm_s16le', "`"$media\silent.wav`"")
  ok '0. the test video (3 s and 9 s), two voices and a silent wav are made' ((Test-Path "$media\v3.mp4") -and (Test-Path "$media\v9.mp4") -and (Test-Path "$media\voice.webm") -and (Test-Path "$media\voice-late.webm") -and (Test-Path "$media\silent.wav"))

  $mixed = $null
  if (Want 1) {
    Section 'Section 1. rules and the talk (harness)'
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $buildList = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
    $srcs = @([regex]::Matches($buildList, '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) }) +
            @([regex]::Matches($buildList, '"\.\.\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('src\' + $_.Groups[1].Value) }) +
            @((Join-Path $PSScriptRoot 'commentary-main.cs'))
    $harness = Join-Path $bin 'commentary-harness.exe'
    $cout = & $csc /nologo /target:exe /platform:anycpu /main:IRDash.CommentaryMain "/out:$harness" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll /r:System.Security.dll @srcs 2>&1 | Out-String
    ok '1. the harness (dash\src + tests\commentary-main.cs) compiles' (Test-Path $harness) ($cout | Select-String 'error' | Out-String)
    if (Test-Path $harness) {
      $p = Start-Process -FilePath $harness -ArgumentList @("`"$ff`"", "`"$fp`"", "`"$media`"") -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $scratch 'out.txt') -RedirectStandardError (Join-Path $scratch 'err.txt')
      try { $p.PriorityClass = 'BelowNormal' } catch { }
      if (-not $p.WaitForExit(240000)) { try { $p.Kill() } catch { }; ok '1. the harness finished within 4 minutes' $false }
      $lines = @(Get-Content (Join-Path $scratch 'out.txt'))
      foreach ($l in $lines) { if ($l -match '^ok (.*)') { ok $Matches[1] $true } elseif ($l -match '^FAIL (.*)') { ok $Matches[1] $false } elseif ($l -match '^MIXED (.*)') { $mixed = $Matches[1] } elseif ($l -match '^-- ') { $l } }
      ok '1. the harness ran to the end' ($lines -contains 'DONE') (Get-Content (Join-Path $scratch 'err.txt') -Raw)
    }
    $cs = [IO.File]::ReadAllText((Join-Path $root 'dash\src\commentary.cs'))
    ok '1. commentary.cs stays C# 5 (no $", ?., nameof, out var, =>)' (-not ($cs -match '\$"|\?\.[A-Za-z]|nameof\(|out var |\) =>'))
    $ir = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
    ok '1. irdash.cs routes /api/library/video and /api/talk/* to Commentary.Route and wires its browser' ($ir.Contains('Commentary.Route(s, method, path, ParseQuery(query), hdr)') -and $ir.Contains('Commentary.Browser = BrowserExe; Commentary.Port = cfg.Port; Commentary.Start();'))
  }

  if (Want 2) {
    Section 'Section 2. the player in headless Chrome'
    . (Join-Path $PSScriptRoot 'deck-harness.ps1')
    $ctl = Join-Path $scratch 'pretend'; New-Item -ItemType Directory -Force $ctl | Out-Null
    Set-Content (Join-Path $ctl 'video.txt') "$media\v3.mp4"; Set-Content (Join-Path $ctl 'stop.txt') '0'
    $port = 9462
    # the pretend irdash: the player's files from dash\www, the video with Range, /api/talk/state from stop.txt, every request logged
    $job = Start-Job -ArgumentList $port, (Join-Path $root 'dash\www'), $ctl -ScriptBlock {
      param($port, $www, $ctl)
      $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$port/"); $l.Start()
      $n = 0
      while ($true) {
        $ctx = $l.GetContext(); $rq = $ctx.Request; $rs = $ctx.Response; $path = $rq.Url.AbsolutePath; $code = 200; $type = 'application/json'; $bytes = $null
        Add-Content (Join-Path $ctl 'log.txt') ($rq.HttpMethod + ' ' + $rq.Url.PathAndQuery + ' xp=' + $rq.Headers['X-Paddock'])
        try {
          if ($path -like '/v2/*' -or $path -like '/app/*') {
            $f = Join-Path $www ($path.TrimStart('/') -replace '/', '\')
            if (Test-Path $f) { $bytes = [IO.File]::ReadAllBytes($f); $type = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript'; '.css' = 'text/css' }[[IO.Path]::GetExtension($f)] } else { $code = 404 }
          } elseif ($path -eq '/api/library/video') {
            $all = [IO.File]::ReadAllBytes((Get-Content (Join-Path $ctl 'video.txt') -Raw).Trim()); $type = 'video/mp4'; $rs.AddHeader('Accept-Ranges', 'bytes')
            $rg = $rq.Headers['Range']
            if ($rg -match '^bytes=(\d+)-(\d*)$') {
              $a = [long]$Matches[1]; $b = if ($Matches[2]) { [long]$Matches[2] } else { $all.Length - 1 }; if ($b -ge $all.Length) { $b = $all.Length - 1 }
              $code = 206; $rs.AddHeader('Content-Range', "bytes $a-$b/$($all.Length)"); $bytes = New-Object byte[] ($b - $a + 1); [Array]::Copy($all, $a, $bytes, 0, $bytes.Length)
            } else { $bytes = $all }
          } elseif ($path -eq '/api/talk/state') {
            $stop = (Get-Content (Join-Path $ctl 'stop.txt') -Raw).Trim() -eq '1'
            $bytes = [Text.Encoding]::UTF8.GetBytes('{"stop":' + $(if ($stop) { 'true' } else { 'false' }) + ',"kind":"talking"}')
          } elseif ($path -eq '/api/talk/event') { $bytes = [Text.Encoding]::UTF8.GetBytes('{"ok":true}')
          } elseif ($path -eq '/api/talk/voice') {
            $n++; $fs = [IO.File]::Create((Join-Path $ctl "voice-$n.webm")); $rq.InputStream.CopyTo($fs); $fs.Close()
            Add-Content (Join-Path $ctl 'log.txt') ("VOICE $n " + (Get-Item (Join-Path $ctl "voice-$n.webm")).Length)
            $bytes = [Text.Encoding]::UTF8.GetBytes('{"ok":true,"say":"Mixing your commentary"}')
          } else { $code = 404 }
        } catch { $code = 500 }
        if ($null -eq $bytes) { $bytes = [Text.Encoding]::UTF8.GetBytes('not found') }
        $rs.StatusCode = $code; $rs.ContentType = $type
        try { $rs.OutputStream.Write($bytes, 0, $bytes.Length); $rs.Close() } catch { }
      }
    }
    $up = $false; for ($i = 0; $i -lt 40 -and -not $up; $i++) { Start-Sleep -Milliseconds 250; try { $up = (Invoke-WebRequest "http://localhost:$port/v2/player.html" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } catch { } }
    ok "2. the pretend irdash answers on port $port (never 8199)" $up (Receive-Job $job 2>&1 | Out-String)
    function Log { if (Test-Path (Join-Path $ctl 'log.txt')) { @(Get-Content (Join-Path $ctl 'log.txt')) } else { @() } }
    # each browser its own debugging port: a closing one must never be the one the next run talks to
    function Player([string]$extra, [int]$dbg) {
      $prof = Join-Path $env:TEMP ('talk-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
      $a = @('--headless=new', '--no-first-run', "--user-data-dir=$prof", '--mute-audio', '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
             '--autoplay-policy=no-user-gesture-required', '--window-size=2560,1440', '--hide-scrollbars', "--remote-debugging-port=$dbg") + $(if ($extra) { @($extra) } else { @() }) + @('about:blank')
      $p = Start-Process -FilePath $chrome -ArgumentList $a -PassThru -WindowStyle Hidden
      $ver = $null; for ($i = 0; $i -lt 60 -and -not $ver; $i++) { Start-Sleep -Milliseconds 200; try { $ver = Invoke-RestMethod "http://127.0.0.1:$dbg/json/version" } catch { } }
      $bws = New-Object System.Net.WebSockets.ClientWebSocket; $null = $bws.ConnectAsync([Uri]$ver.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
      [pscustomobject]@{ Proc = $p; Prof = $prof; Port = $dbg; Bws = $bws }
    }
    function Shot($page, $name) { $r = Invoke-Cdp $page.Ws 'Page.captureScreenshot' @{ format = 'png' }; $f = Join-Path $shots "talk-$name.png"; [IO.File]::WriteAllBytes($f, [Convert]::FromBase64String($r.result.data)); ok "picture: $f" (Test-Path $f) }
    function WaitJs($page, $js, $sec) { for ($i = 0; $i -lt $sec * 5; $i++) { try { if ((Invoke-DeckJs $page $js) -eq $true) { return $true } } catch { }; Start-Sleep -Milliseconds 200 }; return $false }
    $avc = [uri]::EscapeDataString('video/mp4; codecs="avc1.42E01E"')

    # A. the fake microphone (a beep), the 3-second video played to its end: STOP by itself, the voice posted
    $b = Player '' 9463
    try {
      $pg = New-DeckPage $b "http://localhost:$port/v2/player.html?id=a1&codec=$avc"
      $st = WaitJs $pg 'window.player && player.out.started' 10
      ok '2. the player starts: the video plays and the recorder runs ("started" posted with the microphone name, X-Paddock: 1)' ($st -and ((Log) -match '^POST /api/talk/event\?id=a1&ev=started&mic=.+ xp=1$')) ((Log) -join ' | ')
      Start-Sleep -Milliseconds 900
      $micShown = Invoke-DeckJs $pg "document.getElementById('micName').textContent"
      ok "2. the microphone's name is on the screen ($micShown)" ($micShown -and $micShown -eq (Invoke-DeckJs $pg 'player.out.mic') -and $micShown -ne 'Microphone')
      ok '2. the bar says "Talking 0:0x" with one STOP' ((Invoke-DeckJs $pg "/^Talking 0:0[0-3]$/.test(document.getElementById('clock').textContent) && !document.getElementById('bar').hidden && document.querySelectorAll('.btn.stop').length === 1") -eq $true) (Invoke-DeckJs $pg "document.getElementById('clock').textContent")
      ok '2. no pause, no seek: the video has no controls' ((Invoke-DeckJs $pg "!document.getElementById('v').controls") -eq $true)
      Shot $pg 'player-talking'
      $done = WaitJs $pg 'player.out.posted > 0' 12
      $o = Invoke-DeckJs $pg 'player.out'
      $vl = @(Log | Where-Object { $_ -match '^POST /api/talk/voice\?id=a1&D=' })
      $vf = @(Log | Where-Object { $_ -match '^VOICE 1 (\d+)' }); $vsize = if ($vf) { [int]($vf[0] -replace '^VOICE 1 ', '') } else { 0 }
      ok "2. the video's end stops it: the voice is posted once (X-Paddock: 1) with D = $([math]::Round($o.D, 3)) s (between -0.5 and 0.5)" ($done -and $vl.Count -eq 1 -and $vl[0] -match 'xp=1$' -and $o.D -ge -0.5 -and $o.D -le 0.5) (($vl -join ' | ') + ' ' + ($o | ConvertTo-Json -Compress))
      ok "2. secs about 3 ($([math]::Round($o.secs, 2)) s), a non-empty webm ($vsize bytes), mic and silent=0 in the query" ($o.secs -ge 2.5 -and $o.secs -le 4.5 -and $vsize -gt 500 -and $vsize -eq $o.size -and $vl[0] -match '&mic=[^&]+&silent=0 ') ($vl -join ' | ')
      ok '2. then "Mixing... you can close this"' ((Invoke-DeckJs $pg "document.getElementById('msgMain').textContent") -match '^Mixing')
      Shot $pg 'player-mixing'
      $null = Invoke-Cdp $pg.Ws 'Page.close'

      # C. no microphone (getUserMedia refused) and D. a PC that cannot play the video
      Remove-Item (Join-Path $ctl 'log.txt') -ErrorAction SilentlyContinue
      $pg = New-DeckPage $b 'about:blank'
      $null = Invoke-Cdp $pg.Ws 'Page.enable'
      $null = Invoke-Cdp $pg.Ws 'Page.addScriptToEvaluateOnNewDocument' @{ source = "navigator.mediaDevices.getUserMedia = () => Promise.reject(new DOMException('none', 'NotFoundError'));" }
      $null = Invoke-Cdp $pg.Ws 'Page.navigate' @{ url = "http://localhost:$port/v2/player.html?id=c1&codec=$avc" }
      $nm = WaitJs $pg "document.getElementById('msgMain') && document.getElementById('msgMain').textContent === 'No microphone found. Plug in the headset and press again.'" 8
      Start-Sleep -Milliseconds 400
      ok '2. no microphone: "No microphone found. Plug in the headset and press again." and irdash is told (ev=nomic)' ($nm -and ((Log) -match '^POST /api/talk/event\?id=c1&ev=nomic xp=1$')) ((Log) -join ' | ')
      Shot $pg 'player-nomic'
      $null = Invoke-Cdp $pg.Ws 'Page.close'
      $bad = [uri]::EscapeDataString('video/mp4; codecs="nothing.1"')
      $pg = New-DeckPage $b "http://localhost:$port/v2/player.html?id=d1&codec=$bad"
      $cp = WaitJs $pg "document.getElementById('msgMain').textContent === `"This PC cannot play the video in Paddock's player`"" 8
      Start-Sleep -Milliseconds 400
      ok '2. a PC that cannot play it says so (ev=cannotplay), nothing is recorded' ($cp -and ((Log) -match '^POST /api/talk/event\?id=d1&ev=cannotplay') -and -not ((Log) -match 'talk/voice\?id=d1')) ((Log) -join ' | ')
      Shot $pg 'player-cannotplay'
    } finally { Stop-DeckBrowser $b }

    # B. a silent microphone (a silent wav as the fake one), the 9-second video, STOP from irdash (the deck or the page)
    Remove-Item (Join-Path $ctl 'log.txt') -ErrorAction SilentlyContinue
    Set-Content (Join-Path $ctl 'video.txt') "$media\v9.mp4"
    $b = Player "--use-file-for-fake-audio-capture=$media\silent.wav" 9465
    try {
      $pg = New-DeckPage $b "http://localhost:$port/v2/player.html?id=b1&codec=$avc"
      $st = WaitJs $pg 'window.player && player.out.started' 10
      $sil = WaitJs $pg "!document.getElementById('warn').hidden" 9
      ok '2. a silent microphone for 5 s: "The microphone is silent. Is it muted?" and irdash is told (ev=silent); the recording goes on' ($st -and $sil -and ((Log) -match '^POST /api/talk/event\?id=b1&ev=silent xp=1$') -and (Invoke-DeckJs $pg "player.rec.state") -eq 'recording') ((Log) -join ' | ')
      Shot $pg 'player-silent'
      Set-Content (Join-Path $ctl 'stop.txt') '1'
      $done = WaitJs $pg 'player.out.posted > 0' 6
      $o = Invoke-DeckJs $pg 'player.out'
      ok "2. STOP from irdash (/api/talk/state says stop): the voice is posted within 2 s, silent=1, secs $([math]::Round($o.secs, 1))" ($done -and ((Log) -match '^POST /api/talk/voice\?id=b1&D=.*&silent=1 xp=1$') -and $o.secs -ge 5.5 -and $o.secs -le 9.5) ((Log) -join ' | ')
      $polls = @(Log | Where-Object { $_ -match '^GET /api/talk/state\?id=b1' }).Count
      ok "2. it asks irdash about once a second while talking ($polls times)" ($polls -ge 4 -and $polls -le 12)
    } finally { Stop-DeckBrowser $b; Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
    $pj = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\player.js')); $pcss = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\player.css'))
    ok '2. player.js starts the recorder and the video in the same tick and measures D from the start / playing events' ($pj -match 'this\.rec\.start\(1000\);\s*\r?\n\s*v\.play\(\)' -and $pj.Contains('(this.t1 - this.t0) / 1000 - this.c1') -and $pj.Contains('echoCancellation: false, noiseSuppression: true'))
    ok '2. player.css has no colour of its own and only the type tokens' (-not ($pcss -match '#[0-9a-fA-F]{3,8}\b|rgba?\(|hsl') -and -not ($pcss -match 'font-size:\s*\d'))
  }

  if (Want 3) {
    Section 'Section 3. the mix with the real ffmpeg'
    if (-not $mixed) { ok '3. the harness left a mixed video (section 1)' $false }
    else {
      $pr = & $fp -v error -show_entries format=duration:stream=codec_type -of default=nw=1 $mixed 2>&1 | Out-String
      $vd = [double](& $fp -v error -show_entries format=duration -of default=nw=1:nk=1 "$media\v3.mp4")
      $md = if ($pr -match 'duration=([\d.]+)') { [double]$Matches[1] } else { 0 }
      ok '3. two streams (video + the mixed sound)' (([regex]::Matches($pr, 'codec_type=(video|audio)')).Count -eq 2 -and $pr.Contains('codec_type=video') -and $pr.Contains('codec_type=audio')) $pr
      ok "3. as long as the video within 0.2 s ($md s of $vd s)" ([math]::Abs($md - $vd) -le 0.2)
      # D = 0.5 trims the voice's first 0.5 s: it was silent for 1 s, so it is heard from 0.5 s on
      $g0 = Band $mixed 0 0.5 440; $g1 = Band $mixed 1 1 440; $v0 = Band $mixed 0 0.4 1000; $v1 = Band $mixed 0.7 0.3 1000
      ok "3. the game is at least 6 dB quieter where the voice is (0-0.5 s $g0 dB, 1-2 s $g1 dB)" ($null -ne $g0 -and $null -ne $g1 -and ($g0 - $g1) -ge 6)
      ok "3. the voice starts at 0.5 s (0-0.4 s $v0 dB, 0.7-1 s $v1 dB)" ($null -ne $v0 -and $null -ne $v1 -and ($v1 - $v0) -ge 20)
    }
  }
  if (Want 4) {
    Section 'Section 4. the RACES page'
    $www = Join-Path $root 'dash\www\v2'
    $tmp = Join-Path $scratch 'page'; New-Item -ItemType Directory -Force $tmp | Out-Null
    $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds(); $h = 3600000
    function Race($id, $ms, $talk, $state = '{"kind":"none"}') {
      '{"id":"' + $id + '","track":"Road Atlanta","config":"Full Course","car":"Toyota GR86","type":"Race","isRace":true,"startMs":' + $ms +
      ',"sec":1268,"laps":10,"counted":7,"best":93.832,"bestLap":9,"mb":1101,"kept":false,"thumb":false,"state":' + $state + ',"talk":' + $talk +
      ',"markers":[{"sec":0,"kind":"start","label":"Start"},{"sec":780.1,"kind":"best","label":"Best lap 1:33.832 (lap 9)"},{"sec":1248,"kind":"finish","label":"Finish"}]}'
    }
    $T = @{
      none      = '{"kind":"none","sec":0,"mic":"","silent":false,"url":"","error":"","note":"","yt":{"kind":"none"}}'
      preparing = '{"kind":"preparing","sec":0,"mic":"","silent":false,"url":"","error":"","note":"","yt":{"kind":"none"}}'
      talking   = '{"kind":"talking","sec":192,"mic":"Microphone (Arctis Nova 7P)","silent":false,"url":"","error":"","note":"","yt":{"kind":"none"}}'
      silent    = '{"kind":"talking","sec":75,"mic":"Microphone (Arctis Nova 7P)","silent":true,"url":"","error":"","note":"","yt":{"kind":"none"}}'
      mixing    = '{"kind":"mixing","sec":312,"mic":"Microphone (Arctis Nova 7P)","silent":false,"url":"","error":"","note":"","yt":{"kind":"none"}}'
      session   = '{"kind":"mixing","sec":312,"mic":"Microphone (Arctis Nova 7P)","silent":false,"url":"","error":"","note":"Stopped: a session started. What you said is kept.","yt":{"kind":"none"}}'
      ready     = '{"kind":"ready","sec":312,"mic":"Microphone (Arctis Nova 7P)","silent":false,"url":"","error":"","note":"","yt":{"kind":"none"}}'
      sharing   = '{"kind":"ready","sec":312,"mic":"","silent":false,"url":"","error":"","note":"","yt":{"kind":"sharing","pct":41}}'
      shared    = '{"kind":"shared","sec":312,"mic":"","silent":false,"url":"https://youtu.be/talk123","error":"","note":"","yt":{"kind":"shared","pct":100,"privacy":"private","url":"https://youtu.be/talk123"}}'
      failed    = '{"kind":"failed","sec":0,"mic":"","silent":false,"url":"","error":"No microphone found. Plug in the headset and press again.","note":"","yt":{"kind":"none"}}'
    }
    $races = @((Race 'r1' ($now - $h) $T.none), (Race 'r2' ($now - 2 * $h) $T.talking), (Race 'r3' ($now - 3 * $h) $T.ready), (Race 'r4' ($now - 4 * $h) $T.mixing))
    $fixture = '{"storage":{"usedGb":412,"freeGb":280,"trashGb":0,"moreRaces":38,"lowSpace":false},"youtube":{"signedIn":true,"privacy":"private","template":1},"titles":[],"races":[' + ($races -join ',') + '],"trash":[]}'
    $stub = @"
<script>
window.__fx = $fixture; window.__req = []; window.__rig = { online: true, driving: false }; window.__ls = {};
window.data = { __paddock: true, get rig() { return window.__rig; }, get online() { return true; }, on(n, f) { (window.__ls[n] = window.__ls[n] || []).push(f); return () => {}; },
  onList(n, f) { (window.__ls['list:' + n] = window.__ls['list:' + n] || []).push(f); }, fetch(u, o) { return window.fetch(u, o); } };
window.fetch = (url) => { url = String(url); window.__req.push(url);
  const j = (o, code) => Promise.resolve(new Response(JSON.stringify(o), { status: code || 200 }));
  if (/^\/api\/library$/.test(url)) return j(JSON.parse(JSON.stringify(window.__fx)));
  if (/c=racetalk&/.test(url)) return j({ ok: true, say: 'Getting the race ready' });
  if (/c=racetalkstop&/.test(url)) return j({ ok: true, say: 'Mixing your commentary' });
  if (/c=raceshare&/.test(url)) return j({ ok: true, count: 1, signin: false, say: 'Sharing it with your commentary' });
  return j({ ok: true, say: '' }); };
</script>
"@
    $run = @'
<pre id="out"></pre>
<script>
(async () => {
  const out = [], ok = (w, c, why) => out.push((c ? 'ok ' : 'FAIL ') + w + (c || why == null ? '' : ' -> ' + why));
  const sleep = ms => new Promise(r => setTimeout(r, ms)), $ = id => document.getElementById(id);
  const click = el => el.dispatchEvent(new MouseEvent('click', { bubbles: true }));
  const cmds = () => window.__req.filter(u => u.indexOf('/api/do') === 0).map(u => decodeURIComponent(u));
  const open = id => click(document.querySelector('.card[data-id="' + id + '"] [data-act="open"]'));
  await sleep(500);
  open('r1'); await sleep(100);
  const tk = document.querySelector('#open [data-act="talk"]');
  ok('4. TALK OVER IT is a live key on the open card (not greyed)', tk && !tk.disabled && tk.textContent === 'Talk over it' && !/Comes with/.test($('open').textContent));
  window.__req.length = 0; click(tk); await sleep(150);
  ok('4. it sends racetalk a=r1 and the bar says "Getting the race ready…" with STOP', cmds().join(' ') === '/api/do?c=racetalk&a=r1' && /Getting the race ready/.test($('open').textContent) && !!document.querySelector('#open .talkbar [data-act="talkstop"]'), cmds().join(' '));
  click(document.querySelector('[data-act="close"]')); await sleep(50);
  open('r2'); await sleep(100);
  const c1 = $('talkClock').textContent;
  ok('4. talking: one bar "Talking 3:12", the microphone, one red STOP; the five keys are gone', /^Talking 3:1\d$/.test(c1) && /Arctis Nova 7P/.test($('open').textContent) && document.querySelectorAll('#open .btn.stop').length === 1 && !document.querySelector('#open .o-keys'), c1);
  await sleep(2100);
  ok('4. the counter runs on the page (no request)', $('talkClock').textContent !== c1 && window.__req.filter(u => u === '/api/library').length <= 1, c1 + ' -> ' + $('talkClock').textContent);
  window.__req.length = 0; click(document.querySelector('#open [data-act="talkstop"]')); await sleep(150);
  ok('4. STOP sends racetalkstop a=r2 and the bar says "Mixing your commentary…"', cmds().join(' ') === '/api/do?c=racetalkstop&a=r2' && /Mixing your commentary/.test($('open').textContent), cmds().join(' '));
  click(document.querySelector('[data-act="close"]')); await sleep(50);
  open('r3'); await sleep(100);
  const sh = document.querySelector('#open [data-act="sharetalk"]');
  ok('4. ready: the second line "With commentary: ready" with SHARE WITH COMMENTARY', /With commentary: ready/.test($('open').textContent) && sh && sh.textContent === 'Share with commentary');
  const ln = document.querySelector('#open .o-talk .state');
  ok('4. that line stays on one row', ln && ln.getBoundingClientRect().height < 60, ln && ln.getBoundingClientRect().height);
  window.__req.length = 0; click(sh); await sleep(150);
  ok('4. that SHARE sends raceshare a=r3:c (the second video), and the line says waiting', cmds().join(' ') === '/api/do?c=raceshare&a=r3:c' && /With commentary: waiting to share/.test($('open').textContent), cmds().join(' '));
  out.push('DONE'); $('out').textContent = out.join('\n');
})();
</script>
'@
    $src = [IO.File]::ReadAllText((Join-Path $www 'races.html'))
    $base = '<base href="file:///' + ($www -replace '\\', '/') + '/">'
    $utf8 = New-Object Text.UTF8Encoding($false)
    $common = @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$tmp\prof", '--allow-file-access-from-files', '--window-size=1920,1080', '--hide-scrollbars', '--mute-audio')
    function Page([string]$name, [string]$head, [string]$body) {
      $x = $src.Replace('<head>', '<head>' + $base + $stub + $(if ($head) { '<script>' + $head + '</script>' } else { '' }))
      if ($body) { $x = $x.Replace('</body>', $body + '</body>') }
      [IO.File]::WriteAllText("$tmp\$name.html", $x, $utf8); return 'file:///' + ("$tmp\$name.html" -replace '\\', '/')
    }
    $u = Page 't' '' $run
    $null = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=20000', '--dump-dom', $u)) -NoNewWindow -Wait -RedirectStandardOutput "$tmp\out.txt" -RedirectStandardError "$tmp\err.txt"
    $m = [regex]::Match([string](Get-Content "$tmp\out.txt" -Raw), '(?s)<pre id="out">(.*?)</pre>')
    $text = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
    foreach ($l in @($text -split "`n")) { if ($l -match '^ok (.*)') { ok $Matches[1] $true } elseif ($l -match '^FAIL (.*)') { ok $Matches[1] $false } }
    ok '4. the page test ran to the end' ($text -match 'DONE')
    $rj = [IO.File]::ReadAllText((Join-Path $www 'races.js'))
    ok '4. races.js still has no setInterval (the counter is a timeout only while talking)' (-not $rj.Contains('setInterval'))
    # one picture per state: the open card of a race in that state
    foreach ($s in @('preparing', 'talking', 'silent', 'mixing', 'session', 'ready', 'sharing', 'shared', 'failed')) {
      $one = '{"storage":{"usedGb":412,"freeGb":280,"trashGb":0,"moreRaces":38,"lowSpace":false},"youtube":{"signedIn":true,"privacy":"private","template":1},"titles":[],"races":[' + (Race 'x1' ($now - $h) $T[$s] $(if ($s -eq 'shared') { '{"kind":"shared","pct":100,"privacy":"private","url":"https://youtu.be/abc123"}' } else { '{"kind":"none"}' })) + '],"trash":[]}'
      $u = Page "s-$s" "window.__fx = $one;" "<script>setTimeout(() => document.querySelector('.card [data-act=""open""]').dispatchEvent(new MouseEvent('click', { bubbles: true })), 500);</script>"
      $png = Join-Path $shots "talk-page-$s.png"; Remove-Item $png -ErrorAction SilentlyContinue
      $null = Start-Process -FilePath $chrome -ArgumentList ($common + @('--virtual-time-budget=2500', "--screenshot=$png", $u)) -NoNewWindow -Wait -RedirectStandardError "$tmp\e-$s.txt" -RedirectStandardOutput "$tmp\o-$s.txt"
      ok "picture: $png" (Test-Path $png)
    }

    Section 'Section 4. the deck RACES screen: the talking view'
    . (Join-Path $PSScriptRoot 'deck-harness.ps1')
    $html = Join-Path $tmp 'deck.html'
    $url = Build-DeckHarness (Join-Path $root 'deck-intro\plugin.html') $html
    $hh = [IO.File]::ReadAllText($html).Replace("TILE.RigConfirm = 'confirm';", "TILE.RigConfirm = 'confirm'; OPEN.push(['k-races', 'com.peter.rigintro.races', 5, 0]); TILE.RigRaces = 'races';")
    $cut = $hh.IndexOf('</script>')
    $hh = $hh.Substring(0, $cut) + "(function () { const f = window.fetch; window.fetch = function (u, o) { if (String(u).indexOf('/api/library/thumb') >= 0) return Promise.resolve(new Response('', { status: 404 })); return f.apply(this, arguments); }; })();" + $hh.Substring($cut)
    [IO.File]::WriteAllText($html, $hh, (New-Object Text.UTF8Encoding($false)))
    ok '4. the pretend deck page has the RACES key and cannot reach the real irdash' ($hh.Contains('k-races') -and $hh.Contains('return realFetch(url, opt);'))
    function Lib($talk) {
      $rows = @(@{ id = 'r00'; track = 'Road Atlanta'; config = ''; car = 'Toyota GR86'; type = 'Race'; isRace = $true; startMs = $now - $h; sec = 1268; laps = 10; counted = 9; best = 93.832; bestLap = 4; mb = 1100; kept = $false; thumb = $false
                  state = @{ kind = 'none' }; talk = ($talk | ConvertFrom-Json); min = 21; saved = $false },
                @{ id = 'r01'; track = 'Lime Rock Park'; config = ''; car = 'Toyota GR86'; type = 'Race'; isRace = $true; startMs = $now - 2 * $h; sec = 1268; laps = 10; counted = 9; best = 60.1; bestLap = 4; mb = 1100; kept = $false; thumb = $false
                  state = @{ kind = 'none' }; talk = ($T.none | ConvertFrom-Json); min = 21; saved = $false })
      @{ storage = @{ usedGb = 412; freeGb = 283; trashGb = 0; moreRaces = 38; lowSpace = $false }; races = $rows } | ConvertTo-Json -Depth 12 -Compress
    }
    $b = Start-DeckBrowser 9464
    try {
      $page = New-DeckPage $b $url -Hidden
      Start-Sleep -Milliseconds 600
      Start-DeckAddon $page @{ '/guest' = @{}; '/overlays' = @{}; '/replay' = @{ ready = $false }; '/doctor' = @{}; '/showcase' = @{ seq = 0; play = $false; driving = $false }; '/mydrive' = @{ ready = $false }; '/sound' = @{ ready = $false }; '/ac' = @{ connected = $false } }
      Start-Sleep -Seconds 1
      $null = Invoke-DeckJs $page "(() => { __sd.fx['/api/library'] = $(Lib $T.none); window.__apis = []; __sd.onApi = p => window.__apis.push(p); __sd.apiReply = p => JSON.stringify({ ok: true, say: /racetalkstop/.test(p) ? 'Mixing your commentary' : /racetalk/.test(p) ? 'Getting the race ready' : 'Sharing it with your commentary' }); return 1; })()"
      $null = Invoke-DeckJs $page "__sd.measureOpen('races')"; Start-Sleep -Milliseconds 1500
      function Set-Talk($t) { $null = Invoke-DeckJs $page "(async () => { __sd.fx['/api/library'] = $(Lib $t); Races.force = true; await Races.poll(); return 1; })()"; Start-Sleep -Milliseconds 500 }
      function Reg($c, $r) { Invoke-DeckJs $page "(() => { const r = Races.regions.find(x => $c >= x.c && $c < x.c + x.w && $r >= x.r && $r < x.r + x.h); return r ? { t: r.text, s: r.sub, st: r.style, a: r.act, g: r.arg, w: r.w, h: r.h } : null; })()" }
      function Press($c, $r) { $null = Invoke-DeckJs $page "(async () => { __sd.pressTile($c, $r); await __sd.sleep(500); return 1; })()" }
      function Apis { @(Invoke-DeckJs $page 'window.__apis') | ForEach-Object { [uri]::UnescapeDataString($_) } }
      $nocross = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'deck-races-nocross.js'))
      function Sheet($name) { Start-Sleep -Milliseconds 700; $r = Invoke-DeckJs $page $nocross; ok "4. deck $($name): no text of a multi-key tile crosses a key gap ($($r.runs) runs)" ($r.bad.Count -eq 0 -and $r.runs -gt 0) (@($r.bad) -join ' | '); $f = Join-Path $shots "talk-deck-$name.png"; $null = Save-DeckSheet $page $f; ok "picture: $f" (Test-Path $f) }

      # the open view: TALK OVER IT at (6,2)
      $null = Invoke-DeckJs $page "(async () => { Races.sel = 'r00'; Races.relayout(); return 1; })()"; Start-Sleep -Milliseconds 400
      $r = Reg 6 2
      ok '4. the open view has TALK OVER IT (gold) at 6,2' ($r.t -eq 'TALK' -and $r.s -eq 'OVER IT' -and $r.a -eq 'talkone' -and $r.st -eq 'sel') ($r | ConvertTo-Json -Compress)
      Sheet 'open'
      $null = Invoke-DeckJs $page 'window.__apis.length = 0'; Press 6 2
      ok '4. TALK OVER IT sends racetalk a=r00' (@(Apis | Where-Object { $_ -match 'racetalk' }) -join ' ' -match '/api/do\?c=racetalk&a=r00$') ((Apis) -join ' | ')

      # the talking view, whatever page was open
      Set-Talk $T.talking
      $r = Reg 3 0; $s = Reg 2 2
      ok '4. talking: the whole screen is the talking view, "TALKING 03:12" across 4 keys' ($r.t -match '^TALKING 03:1\d$' -and $r.w -eq 4 -and [int](Invoke-DeckJs $page 'Races.regions.length') -le 5) ($r | ConvertTo-Json -Compress)
      ok '4. the microphone name under it, STOP red 3 x 2, EXIT at 7,3' ((Reg 2 1).t -match 'Arctis' -and $s.a -eq 'talkstop' -and $s.st -eq 'stop' -and $s.w -eq 3 -and $s.h -eq 2 -and (Reg 7 3).a -eq 'exit') ((Reg 2 1) | ConvertTo-Json -Compress)
      Sheet 'talking'
      Set-Talk $T.silent
      ok '4. a silent microphone: MIC SILENT / IS IT MUTED? in amber' ((Reg 5 2).t -eq 'MIC SILENT' -and (Reg 5 2).st -eq 'amber')
      Sheet 'silent'
      Set-Talk $T.talking
      $null = Invoke-DeckJs $page 'window.__apis.length = 0'; Press 7 3
      ok '4. EXIT leaves the screen and does not stop the talk' (-not (@(Apis) -match 'racetalkstop') -and (Invoke-DeckJs $page '__sd.cur') -ne 'RigRaces') ((Apis) -join ' | ')
      $null = Invoke-DeckJs $page "__sd.measureOpen('races')"; Start-Sleep -Milliseconds 1200; Set-Talk $T.talking
      $null = Invoke-DeckJs $page 'window.__apis.length = 0'; Press 3 3
      ok '4. STOP (any of its 6 keys) sends racetalkstop a=r00' (@(Apis | Where-Object { $_ -match 'racetalkstop' }) -join ' ' -match 'racetalkstop&a=r00') ((Apis) -join ' | ')
      Set-Talk $T.mixing
      ok '4. mixing: "MIXING NOW", no STOP' ((Reg 2 0).t -eq 'MIXING NOW' -and $null -eq (Reg 2 2))
      Sheet 'mixing'
      Set-Talk $T.ready
      $null = Invoke-DeckJs $page "(async () => { Races.sel = 'r00'; Races.relayout(); return 1; })()"; Start-Sleep -Milliseconds 400
      $r = Reg 7 2
      ok '4. ready: SHARE COMMENTARY at 7,2 in the open view' ($r.t -eq 'SHARE' -and $r.s -eq 'COMMENTARY' -and $r.a -eq 'sharetalk') ($r | ConvertTo-Json -Compress)
      Sheet 'ready'
      $null = Invoke-DeckJs $page 'window.__apis.length = 0'; Press 7 2
      ok '4. SHARE COMMENTARY sends raceshare a=r00:c' (@(Apis | Where-Object { $_ -match 'raceshare' }) -join ' ' -match 'raceshare&a=r00:c') ((Apis) -join ' | ')
    } finally { Stop-DeckBrowser $b 2>$null }
  }
} finally {
  if (-not $Keep) { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
"`n$($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
