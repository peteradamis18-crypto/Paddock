# pickname-test.ps1 - LAST DRIVE / AI RACE find his car in iRacing's own list (offline: reads files, touches nothing).
# 2026-10-18: the telemetry calls his car "Porsche 718 Cayman GT4", iRacing's list "Porsche 718 Cayman GT4 Clubsport MR",
# and the exact-name match stopped LAST DRIVE with "not in the list". This compiles the real BestRow from src\testdrive.cs
# and runs it, for every car he has telemetry for, against iRacing's names (dash\src\officialcore.cs) as its search shows them.
#   powershell -ExecutionPolicy Bypass -File tests\pickname-test.ps1
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }

$src = [IO.File]::ReadAllText((Join-Path $root 'src\testdrive.cs'))
$same = [regex]::Match($src, 'static bool Same\(string a, string b\) \{[^\r\n]*\}').Value
$best = [regex]::Match($src, '(?s)internal static T BestRow<T>.*?\r?\n        \}').Value
$lastw = [regex]::Match($src, 'internal static string LastWord\(string want\) \{[^\r\n]*\}').Value
$smae = [regex]::Match($src, '(?s)internal static T SameMakeAndEnd<T>.*?\r?\n        \}').Value
Check 'Same, BestRow, LastWord and SameMakeAndEnd found in src\testdrive.cs' ($same.Length -gt 0 -and $best.Length -gt 0 -and $lastw.Length -gt 0 -and $smae.Length -gt 0)
Add-Type -Language CSharp -TypeDefinition ("using System; using System.Collections.Generic; public static class PickName { public " + $same + "`n public " + ($best -replace 'internal static', 'static') + "`n public " + ($lastw -replace 'internal static', 'static') + "`n public " + ($smae -replace 'internal static', 'static') + "`n public static string Pick(List<string> rows, string want) { return BestRow(rows, s => s, want); } public static string Pick2(List<string> rows, string want) { return SameMakeAndEnd(rows, s => s, want); } }")

'1. the cases that matter'
function P([string[]]$rows, [string]$want) { [PickName]::Pick([Collections.Generic.List[string]]$rows, $want) }
Check 'the Porsche: the telemetry name finds iRacing''s longer name' ((P @('Porsche 718 Cayman GT4 Clubsport MR') 'Porsche 718 Cayman GT4') -eq 'Porsche 718 Cayman GT4 Clubsport MR')
Check 'an exact name wins over a longer one (Porsche 911 GT3 R, not the 992)' ((P @('Porsche 911 GT3 R (992)', 'Porsche 911 GT3 R') 'Porsche 911 GT3 R') -eq 'Porsche 911 GT3 R')
Check 'two longer names and no exact one: stop, never guess' ($null -eq (P @('Formula Vee - Classic', 'Formula Vee - Sabre') 'Formula Vee'))
Check 'a name that only starts the same word does not count (GT4 is not GT40)' ($null -eq (P @('Ford GT40') 'Ford GT4'))
Check 'second try: Porsche 991 RSR finds the one Porsche ending in RSR' ([PickName]::Pick2([Collections.Generic.List[string]]@('Porsche 911 RSR', 'BMW M8 GTE'), 'Porsche 991 RSR') -eq 'Porsche 911 RSR')
Check 'second try: two Porsches ending in RSR = stop' ($null -eq [PickName]::Pick2([Collections.Generic.List[string]]@('Porsche 911 RSR', 'Porsche 935 RSR'), 'Porsche 991 RSR'))
Check 'nothing on the list: nothing picked' ($null -eq (P @() 'Porsche 718 Cayman GT4'))

'2. every car he has telemetry for, against iRacing''s own names'
$names = @{}
foreach ($m in [regex]::Matches([IO.File]::ReadAllText((Join-Path $root 'dash\src\officialcore.cs')), '"([a-z0-9\\]+)\|([^"]+)"')) { $names[$m.Groups[1].Value] = @($m.Groups[2].Value -split '\|') }
$all = @($names.Values | ForEach-Object { $_ }) | Sort-Object -Unique
$tel = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'iRacing\telemetry'
$seen = @{}
foreach ($f in (Get-ChildItem $tel -Filter '*.ibt' | Sort-Object LastWriteTime -Descending)) {
  $path = ($f.Name -split '_')[0]; if ($seen.ContainsKey($path)) { continue }
  $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite'); $b = New-Object byte[] 300000; $n = $fs.Read($b, 0, $b.Length); $fs.Close()
  $y = [Text.Encoding]::UTF8.GetString($b, 0, $n)
  $me = [regex]::Match($y, 'DriverCarIdx: (\d+)').Groups[1].Value
  $blk = [regex]::Match($y, '(?s)- CarIdx: ' + $me + '\r?\n.*?CarPath: (\S+).*?CarScreenName: ([^\r\n]+)')
  if (-not $blk.Success) { continue }
  $seen[$path] = @($blk.Groups[1].Value, $blk.Groups[2].Value.Trim())
}
Check "cars found in his telemetry: $($seen.Count)" ($seen.Count -ge 3)
foreach ($k in $seen.Keys) {
  $cp = $seen[$k][0]; $tn = $seen[$k][1]
  if (-not $names.ContainsKey($cp)) { "  info  $cp ($tn) is not in officialcore's name table - skipped"; continue }
  # iRacing's search box filters by the typed text: the rows are every iRacing car name that contains it
  $rows = @($all | Where-Object { $_.IndexOf($tn, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
  $got = P $rows $tn; $how = 'its name'
  # nothing found: the second try LAST DRIVE makes (search the last word, same make and same last word)
  if (-not $got) { $lw = [PickName]::LastWord($tn); $rows = @($all | Where-Object { $lw -and $_.IndexOf($lw, [StringComparison]::OrdinalIgnoreCase) -ge 0 }); $got = [PickName]::Pick2([Collections.Generic.List[string]]$rows, $tn); $how = "second try, searched '$lw'" }
  Check "$tn -> '$got' by $how (iRacing: $($names[$cp] -join ' / '))" ($got -and $names[$cp] -contains $got) ("rows on screen: " + ($rows -join '; '))
}
'3. every track and layout in his history, against iRacing''s own track names'
# the real TrackKey / BestTrackRow / TrackKeyName from src\testdrive.cs
$tk = [regex]::Match($src, '(?s)internal static string TrackKey\(string n\).*?\r?\n        \}').Value
$btr = [regex]::Match($src, '(?s)internal static T BestTrackRow<T>.*?\r?\n        \}').Value
$tkn = [regex]::Match($src, '(?s)internal static string TrackKeyName\(string picked, string fallback\).*?\r?\n        \}').Value
Check 'TrackKey, BestTrackRow and TrackKeyName found in src\testdrive.cs' ($tk.Length -gt 0 -and $btr.Length -gt 0 -and $tkn.Length -gt 0)
Add-Type -Language CSharp -TypeDefinition ("using System; using System.Collections.Generic; public static class PickTrack { public " + ($tk -replace 'internal static', 'static') + "`n public " + ($btr -replace 'internal static', 'static') + "`n public " + ($tkn -replace 'internal static', 'static') + "`n public static string Pick(List<string> rows, string want) { return BestTrackRow(rows, s => s, want); } }")
function T($rows, [string]$want) { $l = New-Object 'Collections.Generic.List[string]'; foreach ($r in @($rows)) { if ($r) { $l.Add([string]$r) } }; [PickTrack]::Pick($l, $want) }
Check 'track: exact name wins' ((T @('Road America button', 'Road America - Full button') 'Road America') -eq 'Road America button')
Check 'track: iRacing adds the layout to the name (Road America - Full Course): the one row is taken' ((T @('Road America - Full Course button') 'Road America') -eq 'Road America - Full Course button')
Check 'track: two longer names and no exact one = stop' ($null -eq (T @('Lime Rock Park - Grand Prix button', 'Lime Rock Park - Classic button') 'Lime Rock Park'))
Check 'track: Nordschleife is iRacing''s "Nurburgring Nordschleife" (ends with the name, accents ignored)' ((T @('N' + [char]0xFC + 'rburgring Nordschleife button') 'Nordschleife') -like '*Nordschleife button')
Check 'track: the accent in either place does not matter' ((T @('Nurburgring Combined button') ('N' + [char]0xFC + 'rburgring Combined')) -eq 'Nurburgring Combined button')
Check 'track: two rows end with the name = stop' ($null -eq (T @('Nurburgring Nordschleife button', 'Old Nordschleife button') 'Nordschleife'))
Check 'track: a different track that merely contains the words does not count' ($null -eq (T @('Sebring International Raceway button') 'Raceway Sebring'))
Check 'TrackKeyName strips the button word and keeps the accent' ([PickTrack]::TrackKeyName('N' + [char]0xFC + 'rburgring Nordschleife button', 'x') -eq ('N' + [char]0xFC + 'rburgring Nordschleife'))

# iRacing's track names (officialcore's table; the accent / no-accent twins are one track) as the search box shows them
$tracks = @{}
foreach ($m in [regex]::Matches([IO.File]::ReadAllText((Join-Path $root 'dash\src\officialcore.cs')), '(?s)static readonly string\[\] TrackTable = \{(.*?)\};')) {
  foreach ($e in [regex]::Matches($m.Groups[1].Value, '"([a-z0-9\\]+)\|([^"]+)"')) { foreach ($n in ($e.Groups[2].Value -split '\|')) { $tracks[[PickTrack]::TrackKey($n)] = $n } }
}
Check "iRacing track names read from officialcore: $($tracks.Count)" ($tracks.Count -ge 30)
function Rows($search) { $k = [PickTrack]::TrackKey($search); @($tracks.Keys | Where-Object { $_.Contains($k) } | ForEach-Object { $tracks[$_] + ' button' }) }
# what tdsetup does: the full name, then the name without its last words
function FindTrack($track) {
  $w = $track -split ' '
  for ($cut = 0; $cut -lt $w.Count; $cut++) {
    $s = ($w[0..($w.Count - 1 - $cut)]) -join ' '
    $got = T (Rows $s) $s
    if ($got) { return @($got, $s) }
  }
  return $null
}
$expect = @{ 'Tsukuba Circuit 2k Full' = 'Tsukuba Circuit'; 'Nordschleife Industriefahrten' = 'Nordschleife' }
$cache = Join-Path $root 'dash\career-cache.tsv'
$combos = [IO.File]::ReadAllLines($cache, [Text.Encoding]::UTF8) | ForEach-Object { $p = $_ -split "`t"; if ($p.Count -ge 17) { [pscustomobject]@{ Track = $p[7]; Layout = $p[16]; Fuel = $p[15] } } } | Sort-Object Track, Layout -Unique
Check "tracks and layouts in his history: $(@($combos).Count)" (@($combos).Count -ge 10)
Check 'layout column holds names, never the fuel-laps number (columns 15 / 16 of the cache)' (@($combos | Where-Object { $_.Layout -match '^\d+$' }).Count -eq 0)
foreach ($c in $combos) {
  $r = FindTrack $c.Track
  $shown = if ($r) { $r[0] -replace ' button$', '' } else { '' }
  $want = if ($expect.ContainsKey($c.Track)) { $expect[$c.Track] } else { $c.Track }
  Check "$($c.Track)$(if ($c.Layout) { ' / ' + $c.Layout }) -> '$shown'" ($r -and ([PickTrack]::TrackKey($shown) -like ('*' + [PickTrack]::TrackKey($want) + '*'))) 'not found in iRacing''s track names'
}

'4. LAST DRIVE ids: home.js (JavaScript) and irdash / irdeck (C#) must agree'
$js = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\home.js'))
$fn = [regex]::Match($js, '(?s)fnv\(kind, text\) \{.*?\r?\n  \},').Value
$idc = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'src\mydrive.cs')), '(?s)static string MdId\(char kind, string text\).*?\r?\n        \}').Value
Check 'fnv (home.js) and MdId (src\mydrive.cs) found' ($fn.Length -gt 0 -and $idc.Length -gt 0)
Add-Type -Language CSharp -TypeDefinition ("using System; using System.Globalization; public static class IdC { public " + ($idc -replace 'static string', 'static string') + " }")
$wsh = Join-Path $env:TEMP 'pickname-fnv.js'
$body = ($fn -replace '^fnv\(kind, text\) \{', 'function fnv(kind, text) {' -replace '\},\s*$', '}' -replace '\bconst\b|\blet\b', 'var' -replace 'Math\.imul', 'imul')
$polyfill = 'function imul(a,b){var ah=(a>>>16)&0xffff,al=a&0xffff,bh=(b>>>16)&0xffff,bl=b&0xffff;return((al*bl)+(((ah*bl+al*bh)<<16)>>>0)|0);}'
$cases = @($combos | ForEach-Object { 'x|' + $_.Track }) + @('Porsche 718 Cayman GT4|Road America', 'Chevrolet Corvette Z06 GT3.R|Road Atlanta', ('Car|N' + [char]0xFC + 'rburgring Nordschleife'), 'Car|Track "quoted" O''Reilly')
$lines = ($cases | ForEach-Object { 'WScript.Echo(fnv("r", ' + (ConvertTo-Json $_ -Compress) + '));' }) -join "`r`n"
[IO.File]::WriteAllText($wsh, $polyfill + "`r`n" + $body + "`r`n" + $lines, [Text.Encoding]::Unicode)
$out = @(& cscript //nologo $wsh)
Check 'JScript ran the real fnv' ($out.Count -eq $cases.Count) "got $($out.Count) of $($cases.Count)"
for ($i = 0; $i -lt [Math]::Min($out.Count, $cases.Count); $i++) { $cs = [IdC]::MdId([char]'r', $cases[$i]); if ($out[$i].Trim() -ne $cs) { Check "id for '$($cases[$i])' agrees" $false "js=$($out[$i]) c#=$cs" } }
Check "all $($cases.Count) ids agree (js = c#)" (@(0..([Math]::Min($out.Count, $cases.Count) - 1) | Where-Object { $out[$_].Trim() -ne [IdC]::MdId([char]'r', $cases[$_]) }).Count -eq 0)
Remove-Item $wsh -ErrorAction SilentlyContinue

''
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
