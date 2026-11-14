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
} finally {
  if (-not $Keep) { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
"`n$($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
