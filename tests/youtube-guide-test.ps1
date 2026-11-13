# youtube-guide-test.ps1 - offline: docs\YOUTUBE-SETUP.md is complete and safe to keep in a public repo (W0-10).
#   powershell -ExecutionPolicy Bypass -File tests\youtube-guide-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$script:pass = 0; $script:fail = 0
function Check($what, $cond) { if ($cond) { $script:pass++; "  ok   $what" } else { $script:fail++; "  FAIL $what" } }
'youtube guide test'
$f = Join-Path $root 'docs\YOUTUBE-SETUP.md'
Check 'the guide exists' (Test-Path $f)
$text = if (Test-Path $f) { [IO.File]::ReadAllText($f) } else { '' }
$lines = $text -split "`r?`n"
Check 'it names the exact client.json path' ($text.Contains('C:\Users\peter\iRacingDeck\dash\yt\client.json'))
Check 'it gives the upload scope' ($text.Contains('https://www.googleapis.com/auth/youtube.upload'))
Check 'it names the key steps (project, API, Desktop app, Publish app, Advanced)' (($text -match 'YouTube Data API v3') -and ($text -match 'Desktop app') -and ($text -match 'Publish app') -and ($text -match 'Advanced'))
Check 'it is dated' ($text -match 'Written 20\d\d-\d\d-\d\d')
# every instruction under a "## " heading is a numbered line: a bullet is only allowed under "Limits" and in the intro
$sec = ''; $bad = @()
foreach ($l in $lines) {
  if ($l -match '^## (.+)') { $sec = $matches[1]; continue }
  if ($sec -and $sec -ne 'Limits' -and $l -match '^\s*[-*] ') { $bad += $l }
}
Check 'no un-numbered bullet steps outside the Limits section' ($bad.Count -eq 0)
$nums = @($lines | Where-Object { $_ -match '^\d+\. ' })
Check 'at least 25 numbered steps' ($nums.Count -ge 25)
$ok = $true; $prev = 0
foreach ($l in $lines) {
  if ($l -match '^## ') { $prev = 0 }
  if ($l -match '^(\d+)\. ') { $n = [int]$matches[1]; if ($n -ne $prev + 1) { $ok = $false }; $prev = $n }
}
Check 'numbers run 1, 2, 3 ... inside each section' $ok
$gi = [IO.File]::ReadAllText((Join-Path $root '.gitignore'))
Check '.gitignore has dash/yt/' ($gi -match '(?m)^/?dash/yt/\s*$')
# nothing that looks like a Google client id, secret, API key or token
Check 'no client id' ($text -notmatch '\d{6,}-[a-z0-9]{10,}\.apps\.googleusercontent\.com')
Check 'no client secret' ($text -notmatch 'GOCSPX-[A-Za-z0-9_-]{8,}')
Check 'no API key or token' (($text -notmatch 'AIza[0-9A-Za-z_-]{20,}') -and ($text -notmatch 'ya29\.[0-9A-Za-z_-]{10,}') -and ($text -notmatch '1//[0-9A-Za-z_-]{20,}'))
Check 'no long random string' (@([regex]::Matches($text, '[A-Za-z0-9_-]{32,}') | Where-Object { $_.Value -notmatch '^[a-z]+$' }).Count -eq 0)
$yt = Join-Path $root 'dash\yt'
Check 'no dash\yt folder in the repo tree' (-not (Test-Path (Join-Path $yt 'client.json')))
"youtube guide: $script:pass ok, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
