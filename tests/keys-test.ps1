# keys-test (C-32): every Stream Deck key answers, no dead keys.
# Reads the MAIN and MORE pages by running build-deck.ps1 -Preview (it only writes C:\Temp\preview), keys\keys.map,
# deck-intro\plugin.html (FRIENDS, OVERLAYS, MY DRIVE, REPLAY, ANALYSIS, SOUND) and the sources behind them (src\irdeck.cs, dash\src\*.cs).
# No clicks, no sim, nothing is written to Stream Deck. The only live part (section 8) runs real irdeck commands that
# are known to do nothing without a session, plus the new --dry commands, and only when the rig is free.
#   powershell -ExecutionPolicy Bypass -File tests\keys-test.ps1               (full: needs the rig free, writes tests\last\keys.txt)
#   powershell -ExecutionPolicy Bypass -File tests\keys-test.ps1 -StaticOnly   (files only; fine while he races)
#   -Cli <path>   run the dry commands with another irdeck-cli.exe (for example %TEMP%\ird\irdeck-cli.exe, a build not deployed yet)
# Checked per key: it has a command / handler that really exists, no two keys on a page do the same, every label is at
# most 2 short lines, a key marked x2 is a confirm key (and the other way round), a key whose feature is not built is
# OFF the deck. The table of every key (page, position, command, status) is the end of the output = tests\last\keys.txt.
param([switch]$StaticOnly, [string]$Cli = '')
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')
if (-not $StaticOnly) { Assert-RigFree }
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$pass = 0; $fail = 0; $warns = 0
$buf = New-Object Collections.Generic.List[string]
function Say($s) { $script:buf.Add([string]$s); Write-Host $s }
function Check($what, $ok, $why) { if ($ok) { $script:pass++; Say "  ok    $what" } else { $script:fail++; Say ("  FAIL  $what" + $(if ($why) { " -> $why" } else { '' })) } }
function Warn($what) { $script:warns++; Say "  warn  $what" }
function Note($what) { Say "  info  $what" }
# tests\last\keys.txt is written here when run by hand; under run-all its output IS that file (the parent redirects into it)
function Save-Out {
  if ($env:PADDOCK_RUN_ALL) { return }
  try { New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot 'last') | Out-Null; [IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'last\keys.txt'), [string[]]$script:buf, (New-Object Text.UTF8Encoding $false)) } catch { }
}
function Section($title) {
  if (-not $StaticOnly) { try { Assert-RigFree -Where $title } catch { Say "$_"; Save-Out; exit 3 } }
  Say $title
}
function ReadText($rel) { [IO.File]::ReadAllText((Join-Path $root $rel), [Text.Encoding]::UTF8) }
function Ascii($s) { ([string]$s).Replace([string][char]0x2212, '-').Replace([string][char]0x00B7, '.').Replace([string][char]0x2605, '*') -replace '[^\x20-\x7E]', '?' }

# ---------------- small parsers ----------------
# the text of a C# method: from its signature to the next member (8-space indent, which is how every member in src\ starts)
function Get-Body($src, $sig) {
  $i = $src.IndexOf($sig); if ($i -lt 0) { return '' }
  $m = [regex]::Match($src.Substring($i + $sig.Length), "\r?\n        (static|// ----)")
  if ($m.Success) { return $src.Substring($i, $sig.Length + $m.Index) }
  return $src.Substring($i)
}
function Case-Labels($body) { @([regex]::Matches($body, 'case "([^"]+)":') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() }) }
# split on top-level commas (JavaScript argument lists); quotes and brackets are respected
function Split-Top([string]$s) {
  $parts = New-Object Collections.Generic.List[string]; $depth = 0; $q = ''; $cur = New-Object Text.StringBuilder
  for ($i = 0; $i -lt $s.Length; $i++) {
    $ch = $s[$i]
    if ($q) {
      [void]$cur.Append($ch)
      if ($ch -eq '\') { $i++; if ($i -lt $s.Length) { [void]$cur.Append($s[$i]) } } elseif ([string]$ch -eq $q) { $q = '' }
      continue
    }
    if ($ch -eq "'" -or $ch -eq '"') { $q = [string]$ch; [void]$cur.Append($ch); continue }
    if ('([{'.Contains([string]$ch)) { $depth++ } elseif (')]}'.Contains([string]$ch)) { $depth-- }
    if ($ch -eq ',' -and $depth -eq 0) { $parts.Add($cur.ToString().Trim()); [void]$cur.Clear(); continue }
    [void]$cur.Append($ch)
  }
  $parts.Add($cur.ToString().Trim())
  return ,$parts.ToArray()
}
# every call that starts with $pattern (a regex ending in the opening paren): its index and its argument list
function Get-Calls([string]$text, [string]$pattern) {
  $calls = New-Object Collections.Generic.List[object]
  foreach ($m in [regex]::Matches($text, $pattern)) {
    $start = $m.Index + $m.Length; $depth = 1; $q = ''; $i = $start
    while ($i -lt $text.Length -and $depth -gt 0) {
      $ch = $text[$i]
      if ($q) { if ($ch -eq '\') { $i++ } elseif ([string]$ch -eq $q) { $q = '' } }
      elseif ($ch -eq "'" -or $ch -eq '"') { $q = [string]$ch }
      elseif ($ch -eq '(') { $depth++ } elseif ($ch -eq ')') { $depth-- }
      $i++
    }
    $inner = $text.Substring($start, [Math]::Max(0, $i - 1 - $start))
    $calls.Add([pscustomobject]@{ idx = $m.Index; args = (Split-Top $inner) })
  }
  return $calls.ToArray()   # callers wrap it in @(...)
}
function Lits($s) { @([regex]::Matches([string]$s, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value }) }

Say 'Stream Deck keys test (C-32)'
$irSrc  = ReadText 'src\irdeck.cs'
$irdash = ReadText 'dash\src\irdash.cs'
$plug   = ReadText 'deck-intro\plugin.html'
$inst   = ReadText 'deck-intro\install.ps1'
$table  = New-Object Collections.Generic.List[object]   # page, pos, label, command, status

# ================= 1. the layout =================
Section '1. the layout: build-deck.ps1 -Preview, read back (writes only C:\Temp\preview)'
$prev = ''
$t0 = Get-Date
$o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-deck.ps1') -Preview 2>&1 | ForEach-Object { "$_" }
$rc = $LASTEXITCODE
$pm = [regex]::Match(($o -join ' '), 'preview written to (.+?) and docs\\deck\\main-preview\.png')
if ($pm.Success) { $prev = $pm.Groups[1].Value.Trim() }
Check 'build-deck.ps1 -Preview ran and wrote the layout' ($rc -eq 0 -and ($o -join ' ') -match 'preview written' -and (Test-Path "$prev\layout.tsv") -and (Get-Item "$prev\layout.tsv").LastWriteTime -ge $t0.AddSeconds(-2)) ($o -join ' ')
$deck = @()
if (Test-Path "$prev\layout.tsv") {
  foreach ($l in [IO.File]::ReadAllLines("$prev\layout.tsv", [Text.Encoding]::UTF8)) {
    $p = $l.Split("`t"); if ($p.Count -lt 7) { continue }
    $deck += [pscustomobject]@{ page = $p[0]; col = [int]$p[1]; row = [int]$p[2]; t1 = $p[3]; t2 = $p[4]; kind = $p[5]; what = $p[6]; status = ''; label = (Ascii (($p[3] + ' ' + $p[4]).Trim())) }
  }
}
$main = @($deck | Where-Object { $_.page -eq 'MAIN' }); $more = @($deck | Where-Object { $_.page -eq 'MORE' })
Check "MAIN has keys ($($main.Count)) and MORE has keys ($($more.Count))" ($main.Count -ge 20 -and $more.Count -ge 10)
Check 'every key sits inside the 8 x 4 grid, one key per cell' (@($deck | Where-Object { $_.col -lt 0 -or $_.col -gt 7 -or $_.row -lt 0 -or $_.row -gt 3 }).Count -eq 0 -and @($deck | Group-Object { $_.page + ':' + $_.col + ',' + $_.row } | Where-Object { $_.Count -gt 1 }).Count -eq 0)

# MAIN is the DK-2 grid (docs\deck\council-fable.md section 3, adopted by docs\deck\DECK-v4.md): same cell, same word
$approved = [ordered]@{
  '0,0' = 'HOME*'; '1,0' = 'AI RACE*'; '2,0' = 'TEST DRIVE*'; '3,0' = 'MY DRIVE*'; '4,0' = 'FRIENDS*'; '5,0' = 'MORE*'; '6,0' = 'OFFICIAL*'; '7,0' = 'GET IN*'
  '0,1' = 'GET OUT*'; '1,1' = 'RESET CAR*'; '2,1' = 'KEEP LAP*'; '3,1' = 'SAVE*'; '4,1' = 'TV*'; '5,1' = 'SKIP SESSION*'; '6,1' = 'RESTART*'; '7,1' = 'QUIT*'
  '0,2' = 'FUEL*'; '1,2' = 'TIRES*'; '2,2' = 'CLEAR*'; '3,2' = 'OVERLAYS*'; '4,2' = 'REVIEW*'; '5,2' = 'VAULT*'; '6,2' = 'CAR TRACK*'; '7,2' = 'live:laps-to-empty'
  '0,3' = 'SORRY*'; '1,3' = 'THANKS*'; '2,3' = 'VOL -*'; '3,3' = 'VOL +*'; '4,3' = 'RELATIVE*'; '5,3' = 'live:position'; '6,3' = 'live:incidents' }
$bad = @()
foreach ($pos in $approved.Keys) {
  $c, $r = $pos.Split(',') | ForEach-Object { [int]$_ }
  $k = $main | Where-Object { $_.col -eq $c -and $_.row -eq $r } | Select-Object -First 1
  if (-not $k) { $bad += "$pos missing"; continue }
  $want = $approved[$pos]
  $got = if ($k.kind -eq 'live') { 'live:' + ($k.what -replace '^session-info:', '') } else { $k.label }
  if (-not ($got -like $want)) { $bad += "$pos is '$got', approved '$want'" }
}
foreach ($k in $main) { if (-not $approved.Contains("$($k.col),$($k.row)")) { $bad += "$($k.col),$($k.row) '$($k.label)' is not in the approved grid" } }
Check 'MAIN is the DK-2 / DK-2b grid, cell by cell (7,3 stays empty)' ($bad.Count -eq 0) ($bad -join '; ')
$moreWant = [ordered]@{ '0,0' = 'BACK*'; '2,0' = 'GOOD RACE*'; '3,0' = 'MUTE*'; '4,0' = 'SHOWCASE*'; '5,0' = 'SOUND*'; '6,0' = 'SLEEP*'; '7,0' = 'LOCK*'
  '0,1' = 'MARK SPOT*'; '1,1' = 'BACK TO SPOT*'; '2,1' = 'REPLAY*'; '3,1' = 'REPAIR*'; '4,1' = 'WIPE*'; '5,1' = 'SEAT LOWER*'; '6,1' = 'SEAT HIGHER*'
  '0,2' = 'TIMING*'; '1,2' = 'STANDINGS*'; '2,2' = 'FUEL BOX*'; '3,2' = 'TIRE BOX*'; '4,2' = 'IN-CAR*'; '5,2' = 'WEATHER*'; '6,2' = 'ANALYSIS*' }
$bad = @()
foreach ($pos in $moreWant.Keys) {
  $c, $r = $pos.Split(',') | ForEach-Object { [int]$_ }
  $k = $more | Where-Object { $_.col -eq $c -and $_.row -eq $r } | Select-Object -First 1
  if (-not $k) { $bad += "$pos missing"; continue }
  if (-not ($k.label -like $moreWant[$pos])) { $bad += "$pos is '$($k.label)', wanted '$($moreWant[$pos])'" }
}
foreach ($k in $more) { if (-not $moreWant.Contains("$($k.col),$($k.row)")) { $bad += "$($k.col),$($k.row) '$($k.label)' is not on the MORE plan" } }
Check 'MORE is the planned page, cell by cell (BACK in the corner, the bottom row empty)' ($bad.Count -eq 0) ($bad -join '; ')
Check 'MAIN has a MORE key (next page) and MORE has a BACK key (previous page)' (@($main | Where-Object { $_.kind -eq 'page' -and $_.what -eq 'next' }).Count -eq 1 -and @($more | Where-Object { $_.kind -eq 'page' -and $_.what -eq 'previous' }).Count -eq 1)
Check 'every key on the device is drawn on MAIN.png / MORE.png' ((Test-Path "$prev\MAIN.png") -and (Test-Path "$prev\MORE.png") -and (Get-Item "$prev\MAIN.png").LastWriteTime -ge $t0.AddSeconds(-2))

# ================= 2. what each kind of key points at =================
Section '2. every key has a command or handler, and it exists'
$verbs = Case-Labels ($irSrc.Substring($irSrc.IndexOf('static int Run(string[] a)'), 6000))
$pitToggles = Case-Labels (Get-Body $irSrc 'static int CmdPitToggle(string[] a)')
$mediaCmds  = Case-Labels (Get-Body $irSrc 'static int CmdMedia(string[] a)')
$chatCmds   = Case-Labels (Get-Body $irSrc 'static int CmdChat(string[] a)')
$powerCmds  = Case-Labels (Get-Body $irSrc 'static int CmdPower(string[] a)')
$pitNames   = @([regex]::Matches((Get-Body $irSrc 'static readonly Dictionary<string, int> PitCmd'), '\{"(\w+)",\d+\}') | ForEach-Object { $_.Groups[1].Value })
$keyNames   = (Case-Labels (Get-Body $irSrc 'static bool KeyCode(string n')) | ForEach-Object { $_ }
Check 'src\irdeck.cs: the command switch, pit toggles, media, chat, power and key names were all read' ($verbs.Count -gt 25 -and $pitToggles.Count -ge 3 -and $mediaCmds.Count -ge 5 -and $chatCmds.Count -ge 4 -and $powerCmds.Count -ge 3 -and $pitNames.Count -ge 10 -and $keyNames.Count -ge 20) "verbs $($verbs.Count) pit $($pitToggles.Count) media $($mediaCmds.Count) chat $($chatCmds.Count) power $($powerCmds.Count) pitnames $($pitNames.Count) keys $($keyNames.Count)"

# what irdash accepts from the deck (/api/do): the command sets of each module, Guest.Do's switch, Tv view and Nav
$handled = @{}
foreach ($f in 'replay', 'overlays', 'mydrive', 'gallery', 'perf', 'vault', 'official', 'sound', 'deckfeed') {
  $m = [regex]::Match((ReadText "dash\src\$f.cs"), '(?s)HashSet<string>\s+Commands\s*=\s*new HashSet<string>\s*\{(.*?)\};')
  foreach ($x in [regex]::Matches($m.Groups[1].Value, '"([A-Za-z0-9_-]+)"')) { $handled[$x.Groups[1].Value] = $f }
}
# the workbench's deck commands are /api/do?c=wb-<name>: its Allowed list (dash\src\workbench.cs)
$wbm = [regex]::Match((ReadText 'dash\src\workbench.cs'), '(?s)string\[\] Allowed\s*=\s*\{(.*?)\};')
foreach ($x in [regex]::Matches($wbm.Groups[1].Value, '"([a-z\-]+)"')) { $handled['wb-' + $x.Groups[1].Value] = 'workbench' }
foreach ($f in 'irdash', 'data') {
  foreach ($l in ((ReadText "dash\src\$f.cs") -split "`n")) { if ($l -match 'public static bool Handles\(string c\) \{ return c ==') { foreach ($x in [regex]::Matches($l, 'c == "(\w+)"')) { $handled[$x.Groups[1].Value] = $f } } }
}
$gi = $irdash.IndexOf('A press on the Stream Deck friends screen'); $gj = $irdash.IndexOf('default: return false;', $gi)
$guestCmds = @(); if ($gi -gt 0 -and $gj -gt $gi) { $guestCmds = Case-Labels $irdash.Substring($gi, $gj - $gi) }
foreach ($g in $guestCmds) { if (-not $handled.ContainsKey($g)) { $handled[$g] = 'guest' } }
Check "irdash's accepted deck commands were read ($($handled.Count) of them, $($guestCmds.Count) from the friends switch)" ($handled.Count -gt 60 -and $guestCmds.Count -ge 15 -and $handled.ContainsKey('tvview') -and $handled.ContainsKey('vkkeep'))

# Deck aliases irdash rewrites before dispatch in /api/do (2026-10-18: `if (dc == "vault") dc = "vkopen";`).
foreach ($x in [regex]::Matches($irdash, 'if \(dc == "(\w+)"\) dc = "(\w+)";')) { if ($handled.ContainsKey($x.Groups[2].Value)) { $handled[$x.Groups[1].Value] = 'alias of ' + $x.Groups[2].Value } }
# Commands a key may name before irdash wires them (marked PENDING, not dead). None left: REVIEW and VAULT were wired 2026-10-18.
$pending = @{}

function Split-Cmd([string]$s) { @([regex]::Matches($s, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') }) }
# $null = fine, else the reason. The same forms the real commands take (src\irdeck.cs).
function Test-IrCommand([string]$line) {
  $t = @(Split-Cmd $line)
  if ($t.Count -eq 0) { return 'empty command' }
  $v = $t[0].ToLowerInvariant()
  if ($script:verbs -notcontains $v) { return "irdeck has no command '$v'" }
  switch ($v) {
    'confirm'   { if ($t.Count -lt 3) { return 'confirm needs an id and a command' }; return (Test-IrCommand ($t[2..($t.Count - 1)] -join ' ')) }
    'startlast' { if ($t.Count -lt 2 -or @('td', 'ai') -notcontains $t[1].ToLowerInvariant()) { return 'startlast needs td or ai' } }
    'pittoggle' { if ($t.Count -lt 2 -or $script:pitToggles -notcontains $t[1].ToLowerInvariant()) { return "pittoggle '$($t[1])' is not tires|fr|ws" } }
    'pit'       { if ($t.Count -lt 2 -or ($script:pitNames -notcontains $t[1].ToLowerInvariant() -and @('fuel+', 'fuel-', 'fuelset', 't', 'l', 'r') -notcontains $t[1].ToLowerInvariant())) { return "pit '$($t[1])' is not a pit command" } }
    'chat'      { if ($t.Count -lt 2 -or $script:chatCmds -notcontains $t[1].ToLowerInvariant()) { return "chat '$($t[1])' is not a chat command" }; if ($t[1] -eq 'say' -and $t.Count -lt 3) { return 'chat say needs text' } }
    'media'     { if ($t.Count -lt 2 -or $script:mediaCmds -notcontains $t[1].ToLowerInvariant()) { return "media '$($t[1])' is not a media command" } }
    'power'     { if ($t.Count -lt 2 -or $script:powerCmds -notcontains $t[1].ToLowerInvariant()) { return "power '$($t[1])' is not a power command" } }
    'appvol'    { if ($t.Count -lt 3 -or @('game', 'music') -notcontains $t[1].ToLowerInvariant() -or $t[2] -notmatch '^[+-]\d+$') { return 'appvol needs game|music and a step like +10' } }
    'dash'      { if ($t.Count -lt 2) { return 'dash needs a command' }
                  $dc = $t[1].ToLowerInvariant()
                  if (-not $script:handled.ContainsKey($dc)) {
                    if ($script:pending.ContainsKey($dc)) { return 'pending: ' + $script:pending[$dc] }
                    return "irdash does not accept '$dc' from the deck"
                  } }
    'key' {
      $combo = @($t[1..($t.Count - 1)] | Where-Object { $_ -notlike '--*' })
      if ($combo.Count -ne 1) { return 'key needs one combo like ctrl+[' }
      foreach ($part in $combo[0].ToLowerInvariant().Split('+')) {
        $okp = ($part -match '^[a-z0-9]$') -or ($part -match '^f([1-9]|1[0-2])$') -or ($script:keyNames -contains $part)
        if (-not $okp) { return "unknown key '$part'" }
      }
    }
  }
  return $null
}

$plugActions = @([regex]::Matches($inst, 'UUID = "\$uuid\.(\w+)"') | ForEach-Object { $_.Groups[1].Value })
$plugScreens = @(); $sm = [regex]::Match($plug, 'const SCREENS = \{([^}]*)\}'); if ($sm.Success) { $plugScreens = @([regex]::Matches($sm.Groups[1].Value, '(\w+):') | ForEach-Object { $_.Groups[1].Value }) }
$uuidBase = [regex]::Match($inst, "\`$uuid\s*=\s*'([^']+)'").Groups[1].Value
Check "the add-on's id matches in install.ps1 and plugin.html, and it has the screens $($plugScreens -join ', ')" ($uuidBase -ne '' -and $plug.Contains("const UUID = '$uuidBase'") -and $plugScreens.Count -ge 4) "uuid '$uuidBase', screens '$($plugScreens -join ',')'"
$sessionModes = @()
$sessHtml = Join-Path $env:APPDATA 'Elgato\StreamDeck\Plugins\com.iracedeck.sd.core.sdPlugin\ui\session-info.html'
if (Test-Path $sessHtml) { $sessionModes = @([regex]::Matches([IO.File]::ReadAllText($sessHtml), 'value="([a-z\-]+)"') | ForEach-Object { $_.Groups[1].Value }) } else { Note 'the iRaceDeck plugin is not installed here: the live key modes are not checked against it' }

$bad = @()
foreach ($k in $deck) {
  $why = $null
  switch ($k.kind) {
    'key' {
      $line = ($k.what -split '=', 2)[1]
      $why = Test-IrCommand $line
      if (-not $why -and $line -match '(^|\s)(startlast|appvol|dash)\s') { }   # their --dry forms are run in section 8
    }
    'plugin' {
      $name = ($k.what -replace "^$([regex]::Escape($uuidBase))\.", '')
      if ($k.what -notlike "$uuidBase.*") { $why = "plugin id '$($k.what)' is not this add-on's" }
      elseif ($plugActions -notcontains $name) { $why = "install.ps1 has no action '$name'" }
      elseif ($plugScreens -notcontains $name) { $why = "plugin.html has no screen '$name'" }
    }
    'page' { if (@('next', 'previous') -notcontains $k.what) { $why = "page '$($k.what)'" } }
    'live' {
      $mode = $k.what -replace '^session-info:', ''
      if ($sessionModes.Count -gt 0 -and $sessionModes -notcontains $mode) { $why = "the iRaceDeck plugin has no Session Info mode '$mode'" }
    }
    'later' { }
    default { $why = "unknown kind '$($k.kind)'" }
  }
  if ($k.kind -eq 'later') { $k.status = 'OFF THE DECK: ' + $k.what }
  elseif ($why -like 'pending: *') { $k.status = 'PENDING: ' + $why.Substring(9) }
  elseif ($why) { $k.status = 'FAIL: ' + $why; $bad += "$($k.page) $($k.col),$($k.row) $($k.label): $why" }
  else { $k.status = 'ok' }
}
Check 'every key on MAIN and MORE resolves to a real irdeck command, add-on screen, page switch or live mode' ($bad.Count -eq 0) ($bad -join '; ')
$later = @($deck | Where-Object { $_.kind -eq 'later' })
Check "keys whose feature is not built are marked Later, so they stay OFF the device ($($later.Count): $((($later | ForEach-Object { $_.label }) -join ', ')))" (@($later | Where-Object { $_.label -like 'ANALYSIS*' -or $_.label -like 'TV*' }).Count -eq $later.Count -and $later.Count -le 2)
$bp = (ReadText 'build-deck.ps1')
Check 'build-deck.ps1 leaves a not-built key out of the profile when it is not a preview' ($bp -match 'if \(-not \$Preview\) \{ continue \}')

# the lead's requirements, one by one
$deckKeys = @($deck | Where-Object { $_.kind -eq 'key' })
function Cmd-Of($label) { $k = $deckKeys | Where-Object { $_.label -like $label } | Select-Object -First 1; if ($k) { return ($k.what -split '=', 2)[1] } return '' }
Check 'RESET CAR runs tow, which waits for the car to stop (C-26)' ((Cmd-Of 'RESET CAR*') -eq 'tow' -and $irSrc -match 'TowWaitLive\(ref inCar, ref speed\)' -and $irSrc -match 'TowLimitMs')
$vd = (Cmd-Of 'VOL -*'), (Cmd-Of 'VOL +*')
Check 'VOL - / VOL + are appvol game -10 / +10, and game covers the sim, its menu and CrewChief' ($vd[0] -eq 'appvol game -10' -and $vd[1] -eq 'appvol game +10' -and (Get-Body $irSrc 'static int CmdAppVol(string[] a)') -match '"iRacingSim64DX11", "iRacingUI", "CrewChiefV4"')
$sl = Get-Body $irSrc 'static int CmdStartLast(string[] a)'
Check 'TEST DRIVE (startlast td) no longer quits a running session: it does nothing and says so' ((Cmd-Of 'TEST DRIVE*') -eq 'startlast td' -and $sl -notmatch 'Armed\(' -and $sl -notmatch 'CmdQuitMain' -and $sl -match 'nothing was done' -and $irSrc -notmatch 'static bool Armed\(')
$ini = ReadText 'dash\irdash.ini'
Check 'KEEP LAP is dash vkkeep, irdash accepts vkkeep, and the Vault is on (vault=1)' ((Cmd-Of 'KEEP LAP*') -eq 'dash vkkeep' -and $handled['vkkeep'] -eq 'vault' -and $ini -match '(?m)^\s*vault\s*=\s*1')
# 2026-10-18 audit: irdash answers 400 to tvview (P0-03), so a TV key on the deck can only beep. TV stays Later (off the deck) until the view is rebuilt.
Check 'TV is a Later key while irdash refuses tvview (no dead key on the deck)' (@($deck | Where-Object { $_.label -like 'TV*' -and $_.kind -eq 'later' }).Count -eq 1 -and @($deckKeys | Where-Object { $_.label -like 'TV*' }).Count -eq 0)
Check 'HOME is a real command and sits at 0,0 (the up key on every screen)' ((Cmd-Of 'HOME*') -eq 'rigon' -and @($main | Where-Object { $_.col -eq 0 -and $_.row -eq 0 -and $_.label -like 'HOME*' }).Count -eq 1)
Check 'AI RACE is the airace command the sim tree has' ((Cmd-Of 'AI RACE*') -eq 'airace start' -and $irSrc -match 'case "airace"')
# DK-2b (Peter): OFFICIAL and CAR TRACK. OFFICIAL runs the `official` command irdeck already has (K-03 builds the on-deck
# screen later; not PENDING, the command exists). CAR TRACK reuses the MY DRIVE key, whose home screen IS the car/track step
# (plugin.html MyDrive.open resets to it; there is no deeper step to open), so it changes the car & track AI RACE / TEST DRIVE use.
Check 'OFFICIAL (DK-2b) runs the official command irdeck has' ((Cmd-Of 'OFFICIAL*') -eq 'official' -and $irSrc -match 'case "official"')
# 2026-10-18 audit: plain `official` (no arguments, which is what the key sends) printed a usage line and returned 1 = a dead key. It must open the Official page.
$ofBody = Get-Body (ReadText 'src\official.cs') 'static int CmdOfficial(string[] a)'
Check 'OFFICIAL with no arguments opens the Official page (CmdNav), it does not just print usage' ($ofBody -match '(?s)a\.Length == 0\)\s*\{.*?CmdNav\(new string\[\] \{ "--button", "Official" \}\)' -and $ofBody -notmatch 'if \(a\.Length == 0\) \{ Log\("official: list')
Check 'CAR TRACK (DK-2b) opens the MY DRIVE add-on screen (its home IS the car/track step)' (@($deck | Where-Object { $_.label -like 'CAR TRACK*' -and $_.kind -eq 'plugin' -and $_.what -eq "$uuidBase.mydrive" }).Count -eq 1)
Check 'SAVE is dash recsave and irdash accepts recsave (the recorder saves the last minutes)' ((Cmd-Of 'SAVE*') -eq 'dash recsave' -and $handled['recsave'] -eq 'vault')
Check 'REVIEW is dash debrief and irdash accepts it (opens the coach for the last outing)' ((Cmd-Of 'REVIEW*') -eq 'dash debrief' -and $handled.ContainsKey('debrief'))
Check 'VAULT is dash vault and irdash accepts it (alias of vkopen, opens the Vault)' ((Cmd-Of 'VAULT*') -eq 'dash vault' -and $handled['vault'] -eq 'alias of vkopen')
Check 'no MAIN or MORE key carries a static on / off subtitle (live state is drawn by the add-on, DK-4)' (@($deck | Where-Object { $_.t2 -match '(?i)\bon\s*/\s*off\b' }).Count -eq 0)

# ================= 3. the old keys.map still works =================
Section '3. keys\keys.map (the layout on the device today) still resolves'
$mapFile = Join-Path $root 'keys\keys.map'
$deployed = [ordered]@{}
foreach ($l in [IO.File]::ReadAllLines($mapFile)) { $i = $l.IndexOf('='); if ($i -gt 0) { $deployed[$l.Substring(0, $i).Trim()] = $l.Substring($i + 1) } }
$bad = @(); $pend = @(); foreach ($n in $deployed.Keys) { $w = Test-IrCommand $deployed[$n]; if ($w -like 'pending: *') { $pend += $n } elseif ($w) { $bad += "$n = $($deployed[$n]): $w" } }
Check "all $($deployed.Count) lines of keys.map are irdeck commands that exist" ($bad.Count -eq 0) ($bad -join '; ')
if ($pend.Count -gt 0) { Note "PENDING (DK-5 wires the top-screen command): $($pend -join ', ')" }
$plan = [ordered]@{}
foreach ($l in [IO.File]::ReadAllLines("$prev\keys.map")) { $i = $l.IndexOf('='); if ($i -gt 0) { $plan[$l.Substring(0, $i).Trim()] = $l.Substring($i + 1) } }
# -Preview only records the plan; the lead's real build-deck.ps1 run writes the one exe per key. A name that is not in
# the plan is stale (a bug); a new key's missing exe waits for that run.
$noExe = @($deployed.Keys | Where-Object { -not (Test-Path (Join-Path $root "keys\$_.exe")) })
$noExeOther = @($noExe | Where-Object { -not $plan.Contains($_) })
Check 'each key in keys.map has its exe, or a plan entry the lead''s real build writes' ($noExeOther.Count -eq 0) ($noExeOther -join ', ')
$noExeNew = @($noExe | Where-Object { $plan.Contains($_) })
if ($noExeNew.Count -gt 0) { Note "PENDING (lead): the real build-deck.ps1 run writes these keys\ exes: $($noExeNew -join ', ')" }
Check "the plan has one exe name per key ($($plan.Count) names for $($deckKeys.Count) command keys)" ($plan.Count -eq $deckKeys.Count)
$changed = @($plan.Keys | Where-Object { -not $deployed.Contains($_) -or $deployed[$_] -ne $plan[$_] })
$gone = @($deployed.Keys | Where-Object { -not $plan.Contains($_) })
Note "keys.map on the device differs from the plan in $($changed.Count) key(s) and has $($gone.Count) key(s) the plan drops: the real build-deck.ps1 run writes the new map (lead + Peter)"

# ================= 4. no duplicates, short labels, x2 =================
Section '4. no two keys on a page do the same thing; labels are at most 2 short lines; x2 means confirm'
$sig = @{}
foreach ($k in $deck) {
  # a plugin key's label is part of its identity: DK-2b's CAR TRACK deliberately opens the same MY DRIVE screen (its car/track
  # step), so two plugin keys may share an action UUID while being different keys with different jobs.
  $s = if ($k.kind -eq 'key') { (($k.what -split '=', 2)[1]).ToLowerInvariant() -replace '^confirm \S+ ', '' }
       elseif ($k.kind -eq 'plugin') { 'plugin:' + $k.what + ' / ' + $k.t1 }
       else { $k.kind + ':' + $k.what }
  $k | Add-Member -NotePropertyName sig -NotePropertyValue $s -Force
}
foreach ($pg in 'MAIN', 'MORE') {
  $d = @($deck | Where-Object { $_.page -eq $pg -and $_.kind -ne 'later' } | Group-Object sig | Where-Object { $_.Count -gt 1 })
  Check "$pg : no two keys do the same thing" ($d.Count -eq 0) (($d | ForEach-Object { $_.Name }) -join '; ')
}
$both = @($deck | Where-Object { $_.kind -ne 'later' -and $_.kind -ne 'page' } | Group-Object sig | Where-Object { $_.Count -gt 1 })
Check 'no key is on both MAIN and MORE' ($both.Count -eq 0) (($both | ForEach-Object { $_.Name }) -join '; ')
$bad = @($deck | Where-Object { $_.t1 -eq '' -and $_.kind -ne 'page' })
Check 'every key has a label' ($bad.Count -eq 0) (($bad | ForEach-Object { "$($_.page) $($_.col),$($_.row)" }) -join '; ')
$bad = @($deck | Where-Object { (Ascii $_.t1).Length -gt 16 -or (Ascii $_.t2).Length -gt 16 -or $_.t1 -match '[\r\n]' -or $_.t2 -match '[\r\n]' })
Check 'every label is 2 lines at most, each 16 characters or fewer' ($bad.Count -eq 0) (($bad | ForEach-Object { "$($_.label)" }) -join '; ')
# every word on a key follows docs\COPY-RULES.md (the same banned table copy-audit-test.ps1 uses)
$labelBanned = [ordered]@{
  'addresses him'    = "(?i)\byou(?:r|rs|rself|'re|'ve|'ll)\b"
  'greeting'         = '(?i)\bgood (?:morning|afternoon|evening|night)\b|\bwelcome\b|\bready when\b|\bwhen you\b|\bhello\b'
  'filler word'      = "(?i)\b(?:just|simply|quietly|let's|here's|insights?|journey|stories|story|by itself|automatically)\b"
  'exclamation'      = '[A-Za-z0-9\)\]]!(?:\s|$|["''<])'
  'dash aside'       = "\u2014| - "
  'emoji'            = '[\u2600-\u2604\u2607-\u27BF\u2B50\u2B55]|[\uD83C-\uD83E][\uDC00-\uDFFF]'
  'broken character' = '[\u00C2\u00C3]' }
$bad = @()
foreach ($k in $deck) {
  if ($k.kind -eq 'later') { continue }
  $txt = (($k.t1 + ' ' + $k.t2).Trim())
  if (-not $txt) { continue }
  foreach ($n in $labelBanned.Keys) { if ([regex]::IsMatch($txt, $labelBanned[$n])) { $bad += "$($k.page) $($k.col),$($k.row) '$txt' ($n)" } }
}
Check 'every key label passes the copy rules (docs\COPY-RULES.md)' ($bad.Count -eq 0) ($bad -join '; ')
# SKIP SESSION is one press on purpose (2026-10-18): the two-press arm never got its second press. The command itself refuses official sessions and a moving car.
$ends = @('quitmain', 'restartrace', 'power sleep', 'power lock')
$bad = @()
foreach ($k in $deckKeys) {
  $c = ($k.what -split '=', 2)[1]; $x2 = ($k.t2 -match '\bx2\b') -or ($k.t1 -match '\bx2\b'); $conf = $c -match '^confirm '
  if ($x2 -ne $conf) { $bad += "$($k.label): label x2=$x2, confirm=$conf" }
  foreach ($e in $ends) { if ($c -match "(^|\s)$e(\s|$)" -and -not $conf) { $bad += "$($k.label) ends something without a second press" } }
}
Check 'a key marked x2 is a confirm key, and every key that ends a session or the PC needs the second press' ($bad.Count -eq 0) ($bad -join '; ')
$names = @($plan.Keys); $dupNames = @($names | Group-Object | Where-Object { $_.Count -gt 1 })
Check 'every key has its own exe name' ($dupNames.Count -eq 0)

# ================= 5. the add-on screens =================
Section '5. add-on screens (FRIENDS, OVERLAYS, MY DRIVE, REPLAY, ANALYSIS, SOUND): every action is handled'
$screens = @(
  @{ name = 'FRIENDS';  start = 'const Friends = new class extends Screen';  end = '// ---------------- Rig Doctor key';        guest = $true;  route = '/guest';    own = 'dash\src\irdash.cs'
     fields = 'session', 'driving', 'driverId', 'drivers', 'driver', 'car', 'track', 'carList', 'trackList', 'wheel', 'line', 'coach', 'board', 'voiceDraft', 'event' },
  @{ name = 'OVERLAYS'; start = 'const Overlays = new class extends Screen'; end = '// ---------------- My Drive screen';       guest = $false; route = '/overlays'; own = 'dash\src\overlays.cs'
     fields = 'widgets', 'presets', 'saveTo', 'running', 'waiting', 'pending', 'busy', 'editing', 'onCount', 'msg', 'msgAge', 'delta', 'driving' },
  @{ name = 'MY DRIVE'; start = 'const MyDrive = new class extends Screen';  end = '// ---------------- Replay screen';         guest = $false; route = '/mydrive';  own = 'dash\src\mydrive.cs'
     fields = 'ready', 'session', 'busy', 'msg', 'phase', 'recent', 'all', 'favs', 'choice', 'current', 'results', 'driving', 'last', 'speedtest' },
  @{ name = 'REPLAY';   start = 'const Replay = new class extends Screen';   end = '// ---------------- Analysis screen'; guest = $false; route = '/replay';   own = 'dash\src\replay.cs'
     fields = 'ready', 'inSession', 'driving', 'mode', 'raw', 'live', 'session', 'watch', 'nextSession', 'camera', 'me', 'ahead', 'behind', 'leader', 'cars', 'photo', 'replays', 'multiClass' },
  @{ name = 'ANALYSIS'; start = 'const Analysis = new class extends Screen'; end = '// ---------------- Sound screen';           guest = $false; route = '/workbench/state'; own = 'dash\src\deckfeed.cs'
     fields = 'open', 'driving', 'page', 'pages', 'playing', 'speed', 'tile', 'mapColour', 'zoomed', 'offset', 'id', 'lap', 'ref', 'laps', 'events', 'corners', 'lapTime', 'refTime' },
  @{ name = 'SOUND';    start = 'const Sound = new class extends Screen';    end = '// The deck key presses and the profile tiles'; guest = $false; route = '/sound'; own = @('src\sound.cs', 'dash\src\sound.cs')
     fields = 'ready', 'items', 'live', 'vol', 'mute', 'kind', 'using', 'default', 'preset' } )
$unionCmds = @($handled.Keys); $guestSet = @($guestCmds)
$addonRows = New-Object Collections.Generic.List[object]
$deadKnown = @(); $longLabels = @()
$addonBad = @()
foreach ($sc in $screens) {
  $i = $plug.IndexOf($sc.start); $j = if ($i -ge 0) { $plug.IndexOf($sc.end, $i) } else { -1 }
  if ($i -lt 0 -or $j -le $i) { Check "plugin.html: the $($sc.name) screen was found" $false "markers not found: '$($sc.start)'"; continue }
  $text = $plug.Substring($i, $j - $i)
  $methods = @([regex]::Matches($text, '(?m)^  (?:async )?(\w+)\([^)]*\) \{') | ForEach-Object { [pscustomobject]@{ idx = $_.Index; name = $_.Groups[1].Value } })
  $bounds = @([regex]::Matches($text, '(?m)^    (?:\} else \{|if \(.*\) \{)\s*$') | ForEach-Object { $_.Index })
  $calls = @(Get-Calls $text '(?<![\w.])add\(')
  $cmdCalls = @(Get-Calls $text 'this\.cmd\(')
  # 5a. every command the screen sends: the add() acts plus the this.cmd(...) calls
  $acts = @{}   # act -> status
  $rowsHere = @()
  foreach ($c in $calls) {
    $a = $c.args; function G($n) { if ($a.Count -gt $n) { return $a[$n] } return '' }
    $act = (G 6); $actLits = @(); if ($act -ne '' -and $act -ne 'null') { $actLits = @(Lits $act | Where-Object { $_ -ne '' }) }
    $m = $methods | Where-Object { $_.idx -lt $c.idx } | Select-Object -Last 1
    $mName = if ($m) { $m.name } else { '?' }; $mIdx = if ($m) { $m.idx } else { 0 }
    $branch = @($bounds | Where-Object { $_ -gt $mIdx -and $_ -lt $c.idx }).Count
    $posLit = if ((G 0) -match '^\d+$' -and (G 1) -match '^\d+$') { "$((G 0)),$((G 1))" } else { '' }
    $one = ((G 2) -eq '1' -and (G 3) -eq '1')
    $textLit = @(Lits (G 4)); $subLit = @(Lits (G 5)); $styleLit = @(Lits (G 8))
    $label = if ($textLit.Count -gt 0 -and $textLit[0] -ne '') { $textLit[0] } else { '<' + (Ascii (G 4)) + '>' }
    if ($subLit.Count -gt 0 -and $subLit[0] -ne '') { $label += ' / ' + $subLit[0] }
    $row = [pscustomobject]@{ page = $sc.name; pos = $(if ($posLit) { $posLit } else { (Ascii ((G 0) + ',' + (G 1))) }); label = (Ascii $label); act = ($actLits -join '|'); arg = (G 7); method = $mName; branch = $branch; posLit = $posLit; status = '' }
    foreach ($l in $actLits) { if (-not $acts.ContainsKey($l)) { $acts[$l] = '' } }
    if ($one -and $textLit.Count -gt 0 -and $textLit[0].Length -gt 16) { $longLabels += "$($sc.name) $posLit '$($textLit[0])'" }
    if ($one -and $subLit.Count -gt 0 -and $subLit[0].Length -gt 26) { $longLabels += "$($sc.name) $posLit '$($subLit[0])'" }
    if ($actLits.Count -eq 0 -and $subLit.Count -gt 0 -and $subLit[0] -match 'coming later|not built|todo') { $deadKnown += "$($sc.name) $posLit '$($textLit[0])' says '$($subLit[0])' and does nothing" ; $row.status = 'DEAD (says coming later)' }
    $rowsHere += $row
  }
  foreach ($act in @($acts.Keys)) {
    $inIr = if ($sc.guest) { $guestSet -contains $act } else { $unionCmds -contains $act }
    $local = $text -match "r\.act === '$([regex]::Escape($act))'"
    if ($inIr) { $acts[$act] = 'irdash' } elseif ($local) { $acts[$act] = 'add-on (local)' } else { $acts[$act] = 'NOT HANDLED' }
  }
  $cmdLits = @()
  foreach ($c in $cmdCalls) {
    if ($c.args.Count -eq 0) { continue }
    $first = $c.args[0]
    if ($first -match "^'(\w+)'$") { $cmdLits += $Matches[1] } else { foreach ($m in [regex]::Matches($first, "[?:]\s*'(\w+)'")) { $cmdLits += $m.Groups[1].Value } }
  }
  $cmdLits = @($cmdLits | Sort-Object -Unique)
  $unhandled = @($acts.Keys | Where-Object { $acts[$_] -eq 'NOT HANDLED' })
  $cmdBad = @($cmdLits | Where-Object { $unionCmds -notcontains $_ -and ($sc.name -ne 'FRIENDS' -or $guestSet -notcontains $_) })
  Check "$($sc.name): all $($acts.Count) key actions are handled by irdash or by the add-on itself" ($unhandled.Count -eq 0) ('not handled: ' + ($unhandled -join ', '))
  Check "$($sc.name): every command the screen sends to irdash is one irdash accepts ($($cmdLits -join ', '))" ($cmdBad.Count -eq 0) ('irdash refuses: ' + ($cmdBad -join ', '))
  foreach ($row in $rowsHere) {
    if ($row.act -eq '') { if (-not $row.status) { $row.status = 'display only (no action)' } }
    else { $parts = @($row.act -split '\|' | ForEach-Object { $acts[$_] }); $row.status = if ($parts -contains 'NOT HANDLED') { 'FAIL: not handled' } else { 'ok: ' + (($parts | Sort-Object -Unique) -join ' / ') } }
    $addonRows.Add($row)
  }
  # 5b. no two keys of one layout do the same: same act + argument at two different fixed positions in one branch of one method
  $dups = @($rowsHere | Where-Object { $_.act -ne '' -and $_.posLit -ne '' } | Group-Object { $_.method + '#' + $_.branch + '#' + $_.act + '#' + $_.arg } | Where-Object { @($_.Group | Select-Object -ExpandProperty posLit -Unique).Count -gt 1 })
  Check "$($sc.name): no two keys of one layout do the same thing" ($dups.Count -eq 0) (($dups | ForEach-Object { $_.Name }) -join '; ')
  # 5c. the data the screen draws from: fields it reads exist in irdash's JSON writer
  $ownSrc = (@($sc.own | ForEach-Object { ReadText $_ })) -join "`n"
  $read = @($sc.fields | Where-Object { $text -match "\.$_\b" })
  $missing = @($read | Where-Object { $ownSrc -notmatch ('\\"' + $_ + '\\"') -and $ownSrc -notmatch ('"' + $_ + '"') })
  Check "$($sc.name): the $($read.Count) fields its keys read are in irdash's $($sc.route) JSON ($($sc.own))" ($missing.Count -eq 0 -and $read.Count -ge 5) ('missing: ' + ($missing -join ', '))
  Check "$($sc.name): irdash serves $($sc.route)" ($irdash.Contains('"' + $sc.route + '"'))
  if ($sc.name -eq 'MY DRIVE') { Note 'MY DRIVE: MOST TO GAIN is drawn only when /mydrive carries a gain object; irdash sends one since P5 (dash\src\gain.cs, tests\rig-leftovers-test.ps1) once it knows one, otherwise that cell stays empty on the deck (no dead key)' }
}
# routes the add-on calls that are not screens
$routes = @([regex]::Matches($plug, "'(/api/[a-z/]+)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$noRoute = @($routes | Where-Object { -not $irdash.Contains('"' + $_ + '"') })
Check "irdash has every /api route the add-on calls ($($routes -join ', '))" ($noRoute.Count -eq 0) ($noRoute -join ', ')
$docCmd = [regex]::Matches($plug, "c=([a-z]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$noCmd = @($docCmd | Where-Object { $unionCmds -notcontains $_ })
Check "irdash accepts every direct command call in the add-on ($($docCmd -join ', '))" ($noCmd.Count -eq 0) ($noCmd -join ', ')
foreach ($d in $deadKnown) { Warn "dead key on a screen (needs an add-on change, lead's next add-on batch): $d" }
if ($longLabels.Count -gt 0) { Warn "add-on labels longer than 2 short lines on a single key: $($longLabels -join '; ')" }

# ================= 6. live data, if irdash is up =================
if (-not $StaticOnly) {
  Section '6. irdash answers the routes the add-on screens read (read-only GET)'
  foreach ($sc in $screens) {
    try {
      $r = Invoke-WebRequest -UseBasicParsing ("http://localhost:8199" + $sc.route) -TimeoutSec 6
      $j = $r.Content | ConvertFrom-Json
      $names = @($j.PSObject.Properties | ForEach-Object { $_.Name })
      Check "$($sc.route) is valid JSON with $($names.Count) fields" ($r.StatusCode -eq 200 -and $names.Count -gt 0)
      $absent = @($sc.fields | Where-Object { $names -notcontains $_ })
      if ($absent.Count -gt 0) { Note "$($sc.route): not in the answer right now (may depend on the state): $($absent -join ', ')" }
    } catch { Warn "$($sc.route): irdash is not answering ($($_.Exception.Message)); the live read was skipped" }
  }
}

# ================= 7. what the table says =================
Section '7. the key table'
$tbl = New-Object Collections.Generic.List[string]
$tbl.Add(('{0,-9} {1,-6} {2,-30} {3,-46} {4}' -f 'PAGE', 'POS', 'LABEL', 'COMMAND', 'STATUS'))
foreach ($k in ($deck | Sort-Object page, row, col)) {
  $cmd = switch ($k.kind) { 'key' { ($k.what -split '=', 2)[1] } 'plugin' { 'add-on screen ' + ($k.what -replace '^.*\.', '') } 'page' { 'Stream Deck page ' + $k.what } 'live' { 'iRaceDeck ' + $k.what } default { '(none)' } }
  $tbl.Add(('{0,-9} {1,-6} {2,-30} {3,-46} {4}' -f $k.page, "$($k.col),$($k.row)", $k.label, (Ascii $cmd), $k.status))
}
foreach ($r in $addonRows) {
  $cmd = if ($r.act) { ($r.act + $(if ($r.arg -and $r.arg -ne 'null') { ' ' + (Ascii $r.arg) } else { '' })) } else { '-' }
  $lab = $r.label; if ($lab.Length -gt 30) { $lab = $lab.Substring(0, 29) + '~' }
  if ($cmd.Length -gt 46) { $cmd = $cmd.Substring(0, 45) + '~' }
  $tbl.Add(('{0,-9} {1,-6} {2,-30} {3,-46} {4}' -f $r.page, $r.pos, $lab, $cmd, $r.status))
}
$doNothing = @(($deck | Where-Object { $_.kind -eq 'later' }) | ForEach-Object { "$($_.page) $($_.col),$($_.row) $($_.label) (not on the deck)" }) + @($addonRows | Where-Object { $_.status -like 'DEAD*' } | ForEach-Object { "$($_.page) $($_.pos) $($_.label)" })
$tbl.Add('')
$tbl.Add('Keys that do nothing: ' + $(if ($doNothing.Count) { $doNothing -join '; ' } else { 'none' }))
$tbl.Add("Deck: $($main.Count) MAIN + $($more.Count) MORE keys planned ($(@($deck | Where-Object { $_.kind -ne 'later' }).Count) on the device), $($addonRows.Count) add-on tiles read")
foreach ($l in $tbl) { Say $l }

# ================= 8. dry runs (live, rig must be free) =================
if ($StaticOnly) { Note 'section 8 (dry runs of the real commands) skipped: -StaticOnly' }
else {
  Section '8. dry runs: the commands that refuse without a session, and the --dry forms'
  $cliPath = if ($Cli) { $Cli } else { Join-Path $root 'irdeck-cli.exe' }
  Check "irdeck-cli.exe exists ($cliPath)" (Test-Path $cliPath)
  # the --dry forms are new (C-31). An older exe would IGNORE --dry and really start a drive or change the volume, so look for their text first.
  $bytes = [IO.File]::ReadAllBytes($cliPath); $hay = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
  $needle = (([Text.Encoding]::Unicode.GetBytes('(dry): no session is running') | ForEach-Object { [char]$_ }) -join '')
  $newCli = $hay.Contains($needle)
  if (-not $newCli) { Warn "irdeck-cli.exe is older than src\irdeck.cs (no --dry forms): startlast / appvol / dash are NOT run. Lead: powershell -ExecutionPolicy Bypass -File build-irdeck.ps1 when sim=False, then rerun" }
  function Ir { $o = & $cliPath @args 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join "`n") } }
  function Dry($label, $irArgs, $okRc, $okText, $needsNew) {
    if ($needsNew -and -not $newCli) { Note "not run (needs the new irdeck): $label"; return }
    try { Assert-RigFree -Where $label } catch { Say "$_"; Save-Out; exit 3 }
    $r = Ir @irArgs
    $clean = $r.out -notmatch 'ERROR |Exception|Unhandled'
    Check "$label -> rc $($r.rc), '$($r.out -replace '^> .*?\n', '' -replace '\s+', ' ')'" ($clean -and ($okRc -contains $r.rc) -and ($r.out -match $okText))
  }
  $ran = @{}
  foreach ($k in $deckKeys) {
    $line = ($k.what -split '=', 2)[1] -replace '^confirm \S+ ', ''
    if ($ran.ContainsKey($line)) { continue }; $ran[$line] = 1
    $t = @(Split-Cmd $line)
    switch ($t[0].ToLowerInvariant()) {
      'startlast' { Dry "$($k.label): $line --dry" ($t + '--dry') @(0) 'dry\)' $true }
      'appvol'    { Dry "$($k.label): $line --dry" ($t + '--dry') @(0) 'dry\)' $true }
      'dash'      { Dry "$($k.label): $line --dry" ($t + '--dry') @(0, 1) 'dry\)|not reachable' $true }
      'pittoggle' { Dry "$($k.label): $line (no session)" $t @(3) 'no sim session running' $false }
      'getout'    { Dry "$($k.label): $line (no session)" $t @(3) 'no sim session running' $false }
      'skip'      { Dry "$($k.label): $line (no session)" $t @(3) 'no session is running' $false }
      'chat'      { if ($t[1] -eq 'say') { Dry "$($k.label): $line (no session)" $t @(3) 'no sim session running' $false } else { Note "not run (it would send a chat command): $($k.label)" } }
      'key'       { Dry "$($k.label): $line (sim not in front)" $t @(3) 'refused' $false }
      'tow'       { Dry "$($k.label): tow --pretend 0.4" @('tow', '--pretend', '0.4') @(0) 'stationary' $false }
      default     { Note "not run (it would act, no dry form): $($k.label) = $line" }
    }
  }
}

# ================= 9. defects found by reading the code (2026-10-18 audit); each of these was wrong before =================
Section '9. regressions: dead keys, lying labels, doubled presses, frozen screens, the guide'
# 9a. no deck key sends irdash a command that irdash always answers with an error (the key could only beep)
$refused = @([regex]::Matches($irdash, 'if \(dc == "(\w+)"\) \{ Send\(s, 4\d\d') | ForEach-Object { $_.Groups[1].Value })
$badDash = @($deckKeys | Where-Object { $c = ($_.what -split '=', 2)[1]; $c -match '^dash\s+(\w+)' -and $refused -contains $Matches[1] })
Check "no deck key sends irdash a command it always refuses ($($refused -join ', '))" ($refused.Count -ge 1 -and $badDash.Count -eq 0) (($badDash | ForEach-Object { $_.label }) -join ', ')
# 9b. GET IN (`smart`) must never arm a SKIP. Its picture is fixed (the add-on has no smart key action), but the resolver says SKIP in a Test Drive / AI garage.
$smart = Get-Body $irSrc 'static int CmdSmart(string[] args)'
$realPath = $smart.Substring($smart.IndexOf('if (isFake) return 3;'))
# live 2026-10-19: SKIP SESSION in a Test Drive clicked the DRIVER Prev/Next buttons and did nothing; it now ends the drive like QUIT
$skipSrc = [regex]::Match($irSrc, '(?s)static int CmdSkip\(\).*?\r?\n        \}').Value
Check 'SKIP SESSION in a Test Drive ends it back to the menu (CmdQuitMain) instead of clicking the driver Prev/Next buttons' ($skipSrc -match 'testSession && !s0\.Ai' -and $skipSrc -match 'return CmdQuitMain\(\)')
Check 'GET IN (smart) does not arm a skip-session confirm outside the fake test path' ($smart.Contains('if (isFake) return 3;') -and $realPath -notmatch 'CmdConfirm' -and $realPath -match 'GoDriveOnly\(true\)')
Check 'the add-on has no smart / skip key action, so GET IN is a fixed picture' ($inst -notmatch 'UUID = "\$uuid\.(smart|skip|quit|restart)"')
# 9c. HOME (rigon) with a session running must not maximise the iRacing UI over the sim
$rig = Get-Body $irSrc 'static int CmdRigOn(string[] a)'
Check 'HOME (rigon without --boot) does nothing while a session runs' ($rig -match '!boot && SessionActive\(\)' -and $rig.IndexOf('SessionActive()') -lt $rig.IndexOf('StartApp("StreamDeck"'))
# 9d. add-on: doubled presses, a frozen screen, the CAR TRACK picture
$onceM = [regex]::Match($plug, 'const ONCE_ACTS = new Set\(\[([^\]]*)\]\)')
$onceActs = @([regex]::Matches($onceM.Groups[1].Value, "'([\w-]+)'") | ForEach-Object { $_.Groups[1].Value })
$flip = 'ovtoggle', 'deltaon', 'mddamage', 'mdstar', 'line', 'coach', 'board', 'rpplay', 'rphideui', 'rpautotv', 'wb-map-colour'
$missingOnce = @($flip | Where-Object { $onceActs -notcontains $_ })
Check 'every on/off key of the add-on screens ignores a doubled press (ONCE_ACTS)' ($onceM.Success -and $missingOnce.Count -eq 0 -and $plug -match 'r\.once \|\| ONCE_ACTS\.has\(r\.act\)') ($missingOnce -join ', ')
Check 'an add-on screen whose irdash stops answering says so on its keys, and keeps an EXIT key' ($plug -match 'showOffline\(\) \{' -and $plug -match 'bad >= 4 && !this\.offline' -and $plug -match 'if \(this\.offline\) \{ if \(col === COLS - 1 && row === ROWS - 1\) this\.exit\(\)')
$ct = @($main | Where-Object { $_.label -like 'CAR TRACK*' } | Select-Object -First 1)
$myd = $plug.Substring($plug.IndexOf('const MyDrive = new class extends Screen'))
$myd = $myd.Substring(0, $myd.IndexOf('async keyTick()'))
Check 'CAR TRACK (same add-on screen as MY DRIVE) gets its own picture, chosen by its place on the deck' ($ct.Count -eq 1 -and $myd -match "keyPos\[ctx\] === '$($ct[0].col),$($ct[0].row)'" -and $myd -match "'CAR', 'TRACK'" -and $plug -match 'keyScreen\.keyPos\[e\.context\] = pos')
# 9e. docs\USER-GUIDE.md names every key on the deck, and none of the old names
$guide = Ascii (ReadText 'docs\USER-GUIDE.md')
$noGuide = @($deck | Where-Object { $_.kind -in 'key', 'plugin', 'later' } | ForEach-Object { ($_.label -replace '\s+x2$', '').ToUpperInvariant() } | Where-Object { $guide.ToUpperInvariant().IndexOf($_) -lt 0 })
Check 'the user guide names every key on MAIN and MORE' ($noGuide.Count -eq 0) ($noGuide -join ', ')
$stale = @('DRIVE . CONTINUE', 'TOW TO PITS', 'QUIT TO MAIN', '**DEBRIEF**', 'FAST REPAIR**', 'OFFICIAL RACING**', 'SAVE . RESET POINT', 'TEAR OFF**', 'FRIENDS MODE**', 'SHOWCASE . INTRO', 'OVERLAYS SCREEN**') | Where-Object { $guide.ToUpperInvariant().Contains($_.ToUpperInvariant()) }
Check 'the user guide has none of the old key names' (@($stale).Count -eq 0) (@($stale) -join ', ')
Say ''
Say ("$pass passed, $fail failed" + $(if ($warns) { "   ($warns warnings)" } else { '' }))
Save-Out
if ($fail -gt 0) { exit 1 } else { exit 0 }
