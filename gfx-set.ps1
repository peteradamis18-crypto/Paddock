# Changes iRacing graphics values in rendererDX11Monitor.ini, [Graphics Options] section only
# (the driving settings; [Replay Graphics] is left alone). Keeps iRacing's comments and encoding.
# Refuses while the sim is running (iRacing rewrites the file on exit). Backs up first.
#   gfx-set.ps1 -Set @{ SSAO = 1; CarDetail = 2 }      apply values
#   gfx-set.ps1 -Restore <backup file>                 put a backup back
param([hashtable]$Set, [string]$Restore)
$ini = Join-Path $env:USERPROFILE 'OneDrive\Documents\iRacing\rendererDX11Monitor.ini'
$bkDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'backup'
if (Get-Process iRacingSim64DX11 -ErrorAction SilentlyContinue) { 'The iRacing sim is running - close the race first.'; exit 1 }
if ($Restore) { Copy-Item -LiteralPath $Restore -Destination $ini -Force; "restored $Restore"; exit 0 }
$enc = [Text.Encoding]::GetEncoding(28591)   # Latin-1, as iRacing writes it
$bk = Join-Path $bkDir ('rendererDX11Monitor-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.ini')
Copy-Item -LiteralPath $ini -Destination $bk
$text = [IO.File]::ReadAllText($ini, $enc)
$nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$lines = $text -split [regex]::Escape($nl)
$sec = ''; $done = @{}
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^\[(.+)\]') { $sec = $Matches[1]; continue }
  if ($sec -ne 'Graphics Options') { continue }
  if ($lines[$i] -match '^(\w+)=([^;\s]*)(.*)$' -and $Set.ContainsKey($Matches[1])) {
    $k = $Matches[1]; $old = $Matches[2]; $rest = $Matches[3]; $new = [string]$Set[$k]
    $lines[$i] = "$k=$new" + $rest   # $rest is iRacing's padding and comment, kept as is
    "{0}: {1} -> {2}" -f $k, $old, $new; $done[$k] = $true
  }
}
foreach ($k in $Set.Keys) { if (-not $done[$k]) { "not found (unchanged): $k" } }
[IO.File]::WriteAllText($ini, ($lines -join $nl), $enc)
"backup: $bk"
