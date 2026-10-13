# Friends mode end-to-end test (out of the car; no iRacing session needed).
# Drives the same commands the Stream Deck sends (through irdash, like the add-on does), checks what irdash
# reports back after each step, checks CrewChief's spoken name is switched and put back, and saves a picture
# of the top screen at each stage to tests\shots. Leaves friends mode off and your own settings as they were.
#   powershell -ExecutionPolicy Bypass -File tests\friends-test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$api = 'http://localhost:8199'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Guest { (Invoke-WebRequest -UseBasicParsing "$api/guest" -TimeoutSec 5).Content | ConvertFrom-Json }
function Press($c, $a) { $u = "$api/api/guest/do?c=$c" + $(if ($a) { "&a=$a" } else { '' }); $null = Invoke-WebRequest -UseBasicParsing $u -TimeoutSec 5; Start-Sleep -Milliseconds 1500 }
function CCName { $f = Get-ChildItem "$env:LOCALAPPDATA\Britton_IT_Ltd" -Recurse -Filter user.config | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $m = [regex]::Match((Get-Content $f.FullName -Raw), 'name="PERSONALISATION_NAME"[^>]*>\s*<value>([^<]*)</value>'); $m.Groups[1].Value }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
function Shot($name) {
  Start-Sleep -Milliseconds 1800   # the page polls once a second
  $top = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.Y } | Select-Object -First 1; $b = $top.Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height; $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $s = New-Object System.Drawing.Bitmap $bmp, 960, 540; $s.Save((Join-Path $shots "$name.png")); $g.Dispose(); $bmp.Dispose(); $s.Dispose()
}

. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
function Section($title) { Assert-RigFree -Where $title; $title }
$ownName = CCName
"Friends mode test  (CrewChief currently says: $ownName)"
# start from a board without laps from earlier test runs (they use GT4 at Okayama)
$bf = Join-Path $root 'guest\board.tsv'
function Tidy { if (Test-Path $bf) { $keep = @(Get-Content $bf | Where-Object { $_ -notmatch "^(Sam|Guest)\tgt4\tokayama\t" }); [IO.File]::WriteAllLines($bf, [string[]]$keep) } }
Tidy

Section '1. switch on'
Press 'on'; $g = Guest
Check 'friends mode is on' ($g.active -eq $true)
Check 'a car and a track are chosen' ($g.car.key -and $g.track.key)
Check 'wheel starts on light' ($g.wheel -eq 'light')
Shot '1-setup'

Section '2. type a new name on the deck keyboard'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/guest/draft?n=SA" -TimeoutSec 5
$null = Invoke-WebRequest -UseBasicParsing "$api/api/guest/draft?n=SAM" -TimeoutSec 5
$g = Guest; Check 'top screen sees the typed name' ($g.draft -eq 'SAM'); Check 'spotter knows "Sam"' ($g.voiceDraft -eq $true)
Shot '2-typing'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/guest/draft" -TimeoutSec 5
Press 'adddriver' 'SAM'; Start-Sleep 4
$g = Guest
Check 'Sam is saved and driving' ($g.driver -eq 'Sam' -and ($g.drivers -contains 'Sam'))
Check 'CrewChief now says Sam' ((CCName) -eq 'Sam')
Check 'CrewChief restarted' ([bool](Get-Process CrewChiefV4 -ErrorAction SilentlyContinue))

Section '3. pick a car, a track and the wheel'
Press 'car' 'gt4'; Press 'track' 'okayama'; Press 'wheel' 'medium'
$g = Guest
Check 'car GT4' ($g.car.key -eq 'gt4'); Check 'track Okayama' ($g.track.key -eq 'okayama'); Check 'wheel medium' ($g.wheel -eq 'medium')
Shot '3-chosen'

Section '4. a lap goes on the leaderboard'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/guest/lap?t=101.234" -TimeoutSec 5
$g = Guest; Check 'Sam 1:41.234 on the board' (@($g.times | Where-Object { $_.name -eq 'Sam' -and [math]::Abs($_.time - 101.234) -lt 0.01 }).Count -ge 1)
Check 'first lap there is a new record' ($g.event.kind -eq 'record' -and $g.event.name -eq 'Sam')
Shot '4-record'
$null = Invoke-WebRequest -UseBasicParsing "$api/api/guest/lap?t=101.900" -TimeoutSec 5
$g = Guest; Check 'a slower lap is no celebration' ($g.event.time -eq 101.234)
Start-Sleep 7
Shot '4-board'

Section '5. guest driver'
Press 'driver' 'guest'; Start-Sleep 4
$g = Guest; Check 'Guest is driving' ($g.driver -eq 'Guest'); Check 'CrewChief says no name for Guest' ((CCName) -eq '')

Section '6. exit puts everything back'
Press 'off'; Start-Sleep 4
$g = Guest
Check 'friends mode is off' ($g.active -eq $false)
Check "CrewChief says $ownName again" ((CCName) -eq $ownName)
Check "tonight's podium shows Sam first" ($g.event.kind -eq 'podium' -and $g.event.top[0].name -eq 'Sam')
Shot '6-podium'

# tidy up: test laps and test driver
Tidy
Press 'deldriver' 'SAM'
''
"$pass passed, $fail failed. Pictures in $shots"
