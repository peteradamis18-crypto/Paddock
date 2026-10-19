# Audio test (docs\design\audio-recording.md, dash\src\recaudio.cs + the sound parts of dash\src\recorder.cs).
#   1. the capture code on its own (tests\audio-harness.cs compiled with recaudio.cs, no irdash):
#      a. the whole-PC loopback opens in shared mode (no sound needed)
#      b. 5 s of a real, quiet test tone played by the harness and captured by Windows process loopback: not silent, the chunk's
#         length equals the wall clock within 50 ms, the tone's length within 30 ms, and when it was heard vs when it was asked.
#         The tone is audible (quiet, 5 s), so this part needs Peter away 10 minutes (or away-ok.txt); otherwise it is skipped and says so.
#      c. that capture (or, when b was skipped, a made-up one) muxed with a test video: 1 video + 1 audio stream, lengths within 100 ms
#   2. through irdash's real recorder (test hook, scratch vault, made-up picture with a burned-in clock, test clicks on every whole
#      wall-clock second instead of a device): the session file, a lap clip and an incident clip carry sound, the click and the picture
#      of that second agree within 20 ms (also across a stint join), a Debrief-style -c copy cut keeps the sound, the sound chunks are
#      cleaned up with the segments, audio=off writes picture only (audio:none), a capture that cannot start says "failed", and a real
#      browser decodes the sound. Needs irdash on port 8199 to be a build with recaudio.cs (else part 2 is skipped and says so).
#   powershell -ExecutionPolicy Bypass -File tests\audio-test.ps1 [-Only 1] [-Keep]
param([string]$Only = '', [switch]$Keep)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$api = if ($env:VAULT_TEST_API) { $env:VAULT_TEST_API } else { 'http://localhost:8199' }
$pass = 0; $fail = 0; $skipped = @()
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Note($what) { "  info  $what" }
function Near($a, $b, $tol) { [math]::Abs([double]$a - [double]$b) -le $tol }
function J($path) { $r = Invoke-WebRequest -UseBasicParsing "$api$path" -TimeoutSec 120; [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
function NowMs { [long](([DateTime]::UtcNow - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalMilliseconds) }
function F3($d) { [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.000}', [double]$d) }

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }
$onlySet = @($Only -split '[ ,]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
function Want($n) { return ($onlySet.Count -eq 0) -or ($onlySet -contains $n) }

Add-Type -TypeDefinition @'
using System; using System.Diagnostics; using System.IO; using System.Text; using System.Threading;
public sealed class AudRes { public byte[] Out = new byte[0]; public string Err = ""; public int Code = -1; }
public static class AudTool {
  public static AudRes Run(string exe, string args, int timeoutMs) {
    AudRes res = new AudRes();
    ProcessStartInfo psi = new ProcessStartInfo(exe, args); psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
    using (Process p = Process.Start(psi)) {
      try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
      MemoryStream ms = new MemoryStream(); StringBuilder se = new StringBuilder();
      Thread t = new Thread(delegate() { try { p.StandardOutput.BaseStream.CopyTo(ms); } catch { } }); t.IsBackground = true; t.Start();
      p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) lock (se) se.AppendLine(e.Data); };
      p.BeginErrorReadLine();
      if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } res.Err = "timed out"; return res; }
      p.WaitForExit(); t.Join(3000); res.Out = ms.ToArray(); lock (se) res.Err = se.ToString(); res.Code = p.ExitCode; return res;
    }
  }
  // click onsets in mono s16le: the first sample over 'hi' when none was over 'hi' in the 'quiet' samples before it
  // ('lo' is unused: the rising edge of a click crosses every level below 'hi' first)
  public static int[] Onsets(byte[] b, int hi, int lo, int quiet) {
    System.Collections.Generic.List<int> r = new System.Collections.Generic.List<int>(); int lastHi = -quiet - 1;
    for (int i = 0; i + 1 < b.Length; i += 2) { int x = Math.Abs((int)(short)(b[i] | (b[i + 1] << 8))); int k = i / 2;
      if (x >= hi) { if (k - lastHi > quiet) r.Add(k); lastHi = k; } }
    return r.ToArray();
  }
  public static double Rms(byte[] b) { double s = 0; int n = b.Length / 2; for (int i = 0; i + 1 < b.Length; i += 2) { double x = (short)(b[i] | (b[i + 1] << 8)); s += x * x; } return n > 0 ? Math.Sqrt(s / n) : 0; }
}
'@

$ffmpeg = Join-Path $root 'vault\bin\ffmpeg.exe'; $ffprobe = Join-Path $root 'vault\bin\ffprobe.exe'
$tmp = Join-Path $env:TEMP ('audio-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
function Tool($exe, $argLine, $timeout = 120000) { return [AudTool]::Run($exe, $argLine, $timeout) }
function Probe($argLine) { $r = Tool $ffprobe $argLine 60000; return ([Text.Encoding]::UTF8.GetString($r.Out)) }
# what ffmpeg -i says about a file: the stream lines (the plain "parse ffmpeg -i" check), and each stream's own length from ffprobe
function Streams($f) {
  $r = Tool $ffmpeg "-hide_banner -i `"$f`"" 30000
  $lines = @($r.Err -split "`n" | Where-Object { $_ -match 'Stream #' })
  $v = @($lines | Where-Object { $_ -match ': Video:' }).Count; $a = @($lines | Where-Object { $_ -match ': Audio:' }).Count
  $vd = 0.0; $ad = 0.0; $as = 0.0; $vs = 0.0
  $t = Probe "-v error -select_streams v:0 -show_entries stream=duration,start_time -of default=nw=1 `"$f`""; foreach ($l in $t -split "`n") { if ($l -match '^duration=([\d.]+)') { $vd = [double]$Matches[1] } elseif ($l -match '^start_time=([-\d.]+)') { $vs = [double]$Matches[1] } }
  $t = Probe "-v error -select_streams a:0 -show_entries stream=duration,start_time -of default=nw=1 `"$f`""; foreach ($l in $t -split "`n") { if ($l -match '^duration=([\d.]+)') { $ad = [double]$Matches[1] } elseif ($l -match '^start_time=([-\d.]+)') { $as = [double]$Matches[1] } }
  return @{ video = $v; audio = $a; vdur = $vd; adur = $ad; vstart = $vs; astart = $as; text = ($lines -join ' / ') }
}
# the 32-block clock burned into the test picture (ms since the run's base) of every frame, with that frame's time in the file
function Frame-Clocks($f) {
  $pts = @((Probe "-v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 `"$f`"").Split("`n") | Where-Object { $_.Trim() } | ForEach-Object { [double]($_.Split(',')[0]) } | Sort-Object)
  $r = Tool $ffmpeg "-v error -i `"$f`" -map 0:v:0 -vf crop=640:32:0:0,scale=32:1:flags=neighbor,format=gray -fps_mode passthrough -f rawvideo -" 180000
  $b = $r.Out; $vals = New-Object System.Collections.Generic.List[double]
  for ($k = 0; $k + 32 -le $b.Length; $k += 32) { $ms = 0.0; for ($i = 0; $i -lt 32; $i++) { if ($b[$k + $i] -gt 128) { $ms += [math]::Pow(2, $i) } }; $vals.Add($ms) }
  return @{ pts = $pts; clk = $vals.ToArray() }
}
# the clicks heard (s, the file's own time) and how far each is from the picture of that whole wall-clock second
function Sync-Errors($f) {
  $st = Streams $f
  $r = Tool $ffmpeg "-v error -i `"$f`" -map 0:a:0 -ac 1 -ar 48000 -f s16le -" 180000
  $on = [AudTool]::Onsets($r.Out, 8000, 2000, 4800)
  $fc = Frame-Clocks $f; $n = [math]::Min($fc.pts.Count, $fc.clk.Count)
  $errs = @()
  foreach ($k in $on) {
    $t = $st.astart + $k / 48000.0
    $best = -1; $bd = 1e9; for ($i = 0; $i -lt $n; $i++) { $d = [math]::Abs($fc.pts[$i] - $t); if ($d -lt $bd) { $bd = $d; $best = $i } }
    if ($best -lt 0 -or $bd -gt 0.2) { continue }
    $c = $fc.clk[$best]; $sec = [math]::Round($c / 1000.0) * 1000.0
    $exp = $fc.pts[$best] + ($sec - $c) / 1000.0
    $errs += ($t - $exp) * 1000.0
  }
  return @{ clicks = $on.Count; frames = $n; errs = $errs; streams = $st }
}

$swAll = [Diagnostics.Stopwatch]::StartNew()
'Audio test'
try {

# =====================================================================================================
if (Want 1) {
Section '1. the capture on its own (tests\audio-harness.cs + dash\src\recaudio.cs)'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$hx = Join-Path $tmp 'audio-harness.exe'
$c = Tool $csc "/nologo /target:exe /optimize+ `"/out:$hx`" `"$root\dash\src\recaudio.cs`" `"$root\tests\audio-harness.cs`"" 120000
Check 'the capture code compiles on its own (C# 5, no irdash)' ($c.Code -eq 0)
if ($c.Code -ne 0) { Note ([Text.Encoding]::UTF8.GetString($c.Out)) }

# a. the fallback opens (no sound needed: silence is still delivered)
$o = Tool $hx 'open-system' 30000; $oj = [Text.Encoding]::UTF8.GetString($o.Out) | ConvertFrom-Json
Check "the whole-PC loopback opens in shared mode (state $($oj.state), $($oj.status.runPackets) packets in 1.2 s)" ($oj.state -eq 'ok')
# the real choice: iRacing and CrewChief by name when they run, else the whole PC (nothing is played; they are only listened to)
$sim = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'iRacingSim*' }).Count; $cc = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'CrewChief*' }).Count
$o = Tool $hx 'open auto' 30000; $aj = [Text.Encoding]::UTF8.GetString($o.Out) | ConvertFrom-Json
$want = if ($sim -and $cc) { 'iRacing + CrewChief' } elseif ($cc) { 'CrewChief' } elseif ($sim) { 'iRacing' } else { 'whole PC' }
Check "automatic choice picks only the game and the spotter ($($aj.source); expected $want)" ($aj.state -eq 'ok' -and $aj.source -eq $want)

# b. a real tone, really captured (audible: Peter must be away)
$idle = [RigGuard]::IdleMinutes(); $okf = Join-Path $root 'away-ok.txt'
$away = $idle -ge 10 -or ((Test-Path $okf) -and ((Get-Date) - (Get-Item $okf).LastWriteTime).TotalMinutes -lt 60 -and $idle -ge 0.5)
$pcm = $null
if (-not $away) {
  $script:skipped += '1b real tone'
  Note "SKIPPED 1b (the real tone): Peter used the PC $([math]::Round($idle, 1)) minutes ago; it plays a quiet 5 s tone, so it waits until he has been away 10 minutes"
} else {
  Section '1b. 5 s of a quiet tone through the default output, captured by process loopback'
  $d = Join-Path $tmp 'tone'
  $t = Tool $hx "tone `"$d`" 5.0 0.03 1.0 self" 60000
  $tj = [Text.Encoding]::UTF8.GetString($t.Out) | ConvertFrom-Json
  $chunkLen = $tj.chunkEnd - $tj.chunkStart; $wallLen = $tj.runEnd - $tj.runStart
  Check "the capture is running while the tone plays ($($tj.stateWhilePlaying), $($tj.source))" ($tj.stateWhilePlaying -eq 'ok')
  Check "the captured sound is not silent (peak $($tj.peak), loudest 10 ms RMS $($tj.rmsMax))" ($tj.rmsMax -gt 100)
  Check "the chunk's length equals the wall clock within 50 ms ($(F3 ($chunkLen/1000)) s vs $(F3 ($wallLen/1000)) s)" (Near $chunkLen $wallLen 50)
  $toneLen = $tj.toneOff - $tj.toneOn
  Check "the tone is 5.000 s long in the capture within 30 ms ($(F3 ($toneLen/1000)) s: the sound card's clock and the wall clock agree)" (Near $toneLen 5000 30)
  $lat = $tj.toneOn - $tj.asked
  Check "the tone is heard 0 - 300 ms after it was asked for ($([math]::Round($lat)) ms: the player's own start-up, not the recorder)" ($lat -ge 0 -and $lat -le 300)
  Note "device frames delivered: $($tj.status.runFrames) ($(F3 ($tj.status.runFrames/48000)) s) in a $(F3 (($tj.status.runEndMs - $tj.status.runStartMs)/1000)) s run"
  $cpuPct = 100.0 * $tj.cpuMs / [math]::Max(1, $wallLen)
  Check "the capture is light: $([math]::Round($tj.cpuMs)) ms of processor time in $(F3 ($wallLen/1000)) s, $([math]::Round($cpuPct, 2)) % of one core (player included)" ($cpuPct -lt 5)
  $pcm = $tj.pcm
}

# c. that sound + a test video -> mp4 the way the recorder does it (picture copied, sound AAC)
Section '1c. sound + picture in one mp4: 1 video + 1 audio stream, lengths within 100 ms'
if (-not $pcm) { $pcm = Join-Path $tmp 'made.pcm'; $null = Tool $ffmpeg "-v error -y -f lavfi -i sine=frequency=440:sample_rate=48000:duration=6 -ac 2 -f s16le `"$pcm`"" 60000; Note 'using a made-up 6 s tone (1b was skipped)' }
$secs = (Get-Item $pcm).Length / 192000.0
$vts = Join-Path $tmp 'v.ts'; $null = Tool $ffmpeg ("-v error -y -f lavfi -i testsrc2=size=640x360:rate=60 -t " + (F3 $secs) + " -c:v libx264 -preset ultrafast -g 60 -bf 0 -f mpegts `"$vts`"") 120000
$mp4 = Join-Path $tmp 'mux.mp4'
$m = Tool $ffmpeg "-hide_banner -y -loglevel error -i `"$vts`" -f s16le -ar 48000 -ac 2 -i `"$pcm`" -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 160k -threads 1 -movflags +faststart -f mp4 `"$mp4`"" 120000
$s = Streams $mp4
Check "the mux worked (exit $($m.Code)) and ffmpeg -i shows 1 video + 1 audio stream ($($s.text))" ($m.Code -eq 0 -and $s.video -eq 1 -and $s.audio -eq 1)
Check "the two streams are the same length within 100 ms (video $(F3 $s.vdur) s, sound $(F3 $s.adur) s)" (Near $s.vdur $s.adur 0.1)
}

# =====================================================================================================
$hook = Join-Path $root 'dash\test-hook.on'; $lock = Join-Path $root 'dash\deploy.lock'
$tdir = Join-Path $root 'vault-test'; $recDir = Join-Path $tdir 'vault\rec'; $clipDir = Join-Path $tdir 'vault\clips'; $sessDir = Join-Path $tdir 'vault\sessions'
$live = $false
if (Want 2) {
  $st0 = $null; try { $st0 = J '/vault/recorder' } catch { }
  if (-not $st0 -or -not ($st0.PSObject.Properties.Name -contains 'sound')) { $script:skipped += '2 irdash'; Note 'SKIPPED part 2: irdash on 8199 is not a build with the sound code (dash\build.ps1 first, when the sim is off)' }
  else { $live = $true }
}
if ($live) {
Enter-TestLock 'audio'
for ($i = 0; $i -lt 20 -and (Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 15; $i++) { 'waiting for the deploy lock (' + (Get-Content $lock) + ')'; Start-Sleep -Seconds 60 }
Set-Content $lock ('audio ' + (Get-Date).ToString('HH:mm:ss'))
Set-Content $hook 'audio test'
if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $tdir 'src') | Out-Null
$null = J '/vault/test/sandbox?on=1&reset=1'
function Fake($h) { $q = ($h.Keys | ForEach-Object { "$_=" + ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $h[$_])) }) -join '&'; $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/frame?$q" -TimeoutSec 8 }
function St { J '/vault/test/rec?cmd=status' }
function Wait-For($sb, $secs, $everyMs = 300) { $until = (Get-Date).AddSeconds($secs); while ((Get-Date) -lt $until) { if (& $sb) { return $true }; Start-Sleep -Milliseconds $everyMs }; return $false }

Section '2a. a two-stint session with test clicks: sound in the session, a lap clip and an incident clip, in step with the picture'
$null = J '/vault/test/rec?cmd=on&keep=120&seg=5&grace=2&minlap=3&audio=synth'
$null = J '/vault/test/yaml'
Fake @{ IsOnTrack = 1; SessionUniqueID = 901; SessionNum = 0; Lap = 1; LapDistPct = 0.5; LapCurrentLapTime = 5.0; LapLastLapTime = 0.0; OnPitRoad = 0; PlayerTrackSurface = 3; SessionTime = 100.0; PlayerCarMyIncidentCount = 0 }
$ok = Wait-For { (St).running } 12
Check 'the recorder runs' $ok
$ok = Wait-For { (St).capture.audio -eq 'ok' } 8
$s1 = St
Check "the capture verdict carries the sound: audio=$($s1.capture.audio) ($($s1.capture.audioSource))" ($ok -and $s1.capture.audioSource -eq 'test clicks')
Start-Sleep -Seconds 9
$lapStart = (NowMs) - 6000
$lr = J ("/vault/test/rec?cmd=lap&n=1&start=$lapStart&end=$($lapStart + 5000)&time=5.000")
Fake @{ PlayerCarMyIncidentCount = 2 }
Start-Sleep -Seconds 8
Fake @{ IsOnTrack = 0 }
$ok = Wait-For { -not (St).running } 12
Check 'leaving the car stops picture and sound (audio idle)' ($ok -and (St).capture.audio -eq 'idle')
Start-Sleep -Seconds 3
Fake @{ IsOnTrack = 1; SessionUniqueID = 901; SessionNum = 0 }
$ok = Wait-For { (St).running } 12
Check 'back in the car: recording again' $ok
Start-Sleep -Seconds 12
$sid = (St).session
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
$sp = Join-Path $sessDir ($sid + '.mp4'); $sj = Join-Path $sessDir ($sid + '.json')
$ok = Wait-For { (Test-Path $sp) -and (Test-Path $sj) } 90
Check 'the session is written' $ok
$side = Get-Content $sj -Raw | ConvertFrom-Json
Check "the sidecar says audio=$($side.audio), audioSource=$($side.audioSource)" ($side.audio -eq 'ok' -and $side.audioSource -eq 'test clicks')
$se = Sync-Errors $sp; $ss = $se.streams
Check "the session mp4 has 1 video + 1 audio stream ($($ss.text))" ($ss.video -eq 1 -and $ss.audio -eq 1)
Check "picture and sound are the same length within 100 ms (video $(F3 $ss.vdur) s, sound $(F3 $ss.adur) s)" (Near $ss.vdur $ss.adur 0.1)
$mx = if ($se.errs.Count) { ($se.errs | ForEach-Object { [math]::Abs($_) } | Measure-Object -Maximum).Maximum } else { 999 }
$expClicks = [math]::Floor($ss.vdur) - 1
Check "every whole-second click lands on the picture of that second within 20 ms, across the stint join ($($se.errs.Count) clicks, worst $([math]::Round($mx, 1)) ms)" ($se.errs.Count -ge $expClicks -and $mx -le 20)
Note ('click - picture (ms): ' + (($se.errs | ForEach-Object { [math]::Round($_, 1) }) -join ' '))

$clipId = $lr.clipId; $cp = Join-Path $clipDir ($clipId + '.mp4'); $cj = Join-Path $clipDir ($clipId + '.json')
Check "the lap clip was cut ($clipId)" ((Test-Path $cp) -and (Test-Path $cj))
if (Test-Path $cj) {
  $cside = Get-Content $cj -Raw | ConvertFrom-Json
  $ce = Sync-Errors $cp; $cs = $ce.streams
  $cmx = if ($ce.errs.Count) { ($ce.errs | ForEach-Object { [math]::Abs($_) } | Measure-Object -Maximum).Maximum } else { 999 }
  Check "the lap clip has sound (audio=$($cside.audio); $($cs.text))" ($cside.audio -eq 'ok' -and $cs.audio -eq 1 -and $cs.video -eq 1)
  Check "the lap clip's clicks land on their pictures within 20 ms ($($ce.errs.Count) clicks, worst $([math]::Round($cmx, 1)) ms)" ($ce.errs.Count -ge 4 -and $cmx -le 20)
  Check "the lap clip's sound and picture lengths agree within 100 ms ($(F3 $cs.vdur) / $(F3 $cs.adur))" (Near $cs.vdur $cs.adur 0.1)
}
$inc = @(Get-ChildItem $clipDir -Filter 'inc-*.json' -ErrorAction SilentlyContinue)
Check 'an incident clip was cut' ($inc.Count -ge 1)
if ($inc.Count) {
  $ij = Get-Content $inc[0].FullName -Raw | ConvertFrom-Json; $is = Streams ([IO.Path]::ChangeExtension($inc[0].FullName, '.mp4'))
  Check "the incident clip has sound (audio=$($ij.audio); $($is.text))" ($ij.audio -eq 'ok' -and $is.audio -eq 1)
}
# the Debrief corner clips: -ss/-t before -i, -c copy (dash\src\debrief.cs CvRun)
$dc = Join-Path $tmp 'corner.mp4'
$null = Tool $ffmpeg "-hide_banner -y -loglevel error -ss 4.000 -t 6.000 -i `"$sp`" -c copy -movflags +faststart -f mp4 `"$dc`"" 60000
$ds = Streams $dc
Check "a Debrief-style -c copy cut from the session keeps the sound ($($ds.text))" ($ds.audio -eq 1 -and $ds.video -eq 1)
$ok = Wait-For { @(Get-ChildItem $recDir -Filter 'aud-*.pcm' -ErrorAction SilentlyContinue).Count -eq 0 } 60 1000
Check "the sound chunks are gone with the segments ($(@(Get-ChildItem $recDir -Filter 'aud-*.pcm' -ErrorAction SilentlyContinue).Count) left, $(@(Get-ChildItem $recDir -Filter '*.ts' -ErrorAction SilentlyContinue).Count) .ts left)" $ok
Check 'no temporary sound files are left in the rec folder' (@(Get-ChildItem $recDir -Filter '*.pcm' -ErrorAction SilentlyContinue).Count -eq 0)
$null = J '/vault/test/rec?cmd=off'

Section '2b. sound off: picture only, and the sidecar says audio=none'
$null = J '/vault/test/rec?cmd=on&keep=120&seg=5&grace=2&minlap=3&audio=off'
$null = J '/vault/test/yaml'
Fake @{ IsOnTrack = 1; SessionUniqueID = 902; SessionNum = 0; PlayerCarMyIncidentCount = 0; SessionTime = 100.0 }
$ok = Wait-For { (St).running } 12
Start-Sleep -Seconds 8
$s2 = St
Check "with the sound off the verdict says audio=$($s2.capture.audio) (not failed, so no 'no sound' warning)" ($s2.capture.audio -eq 'off')
$sid2 = $s2.session
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
$sp2 = Join-Path $sessDir ($sid2 + '.mp4'); $sj2 = Join-Path $sessDir ($sid2 + '.json')
$ok = Wait-For { (Test-Path $sp2) -and (Test-Path $sj2) } 60
$s2s = Streams $sp2; $side2 = Get-Content $sj2 -Raw | ConvertFrom-Json
Check "picture only: 1 video, 0 audio, sidecar audio=$($side2.audio)" ($ok -and $s2s.video -eq 1 -and $s2s.audio -eq 0 -and $side2.audio -eq 'none')
$null = J '/vault/test/rec?cmd=off'

Section '2c. a capture that cannot start says failed (HOME / REC pill then add "no sound")'
$null = J '/vault/test/rec?cmd=on&keep=60&seg=5&grace=2&minlap=3&audio=pid:999999'
$null = J '/vault/test/yaml'
Fake @{ IsOnTrack = 1; SessionUniqueID = 903; SessionNum = 0; PlayerCarMyIncidentCount = 0; SessionTime = 100.0 }
$ok = Wait-For { (St).capture.state -eq 'recording' } 25
$s3 = St
Check "the picture records (state $($s3.capture.state)) and the sound says audio=$($s3.capture.audio)" ($ok -and $s3.capture.audio -eq 'failed')
$sid3 = $s3.session
$null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8
$sj3 = Join-Path $sessDir ($sid3 + '.json')
$ok = Wait-For { Test-Path $sj3 } 60
Check 'that session is still written, picture only, audio=none' ($ok -and (Get-Content $sj3 -Raw | ConvertFrom-Json).audio -eq 'none')
$null = J '/vault/test/rec?cmd=off'

Section '2d. a real browser decodes the sound; the changed page scripts parse'
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
if (Test-Path $chrome) {
  $prof = Join-Path $env:TEMP ('audio-test-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9374
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", '--autoplay-policy=no-user-gesture-required', '--mute-audio', 'about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  try {
    $page = $null
    for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
    $ws = New-Object System.Net.WebSockets.ClientWebSocket; $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(); $script:cid = 0
    function Cdp($method, $params) {
      $script:cid++; $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $script:cid; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
      $null = $ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
      while ($true) { $buf = New-Object byte[] 262144; $sb = New-Object Text.StringBuilder
        do { $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf); $r = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None); $null = $r.Wait(); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Result.Count)) } while (-not $r.Result.EndOfMessage)
        $o = $sb.ToString() | ConvertFrom-Json; if ($o.id -eq $script:cid) { return $o } }
    }
    function Ev($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return 'js error: ' + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
    $null = Cdp 'Page.navigate' @{ url = "$api/v2/vault.html?nothing=1" }; Start-Sleep -Seconds 3
    $js = "(async()=>{const v=document.createElement('video');v.src='/api/rec/session-video?id=" + [uri]::EscapeDataString($sid) + "';document.body.appendChild(v);v.muted=false;await new Promise(r=>{v.onloadeddata=r;setTimeout(r,8000)});try{await v.play()}catch(e){return 'play: '+e.name}await new Promise(r=>setTimeout(r,2500));const a=v.webkitAudioDecodedByteCount||0;v.pause();return JSON.stringify({t:v.currentTime,a:a,muted:v.muted})})()"
    $res = Ev $js
    $rj = $null; try { $rj = $res | ConvertFrom-Json } catch { }
    # webkitAudioDecodedByteCount counts the COMPRESSED sound bytes decoded: the test clicks are mostly silence (~6 kbit/s), so 2.5 s is ~2 kB
    Check "Chrome plays the session file with sound, not muted (decoded $(if ($rj) { $rj.a } else { $res }) bytes of AAC in $(if ($rj) { [math]::Round($rj.t, 1) }) s)" ($rj -and $rj.a -gt 1000 -and $rj.t -gt 1 -and -not $rj.muted)
    $syn = Ev "(async()=>{const out=[];for(const f of ['workbench-video.js','home.js','tv.js','debrief-v4.js','vault.js']){try{new Function(await (await fetch('/v2/'+f,{cache:'no-store'})).text());out.push(f+' ok')}catch(e){out.push(f+' '+e.message)}}return out.join(', ')})()"
    Check "the changed scripts parse ($syn)" ($syn -notmatch 'js error' -and ([regex]::Matches($syn, ' ok').Count -eq 5))
  } finally {
    try { $ws.Dispose() } catch { }; try { $p | Stop-Process -Force } catch { }
    Start-Sleep -Milliseconds 400
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$prof*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    try { Remove-Item -LiteralPath $prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
} else { Note 'no Chrome: the browser check is skipped' }
}

}
finally {
  if ($live) {
    try { $null = J '/vault/test/rec?cmd=off' } catch { }
    try { $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 8 } catch { }
    try { $null = J '/vault/test/sandbox?on=0' } catch { }
    Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*vault-test*' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    Remove-Item $hook -Force -ErrorAction SilentlyContinue
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Exit-TestLock
    if (-not $Keep) { try { if (Test-Path $tdir) { Remove-Item $tdir -Recurse -Force } } catch { } }
  }
  if (-not $Keep) { try { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { } } else { "  info  -Keep: files stay in $tmp and $tdir" }
}
$sk = if ($skipped.Count) { ' Skipped: ' + ($skipped -join ', ') + '.' } else { '' }
"$pass passed, $fail failed.$sk $([math]::Round($swAll.Elapsed.TotalSeconds, 0)) s"
if ($fail -gt 0) { exit 1 }
