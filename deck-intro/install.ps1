# Installs the Paddock add-on (the folder, the UUID and the profile names keep the old "rigintro" / "Rig..." names) into the
# Stream Deck app: the startup flag sequence across all 32 keys, the
# live friends mode screen (RigFriends profile, opened by the FRIENDS key on your own profile), the live
# overlays screen (RigOverlays profile, opened by the OVERLAYS key), the My Drive screen (RigMyDrive
# profile, opened by the MY DRIVE action - now the RACE SETUP screen), the REPLAY screen
# (RigReplay profile, opened by the REPLAY key on the MAIN page), the ANALYSIS screen (RigAnalysis, the ANALYSIS key on MAIN)
# and the SOUND screen (RigSound, the SOUND key on the MORE page).
# Builds the plugin folder (manifest, page, icons, and the bundled one-page RigIntro profile whose 32 keys
# are the animation tiles), copies it into Stream Deck's Plugins folder, and restarts Stream Deck so it
# loads. Refuses while you are driving. Re-run after editing plugin.html.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$uuid = 'com.peter.rigintro'
$ver = '1.8.4.0'   # bump on every change so Stream Deck treats a re-install as an update (1.6: REPLAY screen, name Paddock, garbled signs fixed; 1.6.1: PHOTO key dims when iRacing's screen capture is off; 1.7: ANALYSIS and SOUND screens, MY DRIVE became RACE SETUP, AI RACE tile gone; 1.7.1: ANALYSIS page row with more than 8 pages = 7 + a PAGES key and a page picker, CAREER and PRO named; 1.7.2: AU-1 words - key subtitles only where they add information, no emoji; 1.8: deck v3 - SMART key from /deck/state, ARMED 3-2-1 on QUIT/RESTART/SKIP, MY DRIVE START after a pick; 1.8.2: car/track picker - RECENT / CARS / TRACKS lists, one key per item, NO CHOICE opens it; 1.8.3: CAR TRACK key shows its own name, toggles ignore a doubled press, a screen says DASHBOARD NOT ANSWERING instead of freezing; 1.8.4: deck v2 - CAR TRACK picture at its new place 3,0)
$build = Join-Path $here "build\$uuid.sdPlugin"
$dest = Join-Path $env:APPDATA "Elgato\StreamDeck\Plugins\$uuid.sdPlugin"
$cli = Join-Path (Split-Path -Parent $here) 'irdeck-cli.exe'
if ((& $cli state) -match 'telemetry=on') { 'iRacing is in a session - run this when you are out of the car.'; exit 1 }

Add-Type -AssemblyName System.Drawing, System.IO.Compression, System.IO.Compression.FileSystem
if (Test-Path $build) { Remove-Item -LiteralPath $build -Recurse -Force }
New-Item -ItemType Directory -Force "$build\img" | Out-Null
Copy-Item (Join-Path $here 'plugin.html') "$build\plugin.html"

# icons: a gold "4" on black (plugin list) and a plain black tile
function Icon($file, $size, $text) {
  $b = New-Object Drawing.Bitmap $size, $size; $g = [Drawing.Graphics]::FromImage($b)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.Clear([Drawing.Color]::Black)
  if ($text) {
    $f = New-Object Drawing.Font('Bahnschrift', [single]($size * 0.62), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString($text, $f, (New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(242, 194, 48))), (New-Object Drawing.RectangleF(0, 0, $size, $size)), $sf)
  }
  $b.Save($file, [Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $b.Dispose()
}
Icon "$build\img\plugin.png" 28 '4'; Icon "$build\img\plugin@2x.png" 56 '4'
Icon "$build\img\tile.png" 72 $null; Icon "$build\img\tile@2x.png" 144 $null

$manifest = [ordered]@{
  UUID = $uuid; SDKVersion = 2; Name = 'Paddock'; Author = 'Peter'; Version = $ver
  Description = 'Startup intro and the live deck screens: friends, overlays, race setup, replay, analysis, sound.'; CodePath = 'plugin.html'
  Icon = 'img/plugin'; Category = 'Rig'; CategoryIcon = 'img/plugin'
  OS = @(@{ Platform = 'windows'; MinimumVersion = '10' }); Software = @{ MinimumVersion = '6.5' }
  Profiles = @(@{ Name = 'RigIntro'; DeviceType = 2; AutoInstall = $true; DontAutoSwitchWhenInstalled = $true },
               @{ Name = 'RigFriends'; DeviceType = 2; AutoInstall = $true; DontAutoSwitchWhenInstalled = $true },
               @{ Name = 'RigOverlays'; DeviceType = 2; AutoInstall = $true; DontAutoSwitchWhenInstalled = $true },
               @{ Name = 'RigMyDrive'; DeviceType = 2; AutoInstall = $true; DontAutoSwitchWhenInstalled = $true },
               @{ Name = 'RigReplay'; DeviceType = 2; AutoInstall = $true; DontAutoSwitchWhenInstalled = $true },
               @{ Name = 'RigAnalysis'; DeviceType = 2; AutoInstall = $true; DontAutoSwitchWhenInstalled = $true },
               @{ Name = 'RigSound'; DeviceType = 2; AutoInstall = $true; DontAutoSwitchWhenInstalled = $true })
  Actions = @(@{ UUID = "$uuid.tile"; Name = 'Tile'; Icon = 'img/tile'; Tooltip = 'Part of the intro, friends, overlays, race setup, replay, analysis or sound screen'
                 States = @(@{ Image = 'img/tile'; ShowTitle = $false }); VisibleInActionsList = $false; SupportedInMultiActions = $false; Controllers = @('Keypad') },
              @{ UUID = "$uuid.friends"; Name = 'Friends mode'; Icon = 'img/plugin'; Tooltip = 'Opens the friends mode screen'
                 States = @(@{ Image = 'img/tile'; ShowTitle = $false }); VisibleInActionsList = $true; SupportedInMultiActions = $false; Controllers = @('Keypad') },
              @{ UUID = "$uuid.doctor"; Name = 'Rig Doctor'; Icon = 'img/plugin'; Tooltip = 'Checks the whole rig and shows what to fix on the top screen'
                 States = @(@{ Image = 'img/tile'; ShowTitle = $false }); VisibleInActionsList = $true; SupportedInMultiActions = $false; Controllers = @('Keypad') },
              @{ UUID = "$uuid.overlays"; Name = 'Overlays'; Icon = 'img/plugin'; Tooltip = 'Opens the overlays screen: which overlays are on, presets, delta bar, Rig Doctor'
                 States = @(@{ Image = 'img/tile'; ShowTitle = $false }); VisibleInActionsList = $true; SupportedInMultiActions = $false; Controllers = @('Keypad') },
              @{ UUID = "$uuid.mydrive"; Name = 'My Drive'; Icon = 'img/plugin'; Tooltip = 'Opens the My Drive (race setup) screen: last drive, usual, surprise, favourites, same car or track, search, START'
                 States = @(@{ Image = 'img/tile'; ShowTitle = $false }); VisibleInActionsList = $true; SupportedInMultiActions = $false; Controllers = @('Keypad') },
              @{ UUID = "$uuid.replay"; Name = 'Replay'; Icon = 'img/plugin'; Tooltip = 'Opens the Replay screen: timeline, play / pause, laps, incidents, cars, cameras, photo'
                 States = @(@{ Image = 'img/tile'; ShowTitle = $false }); VisibleInActionsList = $true; SupportedInMultiActions = $false; Controllers = @('Keypad') },
              @{ UUID = "$uuid.analysis"; Name = 'Analysis'; Icon = 'img/plugin'; Tooltip = 'Opens the Analysis screen: drive the lap analysis on the top screen from the deck'
                 States = @(@{ Image = 'img/tile'; ShowTitle = $false }); VisibleInActionsList = $true; SupportedInMultiActions = $false; Controllers = @('Keypad') },
              @{ UUID = "$uuid.sound"; Name = 'Sound'; Icon = 'img/plugin'; Tooltip = 'Opens the Sound screen: game, spotter, music, speakers and ButtKicker levels, mute, presets'
                 States = @(@{ Image = 'img/tile'; ShowTitle = $false }); VisibleInActionsList = $true; SupportedInMultiActions = $false; Controllers = @('Keypad') })
}
($manifest | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath "$build\manifest.json" -Encoding UTF8

# bundled profiles: one page each, 8 x 4 tiles. The tiles say which profile they belong to (settings.p).
$enc = New-Object Text.UTF8Encoding($false)
function Build-Profile($name, $p) {
  $stage = Join-Path $here "build\profile-$name"
  if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
  $prof = ([guid]::NewGuid().ToString()).ToUpper(); $def = [guid]::NewGuid().ToString(); $page = [guid]::NewGuid().ToString()
  $pdir = Join-Path $stage "Profiles\$prof.sdProfile"
  New-Item -ItemType Directory -Force "$pdir\Images", "$pdir\Profiles\$($def.ToUpper())\Images", "$pdir\Profiles\$($page.ToUpper())\Images" | Out-Null
  [IO.File]::WriteAllText("$pdir\manifest.json", (@{ Device = @{ Model = '20GAT9902'; UUID = ([guid]::NewGuid().ToString()) }; Name = $name; Version = '3.0'
    Pages = [ordered]@{ Current = $page; Default = $def; Pages = @($page) } } | ConvertTo-Json -Depth 6 -Compress), $enc)
  [IO.File]::WriteAllText("$pdir\Profiles\$($def.ToUpper())\manifest.json", '{"Controllers":[{"Actions":{},"Type":"Keypad"}],"Icon":"","Name":""}', $enc)
  $acts = [ordered]@{}
  for ($r = 0; $r -lt 4; $r++) { for ($c = 0; $c -lt 8; $c++) {
    $acts["$c,$r"] = [ordered]@{ ActionID = [guid]::NewGuid().ToString(); LinkedTitle = $true; Name = 'Tile'
      Plugin = @{ Name = 'Paddock'; UUID = $uuid; Version = $ver }; Resources = $null; Settings = @{ p = $p }; State = 0
      States = @(@{ FontFamily = ''; FontSize = 12; FontStyle = ''; FontUnderline = $false; OutlineThickness = 2; ShowTitle = $false; TitleAlignment = 'bottom'; TitleColor = '#ffffff' })
      UUID = "$uuid.tile" } } }
  [IO.File]::WriteAllText("$pdir\Profiles\$($page.ToUpper())\manifest.json", (@{ Controllers = @(@{ Actions = $acts; Type = 'Keypad' }); Icon = ''; Name = '' } | ConvertTo-Json -Depth 10 -Compress), $enc)
  [IO.File]::WriteAllText("$stage\package.json", '{"AppVersion":"7.6.0.23012","DeviceModel":"20GAT9902","DeviceSettings":null,"FormatVersion":1,"OSType":"Windows","OSVersion":"10.0.26200","RequiredPlugins":["com.peter.rigintro"]}', $enc)
  [IO.Compression.ZipFile]::CreateFromDirectory($stage, "$build\$name.streamDeckProfile")
  Remove-Item -LiteralPath $stage -Recurse -Force
}
Build-Profile 'RigIntro' 'intro'
Build-Profile 'RigFriends' 'friends'
Build-Profile 'RigOverlays' 'overlays'
Build-Profile 'RigMyDrive' 'mydrive'
Build-Profile 'RigReplay' 'replay'
Build-Profile 'RigAnalysis' 'analysis'
Build-Profile 'RigSound' 'sound'

# Package it the way Elgato distributes add-ons. Opening the package makes Stream Deck install it properly,
# including the bundled RigIntro profile (a hand-copied plugin folder never gets its profile).
# Stream Deck asks once: click Install.
$pkg = Join-Path $here "build\$uuid.streamDeckPlugin"
if (Test-Path $pkg) { Remove-Item -LiteralPath $pkg -Force }
[IO.Compression.ZipFile]::CreateFromDirectory($build, $pkg, [IO.Compression.CompressionLevel]::Optimal, $true)
# Stream Deck installs (or updates, when $ver is higher) after one Install click.
# Opened through Explorer so the Stream Deck app (not a program started from the Claude app) does the install.
Start-Process explorer.exe -ArgumentList "`"$pkg`""
"opened $pkg - Stream Deck asks to install it: click Install"
