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
''
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
