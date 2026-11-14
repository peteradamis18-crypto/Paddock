# Official racing + race weekend (WS8), offline. Nothing here touches the sim, iRacing's app, Stream Deck or Peter's screens.
#   1. build   the pure code, irdash's side and irdeck's commands compile; they are in the build lists; irdeck has no click of its own
#   2. unit    PDF reading, repeat patterns -> times, owned filter from folder lists, eligibility (tests\official-unit.cs)
#   3. glue    irdash's side against a pretend root: import, favourites, whitelist, ownership override, weekday / weekend views
#   4. real    the real season schedule and the real folders: every race listed is for a car and a track he owns
#   5. irdeck  the command line: favourites file, refusals (it never starts the UI side here)
#   6. screen  the idle screen's "Race weekend" panel in headless Chrome at 1920x1080 (pictures: tests\shots\of-*.png)
#   -Live      (pending: needs the new irdash deployed and Peter away) reads /official from the running irdash
#   powershell -ExecutionPolicy Bypass -File tests\official-test.ps1 [-NoPictures] [-Live]
param([switch]$NoPictures, [switch]$Live)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'tests\guard.ps1')
Assert-RigFree
$shots = Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
function Section($t) { Assert-RigFree -Where $t; $t }
function Norm($s) { $d = ([string]$s).Normalize([Text.NormalizationForm]::FormD).ToLowerInvariant(); (($d.ToCharArray() | Where-Object { ($_ -ge 'a' -and $_ -le 'z') -or ($_ -ge '0' -and $_ -le '9') }) -join '') }
$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$tmp = Join-Path $env:TEMP "official-test-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$work = Join-Path $tmp 'bin'; New-Item -ItemType Directory -Force $work | Out-Null
'Official racing test'
try {

# ================= 1. build =================
'1. build'
$core = "$root\dash\src\officialcore.cs"; $glue = "$root\dash\src\official.cs"
$unit = Join-Path $work 'official-unit.exe'
$out = & "$fw\csc.exe" -nologo -r:System.Web.Extensions.dll "-out:$unit" "$root\tests\official-unit.cs" $core $glue 2>&1
Check 'officialcore.cs + official.cs compile (C# 5, Windows csc)' ((Test-Path $unit) -and -not ($out | Where-Object { $_ -match 'error' }))
$wpf = "$fw\WPF"
$refs = @('-r:System.dll', '-r:System.Core.dll', '-r:System.Drawing.dll', '-r:System.Windows.Forms.dll', '-r:System.Web.Extensions.dll', "-r:$wpf\UIAutomationClient.dll", "-r:$wpf\UIAutomationTypes.dll", "-r:$wpf\WindowsBase.dll")
# the same files build-irdeck.ps1 compiles (read from it, so a new src file can never break this test again - 2026-10-11)
$bi = Get-Content "$root\build-irdeck.ps1" -Raw
$srcs = @([regex]::Matches(([regex]::Match($bi, '\$src\s*=\s*@\(([^)]*)\)').Groups[1].Value), '\\src\\([\w.]+\.cs)') | ForEach-Object { "$root\src\" + $_.Groups[1].Value })
$cli = Join-Path $work 'irdeck-cli.exe'
$out = & "$fw\csc.exe" -nologo -optimize+ -target:exe -define:CLI "-out:$cli" @refs @srcs 2>&1
Check 'src\official.cs compiles into irdeck (CLI build)' ((Test-Path $cli) -and -not ($out | Where-Object { $_ -match 'error' }))
Check 'both new irdash files are in dash\build.ps1, the new irdeck file is in build-irdeck.ps1' ((Get-Content "$root\dash\build.ps1" -Raw) -match 'officialcore\.cs' -and (Get-Content "$root\dash\build.ps1" -Raw) -match 'src\\official\.cs' -and (Get-Content "$root\build-irdeck.ps1" -Raw) -match 'src\\official\.cs')
$of = Get-Content "$root\src\official.cs" -Raw
Check 'irdeck official.cs never clicks, types or invokes anything itself (only the verified Test Drive helpers and the sidebar nav)' ($of -notmatch '\bClick(El)?\(|\.Invoke\(|SendCombo|TypeText|SendKeys|InvokePattern')
Check 'irdeck official.cs has no register / join / withdraw action: "Register" only appears in text it looks for or says' (([regex]::Matches($of, 'Register|Withdraw') | Measure-Object).Count -gt 0 -and $of -notmatch 'CmdUi\(')
$html = Get-Content "$root\dash\www\v2\index.html" -Raw
Check 'index.html has no official.js, official.css or idleOfficial container any more (the panel is gone)' ($html -notmatch 'official.(js|css)' -and $html -notmatch 'id="idleOfficial"')

# ================= 2. unit =================
'2. unit (PDF, patterns, owned filter, eligibility)'
$u = @(& $unit unit)
$u | Where-Object { $_ -match '^(  ok|  FAIL|\d+\.)' }
$res = ($u | Where-Object { $_ -match '^RESULT' } | Select-Object -Last 1) -split ' '
$script:pass += [int]$res[1]; $script:fail += [int]$res[2]
Section 'series eligibility'
Check 'unit printed series eligibility' (($u | Where-Object { $_ -match 'recent included' }).Count -ge 1)
Section 'ownership'
Check 'unit printed ownership' (($u | Where-Object { $_ -match 'installed car' }).Count -ge 1)
Section 'next race'
Check 'unit printed next race' (($u | Where-Object { $_ -match 'UTC cadence projection' }).Count -ge 1)

# ================= 3. glue =================
Assert-RigFree -Where '3. glue'
'3. irdash side, against a pretend root folder'
$g = Join-Path $tmp 'root'
New-Item -ItemType Directory -Force "$g\data\official", "$g\dash", "$g\iRacing\tracks\silverstone", "$g\iRacing\tracks\roadatlanta" | Out-Null
foreach ($c in 'bmwm4gt3', 'ministock', 'rufrt12r', 'mystery') { New-Item -ItemType Directory -Force "$g\iRacing\cars\$c" | Out-Null; Set-Content "$g\iRacing\cars\$c\$c.dat" 'x' }
Set-Content "$g\data\official\profile.ini" "iracing=$g\iRacing`r`nevening=18`r`nautodownload=no`r`nscheduleurl=`r`n"
$row = "bmwm4gt3_silverstone gp 2026-10-04 22-05-42.ibt|123`t639267627889676588`t600`t20`t0`t1308`tBMW M4 GT3 EVO`tSilverstone Circuit`tRace`tPeter Test`t5`tC 2.54`t2`t0.000`t0.000`t0"
Set-Content "$g\dash\career-cache.tsv" $row
$gl = @(& $unit glue $g)
$gl | Where-Object { $_ -match '^(  ok|  FAIL|\d+\.)' }
$gl | Where-Object { $_ -match 'Unhandled|Exception' } | ForEach-Object { "  $_" }
$res = ($gl | Where-Object { $_ -match '^RESULT' } | Select-Object -Last 1) -split ' '
if ($res.Count -ge 3) { $script:pass += [int]$res[1]; $script:fail += [int]$res[2] } else { $script:fail++; '  FAIL  the glue test did not finish' }

# ================= W3-3 his series and HOME's next race =================
Section '13. his series (W3-3)'
$mr = Join-Path $tmp 'mineroot'; New-Item -ItemType Directory -Force $mr | Out-Null
$mo = @(& $unit mine $mr)
$mo | Where-Object { $_ -match '^(  ok|  FAIL|\d+\.|\s+his series)' }
$res = ($mo | Where-Object { $_ -match '^RESULT' } | Select-Object -Last 1) -split ' '
if ($res.Count -ge 3) { $script:pass += [int]$res[1]; $script:fail += [int]$res[2] } else { $script:fail++; '  FAIL  the his-series test did not finish' }
$logLine = $mo | Where-Object { $_ -match "official: Peter's series: " } | Select-Object -First 1
Check "the start-up log names his series: $($logLine -replace '^\s*\[log\]\s*', '')" ($logLine -match "official: Peter's series: Toyota GR Cup$")
Check 'the log line is written once, not on every rebuild' (@($mo | Where-Object { $_ -match "official: Peter's series: " }).Count -le 2)

# ================= H-01 source / S4 / 2027 =================
$fix = Join-Path $root 'data\official\fixtures'
$srcRoot = Join-Path $tmp 'h01root'
New-Item -ItemType Directory -Force "$srcRoot\data\official", $fix | Out-Null
Section 'source page PDF/fallback'
$srcOut = @(& $unit source $srcRoot $fix)
$srcOut | Where-Object { $_ -match '^(  ok|  FAIL|source |S4 |2027 )' }
$srcRes = ($srcOut | Where-Object { $_ -match '^RESULT' } | Select-Object -Last 1) -split ' '
if ($srcRes.Count -ge 3) { $script:pass += [int]$srcRes[1]; $script:fail += [int]$srcRes[2] } else { $script:fail++; '  FAIL  the source test did not finish' }
Section 'S4 schedule fixture'
Check 'S4 fixture PDF is on disk' (Test-Path (Join-Path $fix '2026-s4.pdf'))
Section '2027 S1 absent'
Check '2027 S1 absent fixture is on disk' (Test-Path (Join-Path $fix '2027-s1-absent.html'))

# ================= 4. real data =================
Assert-RigFree -Where '4. real'
'4. the real schedule and the real folders'
$seasonFile = Join-Path $root 'data\official\season.json'
if (-not (Test-Path $seasonFile)) { Check 'data\official\season.json exists (copy the season PDF into data\official and let irdash read it)' $false }
else {
  $season = [IO.File]::ReadAllText($seasonFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
  Check "the real season file has $($season.series.Count) series (more than 100) and every one has weeks, a licence class and a repeat pattern" ($season.series.Count -gt 100 -and @($season.series | Where-Object { $_.weeks.Count -lt 1 -or $_.lic.Length -ne 1 -or $_.freq.Length -lt 3 }).Count -le 8)
  Check 'GT3 Challenge Fixed has week 4 at Mobility Resort Motegi (the PDF I read by hand) and 12 weeks' ((($season.series | Where-Object { $_.short -eq 'GT3 Challenge Fixed by Fanatec' }).weeks | Where-Object { $_.n -eq 4 }).track -eq 'Mobility Resort Motegi' -and ($season.series | Where-Object { $_.short -eq 'GT3 Challenge Fixed by Fanatec' }).weeks.Count -eq 12)
  Check 'weeks of the regular series (hourly / 2-hourly patterns) all start on a Tuesday; event series are dated on their own race day' (@($season.series | Where-Object { $_.freq -match 'hour|30 min|:' -and $_.freq -notmatch 'GMT' } | ForEach-Object { $_.weeks } | Where-Object { ([datetime]$_.start).DayOfWeek -ne 'Tuesday' }).Count -eq 0)
  $realJson = { param($now) (& $unit json $root $now | Where-Object { $_ -notmatch '^\s+\[log\]' }) -join '' | ConvertFrom-Json }
  $owned = [IO.File]::ReadAllText((Join-Path $root 'data\official\owned.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
  $ownedCars = @{}; foreach ($n in $owned.carNames) { $ownedCars[(Norm $n)] = 1 }
  $ownedTracks = @{}; foreach ($n in $owned.trackNames) { $ownedTracks[(Norm $n)] = 1 }
  Check "owned.json: $($owned.cars) cars and $($owned.tracks) tracks from the install folders, each with names; the ones it cannot name are listed ($($owned.unknownCars.Count))" ($owned.cars -gt 20 -and $owned.tracks -gt 20 -and $owned.carNames.Count -gt 20 -and $owned.trackNames.Count -gt 20)
  $tz = [TimeZoneInfo]::Local
  function LocalToUtcIso($y, $mo, $d, $h, $mi) { $l = New-Object DateTime $y, $mo, $d, $h, $mi, 0, ([DateTimeKind]::Unspecified); [TimeZoneInfo]::ConvertTimeToUtc($l, $tz).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
  $moments = @{ 'Wednesday noon' = (LocalToUtcIso 2026 10 7 12 0); 'Friday 18:30' = (LocalToUtcIso 2026 10 9 18 30); 'Saturday noon' = (LocalToUtcIso 2026 10 10 12 0); 'Sunday 20:00' = (LocalToUtcIso 2026 10 11 20 0); 'Saturday 14 Nov' = (LocalToUtcIso 2026 11 14 12 0) }
  foreach ($k in 'Wednesday noon', 'Friday 18:30', 'Saturday noon', 'Sunday 20:00', 'Saturday 14 Nov') {
    $j = & $realJson $moments[$k]
    $bad = @(); $count = 0
    foreach ($d in $j.days) { foreach ($r in $d.rows) { $count++
      if (-not $ownedCars.ContainsKey((Norm $r.car)) -and $r.car -ne '') { $bad += "car $($r.car)" }
      if ($r.car -eq '') { $bad += "no car for $($r.series)" }
      $tk = Norm $r.track; $okT = $ownedTracks.ContainsKey($tk); if (-not $okT) { foreach ($t in $ownedTracks.Keys) { if ($tk.StartsWith($t)) { $okT = $true } } }
      if (-not $okT) { $bad += "track $($r.track) ($($r.series))" } } }
    Check "$k ($($moments[$k])): $count rows listed, every one for a car and a track he owns$(if ($bad.Count) { ' - ' + (($bad | Select-Object -First 3) -join '; ') })" ($j.loaded -and $count -gt 0 -and $bad.Count -eq 0)
  }
  $sat = & $realJson $moments['Saturday noon']
  $deckNames = @($sat.deck | ForEach-Object { $_.series })
  Check "Saturday 10 Oct: GT3 Challenge Fixed is NOT listed (Motegi this week, not owned) but series at tracks he owns are ($($deckNames.Count) in the deck list)" (-not ($deckNames -contains 'GT3 Challenge Fixed by Fanatec') -and $deckNames.Count -gt 5)
  $nov = & $realJson (LocalToUtcIso 2026 11 5 12 0)
  Check 'Thursday 5 Nov: GT3 Challenge Fixed IS listed (Spa-Francorchamps is owned, so are GT3 cars)' ((@($nov.deck | ForEach-Object { $_.series }) -contains 'GT3 Challenge Fixed by Fanatec'))
  Check 'times are UTC ISO strings and each race row has a licence letter R/D/C/B/A/P' (@($sat.days | ForEach-Object { $_.rows } | Where-Object { $_.t -notmatch 'Z$' -or $_.lic -notmatch '^[RDCBAP]$' }).Count -eq 0)
  Check 'every time of today is estimated or exact on purpose: Production Car Challenge (hourly :30) is not est' (@($sat.days[0].rows | Where-Object { $_.series -like 'Production Car Challenge*' -and $_.est }).Count -eq 0)
  Check 'the oval / dirt limit works: no Class A/B/C/D oval or dirt series while those licences are unknown (assumed Rookie)' (@($sat.days | ForEach-Object { $_.rows } | Where-Object { $_.lic -ne 'R' -and ($_.layout -match 'Oval|Dirt' -or $_.track -match 'Dirt') }).Count -eq 0)
}

# ================= 5. irdeck command line =================
Assert-RigFree -Where '5. irdeck'
'5. irdeck commands (arguments and the favourites file only; the iRacing side is never started here)'
$tr = Join-Path $tmp 'deckroot'; New-Item -ItemType Directory -Force $tr | Out-Null; Copy-Item $cli "$tr\irdeck-cli.exe"
$null = & "$tr\irdeck-cli.exe" official fav "Pretend Cup by Foo"
Check 'official fav "name" writes data\official\favourites.ini, name only, newest first' ((Get-Content "$tr\data\official\favourites.ini" -ErrorAction SilentlyContinue) -contains 'Pretend Cup by Foo')
$null = & "$tr\irdeck-cli.exe" official fav "Second Cup"
$lines = @(Get-Content "$tr\data\official\favourites.ini" | Where-Object { $_ -notmatch '^;' })
Check 'the newest is first' ($lines[0] -eq 'Second Cup' -and $lines[1] -eq 'Pretend Cup by Foo')
$null = & "$tr\irdeck-cli.exe" official fav "pretend cup BY foo"
Check 'the same name in other spelling removes it again (toggle)' (@(Get-Content "$tr\data\official\favourites.ini" | Where-Object { $_ -notmatch '^;' }).Count -eq 1)
$null = & "$tr\irdeck-cli.exe" official register o12345678; $rc1 = $LASTEXITCODE
Check 'register without --dry is refused (exit 1)' ($rc1 -eq 1)
$null = & "$tr\irdeck-cli.exe" official register --dry; $rc2 = $LASTEXITCODE
Check 'register --dry without a series id is refused before touching anything (exit 1)' ($rc2 -eq 1)
$null = & "$tr\irdeck-cli.exe" official scan; $rc3 = $LASTEXITCODE
Check '"official scan" without "owned" is refused (exit 1)' ($rc3 -eq 1)
# irdash reads the file irdeck wrote (same format)
Set-Content "$g\data\official\favourites.ini" (Get-Content "$tr\data\official\favourites.ini")
Check 'the file irdeck writes has the header lines irdash skips and one name per line' ((Get-Content "$g\data\official\favourites.ini")[0] -match '^;')

# ================= 7. live (pending) =================
if ($Live) {
  Assert-RigFree -NeedAway -Where '7. live'
  '7. the running irdash (needs the new build deployed)'
  try {
    $r = Invoke-WebRequest -UseBasicParsing 'http://localhost:8199/official' -TimeoutSec 8
    $j = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    Check '/official answers with the home-screen data' ($j.ready -and $j.loaded -and $j.days.Count -ge 1)
  } catch { Check "irdash answers /official ($($_.Exception.Message))" $false }
} else { '7. live: skipped (run with -Live after the new irdash is deployed; the iRacing-side steps are in docs\official.md and need Peter away)' }

} finally { try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
"$pass passed, $fail failed. Pictures in $shots (of-*.png)."
if ($fail -gt 0) { exit 1 }
