# AU-1 copy audit: every word on a screen must mean something (docs\COPY-RULES.md).
#   1. every screen in headless Chrome with real data (top-screen pages, Analysis workbench pages, the iPhone app):
#      the visible text is read and checked against the banned patterns
#   2. every text string in the served pages, the phone app, the add-on and the Rig Doctor / share overlay code
#      is checked against the same patterns (the states that are not on screen right now: errors, driving, empty)
#   3. a picture of every screen, tests\shots\audit-<tag>-<screen>.png, and a contact sheet tests\shots\audit-<tag>.png
#   -Tag before   only report (the state before the audit); default 'after' fails on a hit
# Needs the deployed irdash (real sessions). Never runs while Peter races (guard.ps1).
param([string]$Tag = 'after', [switch]$NoShots, [switch]$SheetOnly, [switch]$SourceOnly, [switch]$SkipPhone, [string]$OnlyScreen = '')   # -SkipPhone: leave the iPhone app out while its own builder is polishing it
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'guard.ps1')
$needRig = -not $SheetOnly -and -not $SourceOnly
if ($needRig) { Assert-RigFree }
$root = Split-Path -Parent $PSScriptRoot
$api = 'http://localhost:8199'
$shots = Join-Path $PSScriptRoot 'shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$last = Join-Path $PSScriptRoot 'last'; New-Item -ItemType Directory -Force $last | Out-Null
$script:ok = 0; $script:fail = 0
function Check($name, $cond, $detail = '') { if ($cond) { $script:ok++; Write-Output "  ok    $name" } else { $script:fail++; Write-Output "  FAIL  $name $detail" } }
function Section($t) { if ($needRig) { Assert-RigFree -Where $t }; Write-Output ''; Write-Output $t }
function Q($s) { [uri]::EscapeDataString($s) }

# ---- the banned patterns (the table in docs\COPY-RULES.md) ----
$emoji = '[\u2600-\u2604\u2607-\u27BF\u2B50\u2B55]|[\uD83C-\uD83E][\uDC00-\uDFFF]'   # keeps the typographic stars / arrows / triangles used as icons (U+2605, U+2190-21FF, U+25B2-25C0)
$banned = [ordered]@{
  'addresses him'      = "(?i)\byou(?:r|rs|rself|'re|'ve|'ll|’re|’ve|’ll)?\b"
  'greeting'           = '(?i)\bgood (?:morning|afternoon|evening|night)\b|\bwelcome\b|\bready when\b|\bwhen you\b|\bhello\b'
  'filler word'        = '(?i)\b(?:just|simply|quietly|let''s|here''s|insights?|journey|stories|story|by itself|by themselves|automatically)\b'
  'exclamation'        = '[A-Za-z0-9\)\]]!(?:\s|$|["''<])'
  'dash aside'         = '\u2014|[A-Za-z0-9\.\)] \u2013 [A-Za-z]|[a-z]{3,} - [A-Za-z]{3,}'   # a lone en dash is the empty-value mark, not an aside
  'emoji'              = $emoji
  'broken character'   = '[\u00C2\u00C3]'   # raw UTF-8 in a .cs file read as ANSI shows as A-circumflex + dot: write non-ASCII as \u escapes in C#
  'how it is computed' = '(?i)outline from|from your own|sampled \d|explains \d|is the mean|mean over|worked out from|last time here|first time here|as of last'
}
function Banned-Hits([string]$t) {
  $h = @()
  foreach ($k in $banned.Keys) { if ([regex]::IsMatch($t, $banned[$k])) { $h += $k } }
  return $h
}

# ---- headless Chrome with the DevTools protocol (same harness as home-test, its own port) ----
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$script:cdp = $null
function Cdp-Open($url, $w = 1920, $h = 1080) {
  $prof = Join-Path $env:TEMP ('audit-test-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $port = 9391
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", "--remote-debugging-port=$port", "--window-size=$w,$h", '--hide-scrollbars', 'about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null
  for ($i = 0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $arr = Invoke-RestMethod "http://127.0.0.1:$port/json"; foreach ($x in $arr) { if ($x.type -eq 'page') { $page = $x; break } } } catch { } }
  if (-not $page) { throw 'headless Chrome did not start' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()
  $script:cdp = @{ ws = $ws; proc = $p; prof = $prof; id = 0; errors = New-Object System.Collections.Generic.List[string] }
  $null = Cdp 'Page.enable' @{}
  $null = Cdp 'Runtime.enable' @{}
  $mob = $w -lt 600
  $null = Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $mob }
  $null = Cdp 'Page.navigate' @{ url = $url }
}
function Cdp($method, $params) {
  $c = $script:cdp; $c.id++
  $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $c.id; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
  $null = $c.ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
  while ($true) {
    $buf = New-Object byte[] 262144; $sb = New-Object Text.StringBuilder
    do { $seg = New-Object ArraySegment[byte] -ArgumentList @(, $buf); $r = $c.ws.ReceiveAsync($seg, [Threading.CancellationToken]::None); $null = $r.Wait(); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Result.Count)) } while (-not $r.Result.EndOfMessage)
    $o = $sb.ToString() | ConvertFrom-Json
    if ($o.method -eq 'Runtime.exceptionThrown') { $c.errors.Add([string]$o.params.exceptionDetails.exception.description) }
    if ($o.id -eq $c.id) { return $o }
  }
}
function Cdp-Eval($expr) { $r = Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true }; if ($r.result.exceptionDetails) { return 'js error: ' + $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Cdp-Shot($path) { $s = Cdp 'Page.captureScreenshot' @{ format = 'png' }; [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($s.result.data)) }
function Cdp-Close() {
  $c = $script:cdp; if (-not $c) { return }; $script:cdp = $null
  try { $c.ws.Dispose() } catch { }
  try { $c.proc | Stop-Process -Force } catch { }
  Start-Sleep -Milliseconds 400
  try { Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$($c.prof)*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } } } catch { }   # CIM may be blocked; the owned Chrome process above is already stopped
  Start-Sleep -Milliseconds 300; try { Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
# every visible text node, SVG text and title / placeholder / aria-label of the page, one string each
$textJs = @'
(() => { const out = []; const vis = e => { for (let p = e; p && p !== document.documentElement; p = p.parentElement) { const cs = getComputedStyle(p); if (cs.display === 'none' || cs.visibility === 'hidden' || +cs.opacity === 0) return false; } const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); let n;
  while ((n = w.nextNode())) { const t = n.nodeValue.replace(/\s+/g, ' ').trim(); const p = n.parentElement; if (!t || !p || /^(SCRIPT|STYLE|NOSCRIPT)$/.test(p.tagName)) continue; if (vis(p)) out.push(t); }
  document.querySelectorAll('[title],[placeholder],[aria-label]').forEach(e => { if (!vis(e)) return; ['title', 'placeholder', 'aria-label'].forEach(a => { const v = e.getAttribute(a); if (v && v.trim()) out.push('[' + a + '] ' + v.trim()); }); });
  return out; })()
'@
function Get-Texts { $j = Cdp-Eval ('JSON.stringify(' + $textJs + ')'); $a = ConvertFrom-Json $j; if ($a -is [array] -and $a.Count -eq 1 -and $a[0] -is [array]) { $a = $a[0] }; return @($a) }
# wait until the page text stops changing (the pages fetch their data and draw in steps)
function Settle($maxSec = 25) {
  $prev = -1; $same = 0; $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt $maxSec) {
    Start-Sleep -Milliseconds 800
    $len = Cdp-Eval 'document.body ? document.body.innerText.length : 0'
    if ($len -is [string] -or $len -lt 30) { continue }
    if ($len -eq $prev) { $same++ } else { $same = 0 }
    if ($same -ge 3) { break }
    $prev = $len
  }
}

$pb = 'chevyvettez06rgt3_roadatlanta full 2026-10-10 00-13-18.ibt'
$wb = "$api/v2/workbench.html?id=$(Q $pb)&lap=7"
$screens = @(
  @{ n = 'home';          u = "$api/v2/";                                      w = 1920; h = 1080 },
  @{ n = 'live';          u = "$api/v2/index.html?demo=1";                     w = 1920; h = 1080 },
  @{ n = 'sessions';      u = "$api/v2/sessions.html";                         w = 1920; h = 1080 },
  @{ n = 'session-laps';  u = "$api/v2/sessions.html#a=$(Q $pb)";              w = 1920; h = 1080 },
  @{ n = 'vault';         u = "$api/v2/vault.html";                            w = 1920; h = 1080 },
  @{ n = 'performance';   u = "$api/v2/perf.html";                             w = 1920; h = 1080 },
  @{ n = 'review';        u = "$api/v2/sessionreview.html?id=$(Q $pb)&lap=7";  w = 1920; h = 1080 },
  @{ n = 'wb-driver';     u = "$wb&page=driver";                               w = 1920; h = 1080 },
  @{ n = 'wb-grip';       u = "$wb&page=grip";                                 w = 1920; h = 1080 },
  @{ n = 'wb-braking';    u = "$wb&page=braking";                              w = 1920; h = 1080 },
  @{ n = 'wb-tyres';      u = "$wb&page=tyres";                                w = 1920; h = 1080 },
  @{ n = 'wb-suspension'; u = "$wb&page=suspension";                           w = 1920; h = 1080 },
  @{ n = 'wb-splits';     u = "$wb&page=splits";                               w = 1920; h = 1080 },
  @{ n = 'wb-pro';        u = "$wb&page=pro";                                  w = 1920; h = 1080 },
  @{ n = 'wb-career';     u = "$wb&page=career";                               w = 1920; h = 1080 },
  @{ n = 'wb-race';       u = "$wb&page=race";                                 w = 1920; h = 1080 },
  @{ n = 'wb-video';      u = "$wb&page=video";                                w = 1920; h = 1080 }
)
$phonePages = @('home', 'drive', 'sound', 'setup', 'laps', 'clips')
$lines = New-Object System.Collections.Generic.List[string]
$hitsByScreen = [ordered]@{}
$taken = New-Object System.Collections.Generic.List[string]

try {
  if (-not $SheetOnly) {
  if (-not $SourceOnly) {
  Section '0. every served script still compiles (the audit edits many strings)'
  $jsFiles = @(Get-ChildItem (Join-Path $root 'dash\www\v2') -Filter *.js -File | ForEach-Object { '/v2/' + $_.Name }) + @(Get-ChildItem (Join-Path $root 'dash\www\phone') -Filter *.js -File | ForEach-Object { '/phone/' + $_.Name })
  Cdp-Open "$api/v2/vault.html"
  Start-Sleep -Seconds 2
  $listJs = ($jsFiles | ForEach-Object { "'$_'" }) -join ','
  $bad = Cdp-Eval "(async () => { const bad = []; for (const u of [$listJs]) { try { const s = await (await fetch(u)).text(); new Function(s); } catch (e) { bad.push(u + ': ' + e.message); } } return bad.join(' | '); })()"
  Check "$($jsFiles.Count) scripts compile" ([string]$bad -eq '') ([string]$bad)
  Cdp-Close
  Section '1. every screen with real data: the visible text'
  foreach ($s in $screens) {
    if ($OnlyScreen -and $s.n -ne $OnlyScreen) { continue }
    Assert-RigFree -Where $s.n
    Cdp-Open $s.u $s.w $s.h
    Settle
    $err = [string](Cdp-Eval 'window.__err || ""')
    $texts = Get-Texts
    $bad = @()
    foreach ($t in $texts) { $lines.Add("$($s.n) | $t"); $h = Banned-Hits ([string]$t); if ($h.Count) { $bad += "'$t' <- $($h -join ', ')" } }
    $hitsByScreen[$s.n] = $bad.Count
    # CAREER draws chart labels into canvas pixels, so visible DOM text can be two captions even with full data.
    $minTexts = if ($s.n -in @('wb-video', 'wb-career')) { 0 } else { 3 }
    Check "$($s.n): $($texts.Count) texts, none banned" (($bad.Count -eq 0) -and $texts.Count -gt $minTexts) (($bad | Select-Object -First 12) -join ' | ')
    if (-not $NoShots) { $f = Join-Path $shots "audit-$Tag-$($s.n).png"; Cdp-Shot $f; $taken.Add($f) }
    Cdp-Close
  }
  if ($SkipPhone) { $phonePages = @() }
  if ($phonePages.Count) {
  Assert-RigFree -Where 'phone'
  Cdp-Open "$api/phone/" 393 852
  $null = Cdp-Eval 'new Promise(r => { const t0 = Date.now(); const f = () => (typeof PhoneApp !== "undefined" && PhoneApp.st) || Date.now() - t0 > 15000 ? r(1) : setTimeout(f, 300); f(); })'
  }
  foreach ($pg in $phonePages) {
    $null = Cdp-Eval "PhoneApp.show('$pg'); true"
    Settle 12
    $texts = Get-Texts
    $bad = @()
    foreach ($t in $texts) { $lines.Add("phone-$pg | $t"); $h = Banned-Hits ([string]$t); if ($h.Count) { $bad += "'$t' <- $($h -join ', ')" } }
    Check "phone $pg`: $($texts.Count) texts, none banned" (($bad.Count -eq 0) -and $texts.Count -gt 2) (($bad | Select-Object -First 12) -join ' | ')
    if (-not $NoShots) { $f = Join-Path $shots "audit-$Tag-phone-$pg.png"; Cdp-Shot $f; $taken.Add($f) }
  }
  Cdp-Close
  [IO.File]::WriteAllLines((Join-Path $last 'copy-audit-text.txt'), $lines, [Text.Encoding]::UTF8)
  }   # end of the screens (a -SourceOnly run reads files only and can run any time)

  Section '2. every text string in the served pages, the phone app, the add-on and the C# texts'
  $files = @()
  $files += Get-ChildItem (Join-Path $root 'dash\www\v2') -File | Where-Object { $_.Extension -in '.js', '.html' }
  if (-not $SkipPhone) { $files += Get-ChildItem (Join-Path $root 'dash\www\phone') -File | Where-Object { $_.Extension -in '.js', '.html' } }
  $files += Get-Item (Join-Path $root 'deck-intro\plugin.html')
  foreach ($cs in 'doctor.cs', 'share.cs', 'replayjump.cs', 'deltabar.cs', 'gallery.cs', 'home.cs', 'phone.cs') { $files += Get-Item (Join-Path $root "dash\src\$cs") }
  # exceptions, each with a reason: iRacing's own SDK variable descriptions; fake driver names for the demo
  $skipFile = @{ 'workbench-channels.js' = 'iRacing SDK descriptions'; 'demo.js' = 'demo data' }
  $strRx = New-Object Text.RegularExpressions.Regex("'((?:[^'\\\r\n]|\\.)*)'|""((?:[^""\\\r\n]|\\.)*)""|``((?:[^``\\]|\\.)*)``", 'Singleline')
  $srcBad = New-Object System.Collections.Generic.List[string]; $nStr = 0
  foreach ($f in $files) {
    if ($skipFile.ContainsKey($f.Name)) { continue }
    $txt = [IO.File]::ReadAllText($f.FullName).Replace("`r`n", "`n")
    $txt = [regex]::Replace($txt, '(?s)/\*.*?\*/', { param($m) $m.Value -replace '[^\n]', ' ' })
    $txt = [regex]::Replace($txt, '(?s)<!--.*?-->', { param($m) $m.Value -replace '[^\n]', ' ' })
    $txt = [regex]::Replace($txt, '(?m)^\s*//.*$', '')
    $txt = [regex]::Replace($txt, '(?<=\s)//\s.*$', '', 'Multiline')
    if ($f.Extension -eq '.html' -or $f.Extension -eq '.js') { $txt = [regex]::Replace($txt, '(?m)^\s*<!--.*$', '') }
    $isCs = $f.Extension -eq '.cs'
    foreach ($m in $strRx.Matches($txt)) {
      $g = if ($m.Groups[1].Success) { $m.Groups[1] } elseif ($m.Groups[2].Success) { $m.Groups[2] } else { $m.Groups[3] }
      $s = $g.Value
      if ($s.Length -lt 4 -or $s -notmatch '[A-Za-z]{3}') { continue }
      if ($isCs) { $ls = $txt.LastIndexOf("`n", $m.Index) + 1; $le = $txt.IndexOf("`n", $m.Index); if ($le -lt 0) { $le = $txt.Length }; if ($txt.Substring($ls, $le - $ls) -match 'Log\.|Console\.|Debug\.') { continue } }   # log lines are for the log file, not a screen
      $s = [regex]::Replace($s, '<[^>]*>', ' ')
      $nStr++
      $h = Banned-Hits $s
      if ($h.Count) { $ln = ($txt.Substring(0, $m.Index) -split "`n").Count; $srcBad.Add("$($f.Name):$ln '$($s.Trim())' <- $($h -join ', ')") }
    }
    # the text between tags in html pages
    if ($f.Extension -eq '.html') {
      $body = [regex]::Replace($txt, '(?s)<script.*?</script>|<style.*?</style>', ' ')
      foreach ($m in [regex]::Matches($body, '>([^<>]+)<')) { $s = ($m.Groups[1].Value -replace '\s+', ' ').Trim(); if ($s.Length -ge 3) { $nStr++; $h = Banned-Hits $s; if ($h.Count) { $srcBad.Add("$($f.Name) '$s' <- $($h -join ', ')") } } }
    }
  }
  Check "$nStr text strings in $($files.Count) files, none banned" ($srcBad.Count -eq 0) (($srcBad | Select-Object -First 15) -join ' | ')
  [IO.File]::WriteAllLines((Join-Path $last 'copy-audit-source-hits.txt'), $srcBad, [Text.Encoding]::UTF8)
  Write-Output "  ($($srcBad.Count) source hits listed in tests\last\copy-audit-source-hits.txt)"

  Section '2b. no broken characters in what the server sends (every reply decoded as UTF-8)'
  $api2 = @('/home', '/career', '/brief', '/perf', '/perf/checklist', '/sessions', '/vault/list', '/official', '/health', '/overlays', '/analysis/session?id=' + (Q $pb), '/analysis/career?id=' + (Q $pb), '/analysis/gain?id=' + (Q $pb), '/vault/review', '/bench?car=x&track=y', '/doctor', '/rig/doctor')
  $moji = @(); $nApi = 0
  foreach ($u in $api2) { try { $r = Invoke-WebRequest -UseBasicParsing ($api + $u) -TimeoutSec 60; $txt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()); $nApi++; if ($txt -match '[\u00C2\u00C3]') { $moji += $u } } catch { } }
  Check "$nApi server replies read as UTF-8, no broken characters" ($moji.Count -eq 0 -and $nApi -ge 8) ($moji -join ', ')

  Section '3. the cut phrases are gone'
  $gone = @('Outline from your own telemetry', 'Get in when you are ready', 'Last time here', 'Good morning', 'Good evening', 'Good afternoon', 'VS YOUR NEXT BEST', 'Two line crossings', 'the curve explains', 'Surface = mean')
  $all = ''; if (Test-Path (Join-Path $last 'copy-audit-text.txt')) { $all = [IO.File]::ReadAllText((Join-Path $last 'copy-audit-text.txt')) }
  foreach ($g in $gone) {
    $inSrc = $false
    foreach ($f in $files) { if ($skipFile.ContainsKey($f.Name)) { continue }; if ([IO.File]::ReadAllText($f.FullName) -match [regex]::Escape($g)) { $inSrc = $true; break } }
    Check "'$g' is not on any screen or in any served file" (-not $inSrc -and $all.IndexOf($g, [StringComparison]::OrdinalIgnoreCase) -lt 0)
  }

  }   # end of the sections that need the rig free
  # the sheet is built from the pictures of this tag, in screen order (a -SheetOnly run builds the 'before' sheet from earlier pictures)
  $taken.Clear()
  foreach ($n in (@($screens | ForEach-Object { $_.n }) + @($phonePages | ForEach-Object { "phone-$_" }))) { $f = Join-Path $shots "audit-$Tag-$n.png"; if (Test-Path $f) { $taken.Add($f) } }
  if (-not $NoShots -and $taken.Count) {
    Section '4. contact sheet'
    Add-Type -AssemblyName System.Drawing
    $cols = 3; $cw = 800; $ch = 450; $lab = 26
    $rows = [math]::Ceiling($taken.Count / $cols)
    $bmp = New-Object Drawing.Bitmap ($cols * $cw), ($rows * ($ch + $lab))
    $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::FromArgb(8, 8, 10)); $g.InterpolationMode = 'HighQualityBicubic'
    $font = New-Object Drawing.Font 'Segoe UI', 11; $br = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(212, 175, 55))
    $i = 0
    foreach ($f in $taken) {
      $img = [Drawing.Image]::FromFile($f)
      $sc = [math]::Min(($cw - 8) / $img.Width, ($ch - 8) / $img.Height)
      $w2 = [int]($img.Width * $sc); $h2 = [int]($img.Height * $sc)
      $x = ($i % $cols) * $cw + [int](($cw - $w2) / 2); $y = [math]::Floor($i / $cols) * ($ch + $lab) + $lab
      $g.DrawImage($img, $x, $y, $w2, $h2); $g.DrawString(([IO.Path]::GetFileNameWithoutExtension($f) -replace '^audit-\w+-', ''), $font, $br, ($i % $cols) * $cw + 6, [math]::Floor($i / $cols) * ($ch + $lab) + 3)
      $img.Dispose(); $i++
    }
    $g.Dispose(); $sheet = Join-Path $shots "audit-$Tag.png"; $bmp.Save($sheet, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    Check "contact sheet of $($taken.Count) screens written ($sheet)" (Test-Path $sheet)
  }
} finally {
  Cdp-Close
}
Write-Output ''
$total = ($hitsByScreen.Values | Measure-Object -Sum).Sum
Write-Output "copy-audit-test ($Tag): $script:ok passed, $script:fail failed. screen hits: $total, source hits: $($srcBad.Count)"
if ($Tag -eq 'before') { exit 0 }
if ($script:fail -gt 0) { exit 1 }
