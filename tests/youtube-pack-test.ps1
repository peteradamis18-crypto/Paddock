# youtube-pack-test.ps1 - offline: the YouTube pack (W1-11): story titles, the description, the race thumbnail, the highlights clip and
# the model hook (dash\src\cuts.cs, thumb.cs, highlights.cs, words.cs, youtube.cs, library.cs).
#   0. a 10 s fixture clip made here by ffmpeg (a test pattern, HEVC with a keyframe every second like the recorder; never a race video)
#   1-6. a throw-away exe built from dash\src (the build.ps1 list) + tests\youtube-pack-main.cs: titles from 8 fixture stories, the
#        description and tags, the story from a fixture field log, the thumbnail from the clip, the highlights plan and a real join,
#        the model hook (off by default, a stub answers, the key never logged)
#   7. source checks: C# 5, no API call outside words.cs, the key file never in git, the quota counted, the card's words
# Picture: tests\shots\rework\yt-thumb-p15-p4.png (+ yt-thumb-win.png). Nothing touches irdash, the sim or any app.
#   powershell -ExecutionPolicy Bypass -File tests\youtube-pack-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function ok($what, $cond, $why = '') { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what $why" } }
$tmp = Join-Path $env:TEMP ('yt-pack-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$shots = Join-Path $root 'tests\shots\rework'; New-Item -ItemType Directory -Force $shots | Out-Null
# ffmpeg: the worktree has no vault, so the live checkout's copy (read and run only, on the fixture)
$ffmpeg = @((Join-Path $root 'vault\bin\ffmpeg.exe'), 'C:\Users\peter\iRacingDeck\vault\bin\ffmpeg.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
$ffprobe = if ($ffmpeg) { Join-Path (Split-Path $ffmpeg) 'ffprobe.exe' } else { '' }
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$buildList = Get-Content (Join-Path $root 'dash\build.ps1') -Raw
$srcs = @([regex]::Matches($buildList, '"\$d\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('dash\src\' + $_.Groups[1].Value) }) +
        @([regex]::Matches($buildList, '"\.\.\\src\\([A-Za-z0-9_]+\.cs)"') | ForEach-Object { Join-Path $root ('src\' + $_.Groups[1].Value) }) +
        @(Join-Path $PSScriptRoot 'youtube-pack-main.cs')
$harness = Join-Path $tmp 'pack-harness.exe'

'W1-11 the YouTube pack: titles, description, thumbnail, highlights, the model hook'
try {
  Assert-RigFree -Where '0. fixture clip'
  'Section 0. the fixture clip'
  ok 'ffmpeg is there (vault\bin)' ([bool]$ffmpeg)
  if (-not $ffmpeg) { throw 'no ffmpeg' }
  $clip = Join-Path $tmp 'fixture-race.mp4'
  $fx = Start-Process $ffmpeg -ArgumentList ('-v error -y -f lavfi -i testsrc2=size=2560x1440:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 10 ' +
        '-c:v libx265 -preset ultrafast -x265-params log-level=error:pools=2 -g 30 -pix_fmt yuv420p -tag:v hvc1 -c:a aac -b:a 96k -threads 2 "' + $clip + '"') -NoNewWindow -PassThru -Wait
  ok 'a 10 s HEVC fixture clip with a keyframe a second (a test pattern, not a race video)' ((Test-Path $clip) -and $fx.ExitCode -eq 0)

  Assert-RigFree -Where '1. compile'
  'Section 1. the harness'
  $cout = & $csc /nologo /target:exe /platform:anycpu /main:IRDash.YouTubePackMain "/out:$harness" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll /r:System.Security.dll @srcs 2>&1 | Out-String
  ok 'the harness (dash\src + tests\youtube-pack-main.cs) compiles' (Test-Path $harness) $cout
  if (-not (Test-Path $harness)) { throw 'no harness' }
  Copy-Item (Join-Path $root 'docs\youtube-words.md') (Join-Path $tmp 'youtube-words.md')

  Assert-RigFree -Where '2. cases'
  'Section 2-6. the cases'
  $work = Join-Path $tmp 'work'
  $p = Start-Process $harness -ArgumentList "`"$work`" `"$ffmpeg`" `"$ffprobe`" `"$clip`" `"$shots`"" -NoNewWindow -PassThru -RedirectStandardOutput "$tmp\out.txt" -RedirectStandardError "$tmp\err.txt"
  if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { }; ok 'the harness finished within 3 minutes' $false }
  $lines = @(Get-Content "$tmp\out.txt" -Encoding UTF8 -ErrorAction SilentlyContinue)
  foreach ($l in $lines) { if ($l -match '^ok (.*)') { ok $Matches[1] $true } elseif ($l -match '^FAIL (.*)') { ok $Matches[1] $false } elseif ($l -match '^  ') { $l } }
  ok 'the harness ran to the end' ($lines -contains 'DONE') ((Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) + '')
  ok 'the thumbnail picture is in tests\shots\rework' (Test-Path (Join-Path $shots 'yt-thumb-p15-p4.png'))

  Assert-RigFree -Where '7. source'
  'Section 7. source checks'
  $files = 'cuts.cs', 'thumb.cs', 'highlights.cs', 'words.cs', 'youtube.cs', 'library.cs' | ForEach-Object { Get-Content (Join-Path $root "dash\src\$_") -Raw }
  ok '7. C# 5 only in the six files (no $"...", ?., nameof, out var)' (-not (($files -join "`n") -match '(^|[\s(=,+:])\$"|\?\.[A-Za-z]|\bnameof\(|out var '))
  ok '7. thumb.cs, highlights.cs, words.cs are in dash\build.ps1' ($buildList -match 'src\\thumb\.cs' -and $buildList -match 'src\\highlights\.cs' -and $buildList -match 'src\\words\.cs')
  $w = Get-Content (Join-Path $root 'dash\src\words.cs') -Raw
  ok '7. the model hook is off unless youtube_words=claude (default "templates")' ($w.Contains('return "templates";') -and $w.Contains('if (Mode() != "claude") return draft;'))
  ok '7. the key goes only in the x-api-key header; no Log.W line names the key' ($w.Contains('q.Headers["x-api-key"] = key;') -and -not ([regex]::Matches($w, 'Log\.W\(([^;]*)\);') | Where-Object { $_.Groups[1].Value -match '\bkey\b' }))
  ok '7. only words.cs calls api.anthropic.com' (-not ((($files | Where-Object { $_ -ne $w }) -join "`n") -match 'anthropic\.com'))
  ok '7. the model is claude-sonnet-5-5, 400 tokens at most' ($w.Contains('Model = "claude-sonnet-5-5"') -and $w.Contains('MaxTokens = 400'))
  $gi = Get-Content (Join-Path $root '.gitignore') -Raw
  ok '7. dash/yt/ (where claude-key.txt lives) is gitignored, nothing in it committed' ($gi -match '(?m)^dash/yt/\s*$' -and -not (& git -C $root ls-files 'dash/yt' 2>$null))
  $yt = Get-Content (Join-Path $root 'dash\src\youtube.cs') -Raw
  ok '7. the quota: videos.insert 1600 + thumbnails.set 50 counted against 10,000 a day' ($yt.Contains('DailyUnits = 10000, InsertUnits = 1600, ThumbUnits = 50') -and $yt.Contains('Spend(InsertUnits') -and $yt.Contains('Spend(ThumbUnits'))
  ok '7. snippet.tags go up with the upload' ($yt.Contains('TagsJson(r.Tags'))
  ok '7. a 403 on thumbnails.set is "refused" (the channel is not verified) and the picture stays beside the video' ($yt.Contains('ThumbDone(r, "refused")'))
  $lib = Get-Content (Join-Path $root 'dash\src\library.cs') -Raw
  ok '7. the pack runs in the whenFree thumbnail job and SHARE, never while a session is on' ($lib.Contains('if (!yielded && !Packs(all))') -and $lib.Contains('if (Jobs.ShouldYield) return false;'))
  $js = Get-Content (Join-Path $root 'dash\www\app\pages\races.js') -Raw -Encoding UTF8
  ok '7. the HIGHLIGHTS card says "HIGHLIGHTS - 2:41" and nothing more (a label and a number)' ($js.Contains("'<div class=""hlname"">HIGHLIGHTS " + [char]0xB7 + " ' + mmss(h.sec) + '</div>'"))
  $ug = Get-Content (Join-Path $root 'docs\USER-GUIDE.md') -Raw
  ok '7. USER-GUIDE says what the model costs per race' ($ug -match 'youtube_words=claude' -and $ug -match 'per race')
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
"`n$($script:pass) ok, $($script:fail) FAIL"
if ($script:fail -gt 0) { exit 1 }
