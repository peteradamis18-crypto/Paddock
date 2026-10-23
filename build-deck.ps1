# Builds the "iRacing GT3" Stream Deck XL profile: a MAIN page (one row per phase of a session) and a MORE
# page (MORE / BACK keys switch pages), plus one small exe per key in .\keys (each looks up its command in
# keys\keys.map). Layout = docs\research\deck-v2-review.md "Corrected MAIN grid" (C-31). Keys whose feature is not
# built stay OFF the deck (Later); tests\keys-test.ps1 checks that every key on the pages answers.
#   powershell -ExecutionPolicy Bypass -File build-deck.ps1             (Stream Deck must be closed)
#   powershell -ExecutionPolicy Bypass -File build-deck.ps1 -Preview    (only renders C:\Temp\preview: MAIN.png, MORE.png,
#                                                                         layout.tsv, keys.map; touches nothing else)
param([switch]$Preview)
$ErrorActionPreference = 'Stop'
$previewRun = Join-Path ([IO.Path]::GetTempPath()) ('PaddockPreview-' + [guid]::NewGuid().ToString('N'))
if ($Preview) { New-Item -ItemType Directory -Force $previewRun | Out-Null }
Add-Type -AssemblyName System.Drawing
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe   = Join-Path $here 'irdeck.exe'
$keys  = Join-Path $here 'keys'
$sdRoot = "$env:APPDATA\Elgato\StreamDeck\ProfilesV3"
$profId = '65E017A2-2219-43EE-A4E4-44D505F5B406'   # the profile your deck is already set to
$profDir = "$sdRoot\$profId.sdProfile"
$u8 = New-Object Text.UTF8Encoding $false
function G { [guid]::NewGuid().ToString() }

# ---------- colours: six, one per kind of job (2026-10 plan) ----------
#   go = gets you driving, nav = opens a screen, ses = session actions, car = car & pit stop,
#   stop = ends something (always far right), talk = chat, sound, PC
$C = @{ go='#1E9E3F'; nav='#2E6FD8'; ses='#C2570C'; car='#0E8F9C'; stop='#C62F2F'; talk='#4B5563' }

# ---------- icon drawing ----------
function Hex($h) { [Drawing.ColorTranslator]::FromHtml($h) }
function Fit($g, $text, $max, $min, $maxW) {
  for ($s = $max; $s -ge $min; $s--) {
    $f = New-Object Drawing.Font('Segoe UI', $s, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    if ($g.MeasureString($text, $f).Width -le $maxW) { return $f }
    $f.Dispose()
  }
  return (New-Object Drawing.Font('Segoe UI', $min, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel))
}
function Draw-Glyph($g, $name, $cx, $cy, $bg) {
  $w = [Drawing.Color]::White
  $pen = New-Object Drawing.Pen($w, 6); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
  $thin = New-Object Drawing.Pen($w, 4); $thin.StartCap = 'Round'; $thin.EndCap = 'Round'
  $fill = New-Object Drawing.SolidBrush($w)
  $bgBrush = New-Object Drawing.SolidBrush($bg)
  function P($x, $y) { New-Object Drawing.PointF($x, $y) }
  switch ($name) {
    'play'    { $g.FillPolygon($fill, @((P ($cx-12) ($cy-20)), (P ($cx-12) ($cy+20)), (P ($cx+22) $cy))) }
    'wheel'   { $g.DrawEllipse($pen, $cx-22, $cy-22, 44, 44); $g.FillEllipse($fill, $cx-6, $cy-6, 12, 12)
                $g.DrawLine($thin, $cx-22, $cy, $cx-6, $cy); $g.DrawLine($thin, $cx+6, $cy, $cx+22, $cy); $g.DrawLine($thin, $cx, $cy+6, $cx, $cy+22) }
    'exit'    { $g.DrawLines($pen, @((P ($cx-2) ($cy-22)), (P ($cx-22) ($cy-22)), (P ($cx-22) ($cy+22)), (P ($cx-2) ($cy+22))))
                $g.DrawLine($pen, $cx-8, $cy, $cx+22, $cy); $g.FillPolygon($fill, @((P ($cx+14) ($cy-12)), (P ($cx+32) $cy), (P ($cx+14) ($cy+12)))) }
    'power'   { $g.DrawArc($pen, $cx-20, $cy-16, 40, 40, -60, 300); $g.DrawLine($pen, $cx, $cy-26, $cx, $cy-2) }
    'home'    { $g.DrawLines($pen, @((P ($cx-24) ($cy-2)), (P $cx ($cy-24)), (P ($cx+24) ($cy-2))))
                $g.DrawLines($pen, @((P ($cx-16) ($cy-8)), (P ($cx-16) ($cy+22)), (P ($cx+16) ($cy+22)), (P ($cx+16) ($cy-8)))) }
    'flag'    { $g.DrawLine($pen, $cx-20, $cy+24, $cx-20, $cy-24)
                for ($r = 0; $r -lt 3; $r++) { for ($q = 0; $q -lt 4; $q++) { if ((($r + $q) % 2) -eq 0) { $g.FillRectangle($fill, $cx-16+$q*10, $cy-22+$r*10, 10, 10) } } }
                $g.DrawRectangle($thin, $cx-16, $cy-22, 40, 30) }
    'watch'   { $g.DrawEllipse($pen, $cx-20, $cy-16, 40, 40); $g.DrawLine($pen, $cx, $cy-26, $cx, $cy-18); $g.DrawLine($thin, $cx, $cy+4, $cx+10, $cy-6) }
    'pump'    { $g.DrawRectangle($pen, $cx-20, $cy-24, 26, 48); $g.FillRectangle($fill, $cx-14, $cy-17, 14, 12)
                $g.DrawLine($pen, $cx-26, $cy+24, $cx+12, $cy+24)
                $g.DrawLines($thin, @((P ($cx+6) ($cy-14)), (P ($cx+18) ($cy-14)), (P ($cx+18) ($cy+10)), (P ($cx+26) ($cy+10)), (P ($cx+26) ($cy-8)))) }
    'cross'   { $g.DrawEllipse($pen, $cx-24, $cy-24, 48, 48); $g.DrawLine($pen, $cx-12, $cy, $cx+12, $cy); $g.DrawLine($pen, $cx, $cy-12, $cx, $cy+12) }
    'clear'   { $g.DrawEllipse($pen, $cx-22, $cy-22, 44, 44); $g.DrawLine($pen, $cx-15, $cy+15, $cx+15, $cy-15) }
    'chat'    { $g.DrawRectangle($pen, $cx-26, $cy-20, 52, 34); $g.FillPolygon($fill, @((P ($cx-10) ($cy+14)), (P ($cx-20) ($cy+28)), (P ($cx+4) ($cy+14))))
                foreach ($dx in -12, 0, 12) { $g.FillEllipse($fill, $cx+$dx-3, $cy-6, 6, 6) } }
    'speaker' { $g.FillPolygon($fill, @((P ($cx-26) ($cy-9)), (P ($cx-14) ($cy-9)), (P ($cx+0) ($cy-22)), (P ($cx+0) ($cy+22)), (P ($cx-14) ($cy+9)), (P ($cx-26) ($cy+9))))
                $g.DrawArc($thin, $cx-4, $cy-12, 18, 24, -55, 110); $g.DrawArc($thin, $cx-6, $cy-22, 32, 44, -55, 110) }
    'mute'    { $g.FillPolygon($fill, @((P ($cx-26) ($cy-9)), (P ($cx-14) ($cy-9)), (P ($cx+0) ($cy-22)), (P ($cx+0) ($cy+22)), (P ($cx-14) ($cy+9)), (P ($cx-26) ($cy+9))))
                $g.DrawLine($pen, $cx+8, $cy-10, $cx+26, $cy+10); $g.DrawLine($pen, $cx+26, $cy-10, $cx+8, $cy+10) }
    'note'    { $g.FillEllipse($fill, $cx-20, $cy+6, 18, 14); $g.FillEllipse($fill, $cx+8, $cy+2, 18, 14)
                $g.DrawLine($thin, $cx-4, $cy+12, $cx-4, $cy-20); $g.DrawLine($thin, $cx+24, $cy+8, $cx+24, $cy-24); $g.DrawLine($pen, $cx-4, $cy-20, $cx+24, $cy-24) }
    'pp'      { $g.FillPolygon($fill, @((P ($cx-26) ($cy-18)), (P ($cx-26) ($cy+18)), (P ($cx+2) $cy))); $g.FillRectangle($fill, $cx+8, $cy-18, 7, 36); $g.FillRectangle($fill, $cx+19, $cy-18, 7, 36) }
    'next'    { $g.FillPolygon($fill, @((P ($cx-26) ($cy-18)), (P ($cx-26) ($cy+18)), (P ($cx-4) $cy))); $g.FillPolygon($fill, @((P ($cx-4) ($cy-18)), (P ($cx-4) ($cy+18)), (P ($cx+18) $cy))); $g.FillRectangle($fill, $cx+18, $cy-18, 7, 36) }
    'prev'    { $g.FillPolygon($fill, @((P ($cx+26) ($cy-18)), (P ($cx+26) ($cy+18)), (P ($cx+4) $cy))); $g.FillPolygon($fill, @((P ($cx+4) ($cy-18)), (P ($cx+4) ($cy+18)), (P ($cx-18) $cy))); $g.FillRectangle($fill, $cx-25, $cy-18, 7, 36) }
    'globe'   { $g.DrawEllipse($pen, $cx-24, $cy-24, 48, 48); $g.DrawEllipse($thin, $cx-10, $cy-24, 20, 48); $g.DrawLine($thin, $cx-24, $cy, $cx+24, $cy) }
    'lock'    { $g.DrawArc($pen, $cx-12, $cy-26, 24, 28, 180, 180); $g.DrawLine($pen, $cx-12, $cy-12, $cx-12, $cy-4); $g.DrawLine($pen, $cx+12, $cy-12, $cx+12, $cy-4); $g.FillRectangle($fill, $cx-20, $cy-4, 40, 28) }
    'moon'    { $g.FillEllipse($fill, $cx-22, $cy-22, 44, 44); $g.FillEllipse($bgBrush, $cx-8, $cy-30, 40, 40) }
    'restart' { $g.DrawArc($pen, $cx-22, $cy-22, 44, 44, -60, 300); $g.FillPolygon($fill, @((P ($cx+4) ($cy-30)), (P ($cx+20) ($cy-20)), (P ($cx+4) ($cy-10)))) }
    'camera'  { $g.DrawRectangle($pen, $cx-26, $cy-14, 52, 36); $g.FillRectangle($fill, $cx-10, $cy-22, 20, 8); $g.DrawEllipse($pen, $cx-10, $cy-6, 20, 20) }
    'monitor' { $g.DrawRectangle($pen, $cx-26, $cy-22, 52, 34); $g.DrawLine($pen, $cx, $cy+12, $cx, $cy+22); $g.DrawLine($pen, $cx-14, $cy+22, $cx+14, $cy+22) }
    'eye'     { $g.DrawArc($pen, $cx-28, $cy-24, 56, 48, 210, 120); $g.DrawArc($pen, $cx-28, $cy-24, 56, 48, 30, 120); $g.FillEllipse($fill, $cx-9, $cy-9, 18, 18) }
    'info'    { $g.DrawEllipse($pen, $cx-24, $cy-24, 48, 48); $g.FillEllipse($fill, $cx-4, $cy-15, 8, 8); $g.DrawLine($pen, $cx, $cy-2, $cx, $cy+13) }
    'folder'  { $g.DrawLines($pen, @((P ($cx-26) ($cy+20)), (P ($cx-26) ($cy-18)), (P ($cx-6) ($cy-18)), (P ($cx+2) ($cy-10)), (P ($cx+26) ($cy-10)), (P ($cx+26) ($cy+20)), (P ($cx-26) ($cy+20)))) }
    'left'    { $g.FillPolygon($fill, @((P ($cx-22) $cy), (P ($cx+14) ($cy-22)), (P ($cx+14) ($cy+22)))) }
    'up'      { $g.FillPolygon($fill, @((P $cx ($cy-22)), (P ($cx-22) ($cy+14)), (P ($cx+22) ($cy+14)))) }
    'down'    { $g.FillPolygon($fill, @((P $cx ($cy+22)), (P ($cx-22) ($cy-14)), (P ($cx+22) ($cy-14)))) }
  }
}
function New-Icon($path, $t1, $t2, $hex, $glyph) {
  $bmp = New-Object Drawing.Bitmap 144, 144, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.PixelOffsetMode = 'HighQuality'
  $c = Hex $hex
  $top = [Drawing.Color]::FromArgb(255, [Math]::Min(255, $c.R+34), [Math]::Min(255, $c.G+34), [Math]::Min(255, $c.B+34))
  $br = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Rectangle 0, 0, 144, 144), $top, $c, 90)
  $g.FillRectangle($br, 0, 0, 144, 144)
  $fmt = New-Object Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
  $white = [Drawing.Brushes]::White
  $mid = [Drawing.Color]::FromArgb(255, [int](($top.R + $c.R) / 2), [int](($top.G + $c.G) / 2), [int](($top.B + $c.B) / 2))
  if ($glyph -and -not $t1 -and -not $t2) {
    Draw-Glyph $g $glyph 72 72 $mid
  } elseif ($glyph) {
    Draw-Glyph $g $glyph 72 40 $mid
    $f1 = Fit $g $t1 30 15 128; $g.DrawString($t1, $f1, $white, (New-Object Drawing.RectangleF 0, 76, 144, 36), $fmt)
    if ($t2) { $f2 = Fit $g $t2 22 12 128; $g.DrawString($t2, $f2, $white, (New-Object Drawing.RectangleF 0, 110, 144, 28), $fmt) }
  } elseif ($t2) {
    $f1 = Fit $g $t1 44 18 130; $g.DrawString($t1, $f1, $white, (New-Object Drawing.RectangleF 0, 22, 144, 56), $fmt)
    $f2 = Fit $g $t2 26 13 128; $g.DrawString($t2, $f2, $white, (New-Object Drawing.RectangleF 0, 82, 144, 40), $fmt)
  } else {
    $f1 = Fit $g $t1 40 16 130; $g.DrawString($t1, $f1, $white, (New-Object Drawing.RectangleF 0, 20, 144, 104), $fmt)
  }
  $g.Dispose(); $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

# ---------- one exe per key ----------
New-Item -ItemType Directory $keys -Force | Out-Null
$keyMap = [ordered]@{}
function Lnk($name, $argString) {
  $script:keyMap[$name] = $argString   # -Preview records the plan too (C:\Temp\preview\keys.map, read by tests\keys-test.ps1)
  if ($Preview) { return "(preview)" }
  $p = Join-Path $keys "$name.exe"
  # copy only when different, so a key that is running right now never blocks the build
  if (-not (Test-Path -LiteralPath $p) -or (Get-FileHash -LiteralPath $p).Hash -ne (Get-FileHash -LiteralPath $exe).Hash) {
    try { Copy-Item -LiteralPath $exe -Destination $p -Force } catch { Write-Warning "key $name is in use; it keeps its current exe until next build" }
  }
  return $p
}

# ---------- key definitions:  'col,row' = K title1 title2 colour glyph action ----------
function K($t1, $t2, $col, $glyph, $act) { @{ t1 = $t1; t2 = $t2; col = $C[$col]; glyph = $glyph; act = $act } }
function L($name, $a) { @{ lnk = $name; args = $a } }
# Live keys drawn by the iRaceDeck plugin (Session Info action); mode picks the number shown.
# $big / $small are only the example shown on the -Preview picture (the plugin draws the real number on the deck).
function Live($mode, $extra, $big, $small) { $s = [ordered]@{ mode = $mode }; foreach ($k in $extra.Keys) { $s[$k] = $extra[$k] }; @{ live = $true; settings = $s; big = $big; small = $small } }
# A key whose feature is not built yet: drawn on the -Preview picture only, the cell stays EMPTY on the real deck (no dead keys).
function Later($why) { @{ later = $why } }
$back = K 'BACK' '' 'nav' 'left' @{ page = 'previous' }
$minus = [string][char]0x2212   # a real minus sign for VOL; the script file itself stays plain ASCII

# MAIN (DK-2, 2026-10-11; docs\deck\council-fable.md section 3, adopted by docs\deck\DECK-v4.md):
#   row 1 get into a car, row 2 in the session, row 3 pit and car, row 4 talk, sound and live numbers.
#   One key = one finished job. A key whose live state the add-on draws (DK-4) carries no static subtitle
#   (no "on / off", no "last settings"). Keys that end something sit right, red, and need a second press (x2).
#   DK-2 left cell 7,3 empty. K-01 uses it for KIDS. DK-2b (Peter, 2026-10-11) filled 6,0 (OFFICIAL) and 6,2 (CAR TRACK).
$main = [ordered]@{
  # DECK v2 (2026-10-23, docs\design\deck-v2\deck-plan.html, Peter: "yes, build it"). Every key is ONE press from any state:
  # the key works out where he is. No x2 keys: the thing that ends a session sits behind the LEAVE page, and opening that page is the check.
  # row 1 - start something
  '0,0' = K 'HOME' '' 'go' 'power'                             (L 'rig-on'          'rigon')          # rig up: RIG ON; rig already up: HOME. Also the 2nd key of the kids unlock (KIDS, then HOME)
  '1,0' = K 'LAST' 'DRIVE' 'go' $null                           (L 'last-drive'      'mydrive start')  # your last car + track as a test drive (MY DRIVE's choice), same as HOME's gold button
  '2,0' = K 'AI RACE' '' 'go' 'play'                           (L 'ai-race'         'airace start')
  '3,0' = K 'CAR' 'TRACK' 'nav' 'folder'                        @{ plugin = 'com.peter.rigintro.mydrive'; name = 'Car Track' }   # change the car & track LAST DRIVE / AI RACE use
  '4,0' = K 'OFFICIAL' '' 'go' 'flag'                          (L 'official'        'official')
  '5,0' = K 'FRIENDS' '' 'go' 'wheel'                          @{ plugin = 'com.peter.rigintro.friends'; name = 'Friends mode' }
  # kids mode: locks keyboard + mouse, works while the kids drive; the deck then answers only GET IN, RESET CAR, RESTART, VOL. Unlock: KIDS then HOME.
  '6,0' = K 'KIDS' '' 'talk' 'lock'                            (L 'kids'            'kids')
  '7,0' = K 'MORE' '' 'nav' 'next'                             @{ page = 'next' }
  # row 2 - the session loop (GET OUT -> RESTART -> GET IN was 3 presses and 2 of them failed; each now finishes the job)
  '0,1' = K 'GET IN' '' 'go' 'play'                            (L 'smart'           'smart')          # always: no sim = starts the last drive; session screen/replay = Drive
  '1,1' = K 'GET OUT' '' 'ses' 'exit'                          (L 'get-out'         'getout')         # still rolling: waits for the car to stop (15 s), then out
  '2,1' = K 'RESET' 'CAR' 'ses' 'left'                          (L 'tow'             'tow')
  '3,1' = K 'RESTART' '' 'ses' 'restart'                       (L 'restart-race'    'restartrace')    # AI race: out, restart, back in. Test drive: pits + in the car
  '4,1' = K 'NEXT' 'SESSION' 'ses' 'next'                       (L 'skip-session'    'skip')           # practice -> qualify -> race; test drive: back to the menu
  '5,1' = K 'RACE' 'NOW' 'go' 'flag'                            (L 'race-now'        'racenow')        # from practice or qualify straight to the race
  '6,1' = K 'INSTANT' 'REPLAY' 'nav' 'camera'                   (Later 'instant replay of the last 30 s: not built yet')
  '7,1' = K 'LEAVE' '' 'stop' 'home'                           @{ page = 'previous' }               # opens the LEAVE page (QUIT TO MENU is one press there)
  # row 3 - pit and car, and the screens
  '0,2' = K 'FUEL TO' 'FINISH' 'car' 'pump'                     (L 'fuel-finish'     'chat say #autofuel')
  '1,2' = K 'TIRES' '' 'car' $null                             (L 'pit-tires'       'pittoggle tires')
  '2,2' = K 'FAST' 'REPAIR' 'car' 'cross'                       (L 'pit-fr'          'pittoggle fr')
  '3,2' = K 'CLEAR' 'PIT' 'ses' 'clear'                         (L 'pit-clear'       'pit clear')
  '4,2' = K 'OVERLAYS' '' 'nav' 'eye'                          @{ plugin = 'com.peter.rigintro.overlays'; name = 'Overlays' }
  '5,2' = K 'REVIEW' '' 'nav' 'info'                           (L 'debrief'         'dash debrief')
  '6,2' = K 'VAULT' '' 'nav' 'folder'                          (L 'vault'           'dash vault')
  '7,2' = K 'LAPS TO' 'EMPTY' 'car' $null                      (Live 'laps-to-empty' @{} '12' 'laps left')
  # row 4 - sound, talk, live numbers
  '0,3' = K ('VOL ' + $minus) '' 'talk' 'speaker'              (L 'vol-down'        'appvol game -10')   # the sim, its menu and the spotter, together
  '1,3' = K 'VOL +' '' 'talk' 'speaker'                        (L 'vol-up'          'appvol game +10')
  '2,3' = K 'MUTE' 'SPOTTER' 'talk' 'mute'                      (L 'mute-spotter'    'appvol mute spotter')
  '3,3' = K 'SORRY' '' 'talk' 'chat'                           (L 'say-sorry'       'chat say Sorry!')
  '4,3' = K 'THANKS' '' 'talk' 'chat'                          (L 'say-thanks'      'chat say Thanks!')
  '5,3' = K 'RELATIVE' '' 'talk' $null                         (L 'bb-f3'           'key --sim f3')
  '6,3' = K 'POSITION' 'CLASS' 'talk' $null                    (Live 'position' @{ positionType = 'class'; positionShowTotal = 'true' } 'P4' 'of 18')
  '7,3' = K 'INCIDENTS' '' 'talk' $null                        (Live 'incidents' @{} '2' 'incidents')
}

# LEAVE (the page BEFORE MAIN: MAIN's LEAVE key is "previous page", this page's BACK is "next page"). One big QUIT, no second press.
$leave = [ordered]@{
  '0,0' = K 'BACK' '' 'nav' 'left'                             @{ page = 'next' }
  '3,1' = K 'QUIT TO' 'MENU' 'stop' 'home'                      (L 'quit-main'       'quitmain')
  '4,1' = K 'QUIT TO' 'MENU' 'stop' 'home'                      (L 'quit-main2'      'quitmain')       # the same, twice as wide a target
  '0,3' = K 'KIDS' 'MODE' 'talk' 'lock'                        (L 'kids-leave'      'kids')            # hand the rig to the kids (Peter 2026-10-23: the blanks = kids mode and shut off PC)
  '6,3' = K 'SHUT' 'DOWN PC' 'stop' 'power'                     (L 'shutdown'        'power off')       # quits iRacing cleanly first, then turns the PC off
  '7,3' = K 'SLEEP' 'PC' 'stop' 'moon'                          (L 'sleep'           'power sleep')
}
# MORE (page 2): the rare keys and the ones that end something, plus the MAIN keys the new grid drops. BACK returns
# to MAIN. Nothing is lost: MARK SPOT / BACK TO SPOT are the old reset points, WIPE is the windscreen tear-off.
$more = [ordered]@{
  '0,0' = $back
  '2,0' = K 'GOOD' 'RACE' 'talk' 'chat'                           (L 'say-gg'          'chat say GG')
  '3,0' = K 'MUTE' '' 'talk' 'mute'                            (L 'mute'            'media mute')
  '4,0' = K 'SHOWCASE' '' 'nav' 'play'                         (L 'showcase'        'showcase')
  '5,0' = K 'SOUND' '' 'talk' 'speaker'                        @{ plugin = 'com.peter.rigintro.sound'; name = 'Sound' }   # the SOUND screen (C-39): game, spotter, music, speakers, ButtKicker, presets
  '7,0' = K 'LOCK' '' 'stop' 'lock'                            (L 'lock'            'power lock')   # one press, like every v2 key; it only locks Windows and sits on MORE, never on MAIN
  '0,1' = K 'MARK' 'SPOT' 'ses' 'flag'                         (L 'reset-save'      'key --sim ctrl+shift+f1')
  '1,1' = K 'BACK TO' 'SPOT' 'ses' 'restart'                   (L 'reset-run'       'key --sim ctrl+shift+f2')
  '2,1' = K 'REPLAY' '' 'nav' 'camera'                         @{ plugin = 'com.peter.rigintro.replay'; name = 'Replay' }
  '4,1' = K 'WIPE' '' 'car' $null                              (L 'pit-ws'          'pittoggle ws')   # windscreen tear-off
  '5,1' = K 'SEAT' 'LOWER' 'car' 'down'                        (L 'seat-down'       'key --sim ctrl+[')
  '6,1' = K 'SEAT' 'HIGHER' 'car' 'up'                         (L 'seat-up'         'key --sim ctrl+]')
  '0,2' = K 'TIMING' '' 'talk' $null                           (L 'bb-f1'           'key --sim f1')
  '1,2' = K 'STANDINGS' '' 'talk' $null                        (L 'bb-f2'           'key --sim f2')
  '2,2' = K 'FUEL' 'BOX' 'talk' $null                          (L 'bb-f4'           'key --sim f4')
  '3,2' = K 'TIRE' 'BOX' 'talk' $null                          (L 'bb-f5'           'key --sim f5')
  '4,2' = K 'IN-CAR' '' 'talk' $null                           (L 'bb-f8'           'key --sim f8')
  '5,2' = K 'WEATHER' '' 'talk' $null                          (L 'bb-f11'          'key --sim f11')
  '6,2' = K 'ANALYSIS' '' 'nav' 'info'                         @{ plugin = 'com.peter.rigintro.analysis'; name = 'Analysis' }   # moved off MAIN (DK-2), same screen
}
# ---------- write the profile ----------
if (-not $Preview) {
  if (Get-Process StreamDeck -ErrorAction SilentlyContinue) { throw "Close Stream Deck first (it only reads profiles when it starts)." }
  $dev = (Get-Content "$profDir\manifest.json" -Raw | ConvertFrom-Json).Device
  $oldPages = @(Get-ChildItem "$profDir\Profiles" -Directory -ErrorAction SilentlyContinue)   # removed only after the new pages are written
}
$ids = @{ main = G; more = G; leave = G; guest = G }
# One line per key, written next to the pictures in -Preview: page, col, row, line 1, line 2, kind, what it does.
# tests\keys-test.ps1 reads it, so the test never has to guess the layout from this script's text.
$layout = New-Object Collections.Generic.List[string]
function Add-Layout($page, $pos, $k, $kind, $what) {
  $cx, $ry = $pos.Split(',')
  $l1 = if ($k.act.live) { $k.act.big } else { $k.t1 }
  $l2 = if ($k.act.live) { $k.act.small } else { $k.t2 }
  $script:layout.Add((@($page, $cx, $ry, $l1, $l2, $kind, $what) -join "`t"))
}
# Preview only: a live key as the plugin will show it (big gold number, small word). The real number comes from the sim.
function New-LiveIcon($path, $big, $small) {
  $bmp = New-Object Drawing.Bitmap 144, 144, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.Clear([Drawing.Color]::Black)
  $gold = Hex '#F2C230'
  $pen = New-Object Drawing.Pen((Hex '#5A4A1A'), 3); $g.DrawRectangle($pen, 5, 5, 134, 134)
  $fmt = New-Object Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
  $fb = Fit $g $big 64 24 124; $g.DrawString($big, $fb, (New-Object Drawing.SolidBrush $gold), (New-Object Drawing.RectangleF 0, 18, 144, 70), $fmt)
  $fs = Fit $g $small 22 12 124; $g.DrawString($small, $fs, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 0, 92, 144, 34), $fmt)
  $g.Dispose(); $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
function Write-Page($pageId, $name, $keysDef) {
  $dir = if ($Preview) { Join-Path $previewRun $name } else { "$profDir\Profiles\$($pageId.ToUpper())" }
  New-Item -ItemType Directory "$dir\Images" -Force | Out-Null
  $actions = [ordered]@{}
  $soon = @()   # keys not built yet: on the picture, not on the deck
  foreach ($pos in $keysDef.Keys) {
    $k = $keysDef[$pos]
    $a = $k.act
    if ($a.later) {
      Add-Layout $name $pos $k 'later' $a.later
      if (-not $Preview) { continue }   # no dead keys: the cell stays empty on the real deck
      $soon += $pos
    }
    $img = (-join ((65..90) + (48..57) | Get-Random -Count 26 | % { [char]$_ })) + 'Z'
    if ($a.live -and $Preview) { New-LiveIcon "$dir\Images\$img.png" $a.big $a.small }
    else { New-Icon "$dir\Images\$img.png" $k.t1 $k.t2 $k.col $k.glyph }
    $state = [ordered]@{ FontFamily = ''; FontSize = 12; FontStyle = ''; FontUnderline = $false; Image = "Images/$img.png"; OutlineThickness = 2; ShowTitle = $false; Title = ''; TitleAlignment = 'bottom'; TitleColor = '#ffffff' }
    if ($a.later) {
      # preview only: nothing is written to the profile for this key
    } elseif ($a.live) {
      # iRaceDeck draws these keys itself with live data, so no image of ours
      Add-Layout $name $pos $k 'live' ('session-info:' + $a.settings.mode)
      $ls = [ordered]@{ FontSize = 14; TitleAlignment = 'bottom'; ShowTitle = $true; Title = '' }
      $act = [ordered]@{ ActionID = (G); LinkedTitle = $true; Name = 'Session Info'
        Plugin = [ordered]@{ Name = 'iRaceDeck'; UUID = 'com.iracedeck.sd.core'; Version = '3.5.0.2408' }
        Resources = $null; Settings = $a.settings; State = 0; States = @($ls); UUID = 'com.iracedeck.sd.core.session-info' }
    } elseif ($a.plugin) {
      # a key drawn and handled by our own Rig Intro add-on (deck-intro\install.ps1)
      Add-Layout $name $pos $k 'plugin' $a.plugin
      $act = [ordered]@{ ActionID = (G); LinkedTitle = $true; Name = $a.name
        Plugin = [ordered]@{ Name = 'Rig Intro'; UUID = 'com.peter.rigintro'; Version = '1.1.0.0' }
        Resources = $null; Settings = [ordered]@{}; State = 0; States = @($state); UUID = $a.plugin }
    } elseif ($a.page) {
      # Stream Deck's built-in page switching (MORE -> next page, BACK -> previous page)
      Add-Layout $name $pos $k 'page' $a.page
      $pn = if ($a.page -eq 'next') { 'Next Page' } else { 'Previous Page' }
      $act = [ordered]@{ ActionID = (G); LinkedTitle = $true; Name = $pn; Resources = $null; Settings = [ordered]@{}; State = 0; States = @($state); UUID = "com.elgato.streamdeck.page.$($a.page)" }
    } else {
      Add-Layout $name $pos $k 'key' ($a.lnk + '=' + $a.args)
      $path = Lnk $a.lnk $a.args
      $act = [ordered]@{ ActionID = (G); LinkedTitle = $true; Name = 'Open'; Resources = $null; Settings = [ordered]@{ path = "`"$path`"" }; State = 0; States = @($state); UUID = 'com.elgato.streamdeck.system.open' }
    }
    if (-not $a.later) { $actions[$pos] = $act }
    if ($Preview) { Copy-Item "$dir\Images\$img.png" "$dir\key_$($pos.Replace(',','_')).png" }
  }
  if ($Preview) {
    # the contact sheet: all 32 cells; an empty cell is a dark outline; SOON marks a key that is not on the real deck yet
    $sheet = New-Object Drawing.Bitmap (8*150+10), (4*150+10)
    $sg = [Drawing.Graphics]::FromImage($sheet); $sg.Clear([Drawing.Color]::Black)
    $sg.SmoothingMode = 'AntiAlias'; $sg.TextRenderingHint = 'AntiAliasGridFit'
    $edge = New-Object Drawing.Pen((Hex '#262626'), 2)
    for ($cc = 0; $cc -lt 8; $cc++) { for ($rr = 0; $rr -lt 4; $rr++) { $sg.DrawRectangle($edge, 10+$cc*150, 10+$rr*150, 139, 139) } }
    $badge = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    foreach ($pos in $keysDef.Keys) {
      $col, $row = $pos.Split(',') | % { [int]$_ }
      $im = [Drawing.Image]::FromFile("$dir\key_$($pos.Replace(',','_')).png"); $sg.DrawImage($im, 10+$col*150, 10+$row*150, 140, 140); $im.Dispose()
      if ($soon -contains $pos) {
        $sg.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(230, 0, 0, 0))), 10+$col*150+82, 10+$row*150+6, 52, 20)
        $sg.DrawString('SOON', $badge, (New-Object Drawing.SolidBrush (Hex '#F2C230')), 10+$col*150+88, 10+$row*150+8)
      }
    }
    $sg.Dispose(); $sheet.Save((Join-Path $previewRun "$name.png"), [Drawing.Imaging.ImageFormat]::Png); $sheet.Dispose()
    return
  }
  $pm = [ordered]@{ Controllers = @([ordered]@{ Actions = $actions; Type = 'Keypad' }); Icon = ''; Name = $name }
  [IO.File]::WriteAllText("$dir\manifest.json", ($pm | ConvertTo-Json -Depth 30), $u8)
}
Write-Page $ids.main 'MAIN' $main
# MORE is page 2 (MORE key on MAIN, BACK key here). Stream Deck's own page switching; the Pages list below names both.
Write-Page $ids.more 'MORE' $more
Write-Page $ids.leave 'LEAVE' $leave
if ($Preview) {
  # docs\deck\main-preview.png: the MAIN page as Peter sees it (black keys, gold labels, the real key text).
  # -Preview only; touches no Stream Deck profile and does not close Stream Deck.
  $pv = New-Object Drawing.Bitmap (8*150+10), (4*150+10)
  $pg = [Drawing.Graphics]::FromImage($pv); $pg.Clear([Drawing.Color]::Black)
  $pg.SmoothingMode = 'AntiAlias'; $pg.TextRenderingHint = 'AntiAliasGridFit'
  $gold = New-Object Drawing.SolidBrush (Hex '#F2C230')
  $edge = New-Object Drawing.Pen((Hex '#3A2F12'), 2)
  $pf = New-Object Drawing.StringFormat; $pf.Alignment = 'Center'; $pf.LineAlignment = 'Center'
  for ($cc = 0; $cc -lt 8; $cc++) { for ($rr = 0; $rr -lt 4; $rr++) { $pg.DrawRectangle($edge, 10+$cc*150, 10+$rr*150, 139, 139) } }
  foreach ($pos in $main.Keys) {
    $k = $main[$pos]; if ($k.act.later) { continue }
    $col, $row = $pos.Split(',') | % { [int]$_ }
    $t1 = if ($k.act.live) { $k.act.big } else { $k.t1 }
    $t2 = if ($k.act.live) { $k.act.small } else { $k.t2 }
    $cx = 10 + $col*150; $cy = 10 + $row*150
    if ($t1) {
      $f1 = Fit $pg $t1 30 13 126
      $ry = if ($t2) { $cy + 42 } else { $cy + 55 }
      $pg.DrawString($t1, $f1, $gold, (New-Object Drawing.RectangleF $cx, $ry, 140, 44), $pf)
    }
    if ($t2) { $f2 = Fit $pg $t2 22 11 126; $pg.DrawString($t2, $f2, $gold, (New-Object Drawing.RectangleF $cx, ($cy + 92), 140, 30), $pf) }
  }
  $pg.Dispose()
  $outDir = Join-Path $here 'docs\deck'; New-Item -ItemType Directory -Force $outDir | Out-Null
  $pv.Save((Join-Path $outDir 'main-preview.png'), [Drawing.Imaging.ImageFormat]::Png); $pv.Dispose()
  [IO.File]::WriteAllLines((Join-Path $previewRun 'layout.tsv'), [string[]]$layout, $u8)
  [IO.File]::WriteAllLines((Join-Path $previewRun 'keys.map'), [string[]]($keyMap.Keys | % { "$_=$($keyMap[$_])" }), $u8)
  "preview written to $previewRun and docs\deck\main-preview.png"; return
}
[IO.File]::WriteAllLines((Join-Path $keys 'keys.map'), [string[]]($keyMap.Keys | % { "$_=$($keyMap[$_])" }), $u8)
# remove key exes from older layouts that no longer have a key
Get-ChildItem -LiteralPath $keys -Filter *.exe -File | ? { -not $keyMap.Contains($_.BaseName) } | % { Remove-Item -LiteralPath $_.FullName -Force }
# new pages are complete: now drop the old ones (a failed build above leaves the old profile intact)
foreach ($d in $oldPages) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
# Stream Deck's Default page is a hidden empty page of its own, never one of the listed pages (every profile it makes is like that).
# We used to name MAIN as Default too: its log then said "Failed to map default page" for MAIN, and that is when it pruned MAIN
# and left blank keys (2026-10-18, 2026-10-23). Current = MAIN is what makes the deck open on MAIN.
$ids.dflt = G
New-Item -ItemType Directory "$profDir\Profiles\$($ids.dflt.ToUpper())\Images" -Force | Out-Null
[IO.File]::WriteAllText("$profDir\Profiles\$($ids.dflt.ToUpper())\manifest.json", '{"Controllers":[{"Actions":null,"Type":"Keypad"}],"Icon":"","Name":""}', $u8)
$tm = [ordered]@{ Device = $dev; Name = 'iRacing GT3'; Pages = [ordered]@{ Current = $ids.main; Default = $ids.dflt; Pages = @($ids.leave, $ids.main, $ids.more) }; Version = '3.0' }
[IO.File]::WriteAllText("$profDir\manifest.json", ($tm | ConvertTo-Json -Depth 10), $u8)
"built: MAIN $($main.Count) keys, MORE $($more.Count) keys, LEAVE $($leave.Count) keys; $($keyMap.Count) key exes"
