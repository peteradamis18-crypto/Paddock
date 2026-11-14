# Builds the "iRacing GT3" Stream Deck XL profile from deck\layout.json (W3-4: the ONE layout; PLAN 4.6): the pages LEAVE, MAIN and
# MORE, one small exe per command key in .\keys (each looks up its command in keys\keys.map), and the key pictures made by
# tools\deck-render.ps1 (deck\render.html, the same drawing as the add-on: deck\keyart.js). Nothing is drawn here any more.
#   powershell -ExecutionPolicy Bypass -File build-deck.ps1             (Stream Deck must be closed; the lead runs tools\deck-refresh.ps1)
#   powershell -ExecutionPolicy Bypass -File build-deck.ps1 -Preview    (renders the pictures into deck\ and writes %TEMP%\PaddockPreview-*:
#                                                                         MAIN.png, MORE.png, LEAVE.png, layout.tsv, keys.map; touches nothing else)
# A key whose add-on action is not in the INSTALLED add-on is left off the real deck (a key for an action that is not installed is
# dead, and Stream Deck may drop a page with one): run tools\addon-update.ps1 first, then this.
param([switch]$Preview, [switch]$NoRender)
$ErrorActionPreference = 'Stop'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe   = Join-Path $here 'irdeck.exe'
$keys  = Join-Path $here 'keys'
$deckDir = Join-Path $here 'deck'
$sdRoot = "$env:APPDATA\Elgato\StreamDeck\ProfilesV3"
$profId = '65E017A2-2219-43EE-A4E4-44D505F5B406'   # the profile your deck is already set to
$profDir = "$sdRoot\$profId.sdProfile"
$u8 = New-Object Text.UTF8Encoding $false
function G { [guid]::NewGuid().ToString() }
$previewRun = Join-Path ([IO.Path]::GetTempPath()) ('PaddockPreview-' + [guid]::NewGuid().ToString('N'))
if ($Preview) { New-Item -ItemType Directory -Force $previewRun | Out-Null }

# ---------- the layout and its pictures ----------
$L = [IO.File]::ReadAllText((Join-Path $deckDir 'layout.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
if (-not $NoRender -or -not (Test-Path (Join-Path $deckDir 'keys\MAIN'))) {
  $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'tools\deck-render.ps1') 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $deckDir 'keys\MAIN'))) { throw ('the key pictures were not made (tools\deck-render.ps1): ' + ($o -join ' ')) }
}
# the add-on's name and version as the installer writes them (audit 11, A5: the keys used to say "Rig Intro" 1.1.0.0)
$inst = [IO.File]::ReadAllText((Join-Path $here 'deck-intro\install.ps1'))
$uuid = [regex]::Match($inst, "\`$uuid = '([^']+)'").Groups[1].Value
$plugVer = [regex]::Match($inst, "\`$ver = '([^']+)'").Groups[1].Value
# what the INSTALLED add-on has (a key for a missing action stays off the real deck); -Preview shows the plan
$sdPlugin = Join-Path $env:APPDATA "Elgato\StreamDeck\Plugins\$uuid.sdPlugin\manifest.json"
$installed = if (Test-Path $sdPlugin) { [IO.File]::ReadAllText($sdPlugin) } else { '' }
function ActionOn($name) { $Preview -or $installed -match ([regex]::Escape("$uuid.$name") + '"') }

# ---------- one exe per command key ----------
New-Item -ItemType Directory $keys -Force | Out-Null
$keyMap = [ordered]@{}
function Lnk($name, $argString) {
  if ($script:keyMap.Contains($name) -and $script:keyMap[$name] -ne $argString) { throw "keys.map: '$name' is two different commands" }
  $script:keyMap[$name] = $argString
  if ($Preview) { return "(preview)" }
  $p = Join-Path $keys "$name.exe"
  # copy only when different, so a key that is running right now never blocks the build
  if (-not (Test-Path -LiteralPath $p) -or (Get-FileHash -LiteralPath $p).Hash -ne (Get-FileHash -LiteralPath $exe).Hash) {
    try { Copy-Item -LiteralPath $exe -Destination $p -Force } catch { Write-Warning "key $name is in use; it keeps its current exe until next build" }
  }
  return $p
}

# ---------- write the profile ----------
if (-not $Preview) {
  if (Get-Process StreamDeck -ErrorAction SilentlyContinue) { throw "Close Stream Deck first (it only reads profiles when it starts)." }
  # tell the irdash watchdog not to restart Stream Deck while the pages are half written (dash\deck-build.lock, see irdash.cs Tick)
  $buildLock = Join-Path $here 'dash\deck-build.lock'; $ownLock = -not (Test-Path $buildLock)
  [IO.File]::WriteAllText($buildLock, (Get-Date).ToString('o'))
  $dev = (Get-Content "$profDir\manifest.json" -Raw | ConvertFrom-Json).Device
  $oldPages = @(Get-ChildItem "$profDir\Profiles" -Directory -ErrorAction SilentlyContinue)   # removed only after the new pages are written
}
$ids = @{ MAIN = G; MORE = G; LEAVE = G }
# One line per key, written next to the pictures in -Preview: page, col, row, line 1, line 2, kind, what it does.
# tests\keys-test.ps1 and tests\deck-layout-test.ps1 read it.
$layout = New-Object Collections.Generic.List[string]
$missing = New-Object Collections.Generic.List[string]
function Write-Page($name) {
  $dir = if ($Preview) { Join-Path $previewRun $name } else { "$profDir\Profiles\$($ids[$name].ToUpper())" }
  New-Item -ItemType Directory "$dir\Images" -Force | Out-Null
  $actions = [ordered]@{}
  foreach ($k in $L.pages.$name) {
    $pos = "$($k.c),$($k.r)"; $a = $k.action
    $pic = Join-Path $deckDir "keys\$name\$pos.png"
    if (-not (Test-Path -LiteralPath $pic)) { throw "no picture for $name $pos (tools\deck-render.ps1)" }
    $img = (-join ((65..90) + (48..57) | Get-Random -Count 26 | ForEach-Object { [char]$_ })) + 'Z'
    $l1 = [string]$k.label[0]; $l2 = if ($k.label.Count -gt 1) { [string]$k.label[1] } else { '' }
    $state = [ordered]@{ FontFamily = ''; FontSize = 12; FontStyle = ''; FontUnderline = $false; Image = "Images/$img.png"; OutlineThickness = 2; ShowTitle = $false; Title = ''; TitleAlignment = 'bottom'; TitleColor = '#ffffff' }
    if ($a.exe) {
      $what = "$($a.exe)=$($a.args)"; $kind = 'key'
      $path = Lnk $a.exe $a.args
      $act = [ordered]@{ ActionID = (G); LinkedTitle = $true; Name = 'Open'; Resources = $null; Settings = [ordered]@{ path = "`"$path`"" }; State = 0; States = @($state); UUID = 'com.elgato.streamdeck.system.open' }
    } elseif ($a.screen -or $a.plugin) {
      # a key drawn and handled by our own add-on (deck-intro\plugin.html): a screen's opener, or the CONFIRM key with its "what"
      $an = if ($a.screen) { $a.screen } else { $a.plugin }
      $what = "$uuid.$an"; $kind = 'plugin'
      if (-not (ActionOn $an)) { $script:missing.Add("$name $pos $l1 $l2 ($an)"); $layout.Add((@($name, $k.c, $k.r, $l1, $l2, 'missing', $what) -join "`t")); continue }
      $settings = [ordered]@{}; if ($a.what) { $settings['what'] = $a.what }
      $act = [ordered]@{ ActionID = (G); LinkedTitle = $true; Name = $an
        Plugin = [ordered]@{ Name = 'Paddock'; UUID = $uuid; Version = $plugVer }
        Resources = $null; Settings = $settings; State = 0; States = @($state); UUID = $what }
    } elseif ($a.page) {
      # Stream Deck's built-in page switching (the pages are LEAVE, MAIN, MORE: MORE = next, LEAVE = previous)
      $what = $a.page; $kind = 'page'
      $pn = if ($a.page -eq 'next') { 'Next Page' } else { 'Previous Page' }
      $act = [ordered]@{ ActionID = (G); LinkedTitle = $true; Name = $pn; Resources = $null; Settings = [ordered]@{}; State = 0; States = @($state); UUID = "com.elgato.streamdeck.page.$($a.page)" }
    } else { throw "layout.json: $name $pos has no action" }
    $layout.Add((@($name, $k.c, $k.r, $l1, $l2, $kind, $what) -join "`t"))
    Copy-Item -LiteralPath $pic "$dir\Images\$img.png"
    $actions[$pos] = $act
  }
  if ($Preview) { Copy-Item -LiteralPath (Join-Path $deckDir "preview-$name.png") (Join-Path $previewRun "$name.png"); return }
  $pm = [ordered]@{ Controllers = @([ordered]@{ Actions = $actions; Type = 'Keypad' }); Icon = ''; Name = $name }
  [IO.File]::WriteAllText("$dir\manifest.json", ($pm | ConvertTo-Json -Depth 30), $u8)
}
foreach ($p in $L.pageOrder) { Write-Page $p }
if ($Preview) {
  [IO.File]::WriteAllLines((Join-Path $previewRun 'layout.tsv'), [string[]]$layout, $u8)
  [IO.File]::WriteAllLines((Join-Path $previewRun 'keys.map'), [string[]]($keyMap.Keys | ForEach-Object { "$_=$($keyMap[$_])" }), $u8)
  "preview written to $previewRun (pictures: deck\preview-MAIN.png, deck\preview-MORE.png, deck\preview-LEAVE.png)"; return
}
[IO.File]::WriteAllLines((Join-Path $keys 'keys.map'), [string[]]($keyMap.Keys | ForEach-Object { "$_=$($keyMap[$_])" }), $u8)
# remove key exes from older layouts that no longer have a key
Get-ChildItem -LiteralPath $keys -Filter *.exe -File | Where-Object { -not $keyMap.Contains($_.BaseName) } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
# new pages are complete: now drop the old ones (a failed build above leaves the old profile intact)
foreach ($d in $oldPages) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
# Stream Deck's Default page is a hidden empty page of its own, never one of the listed pages (every profile it makes is like that).
# We used to name MAIN as Default too: its log then said "Failed to map default page" for MAIN, and that is when it pruned MAIN
# and left blank keys (2026-10-18, 2026-10-23). Current = MAIN is what makes the deck open on MAIN.
$ids.dflt = G
New-Item -ItemType Directory "$profDir\Profiles\$($ids.dflt.ToUpper())\Images" -Force | Out-Null
[IO.File]::WriteAllText("$profDir\Profiles\$($ids.dflt.ToUpper())\manifest.json", '{"Controllers":[{"Actions":null,"Type":"Keypad"}],"Icon":"","Name":""}', $u8)
$tm = [ordered]@{ Device = $dev; Name = 'iRacing GT3'; Pages = [ordered]@{ Current = $ids.MAIN; Default = $ids.dflt; Pages = @($L.pageOrder | ForEach-Object { $ids[$_] }) }; Version = '3.0' }
[IO.File]::WriteAllText("$profDir\manifest.json", ($tm | ConvertTo-Json -Depth 10), $u8)
if ($ownLock) { Remove-Item -LiteralPath $buildLock -Force -ErrorAction SilentlyContinue }   # deck-refresh owns it otherwise, until Stream Deck is back
"built: " + (($L.pageOrder | ForEach-Object { "$_ $(@($L.pages.$_).Count) keys" }) -join ', ') + "; $($keyMap.Count) key exes"
if ($missing.Count -gt 0) { "NOT DONE: these keys are LEFT OFF the deck because the installed add-on does not have their action yet: $($missing -join '; '). Run tools\addon-update.ps1, then build-deck.ps1 again." }
