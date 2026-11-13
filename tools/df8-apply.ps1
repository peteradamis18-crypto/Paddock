# Loads tools\df8-flags.js into SimHub's DF-8 and sets the box brightness. SimHub keeps its settings in memory and writes
# them when it closes, so it is closed first, edited, then started again. Refuses while a session is on (CLAUDE.md rule 1).
#   powershell -ExecutionPolicy Bypass -File tools\df8-apply.ps1 [-Brightness 100]
param([int]$Brightness = 100)
$root = Split-Path -Parent $PSScriptRoot
if ((& "$root\irdeck-cli.exe" state) -match 'telemetry=on|sim=True') { 'You are in a session - not touching SimHub now.'; exit 2 }
$files = @(
  'C:\Program Files (x86)\SimHub\PluginsData\Common\Devices\97cf2500-188f-4c0f-88b1-b038409258ef\settings.json',
  'C:\Program Files (x86)\SimHub\DevicesDefinitions\Installed\cacbb3b2-a9cc-4a55-9478-2f00a9441e64\BuiltInLedsProfiles\Matrix\5a6f1c2e-0d35-4b8e-9a51-55c0a1d5e088.ledsprofile'
)
$p = Get-Process SimHubWPF -ErrorAction SilentlyContinue
if ($p) { $p.CloseMainWindow() | Out-Null; if (-not $p.WaitForExit(30000)) { 'SimHub did not close - nothing changed.'; exit 1 } }
$bk = 'C:\Temp\ft\backup-before-apply-' + (Get-Date -f HHmmss); New-Item -ItemType Directory -Force $bk | Out-Null; Copy-Item $files $bk
$enc = ConvertTo-Json ([IO.File]::ReadAllText("$PSScriptRoot\df8-flags.js"))
$rx = [regex]'"Expression":(\s*)"// S(SG Racing 8x8 matrix)(?:[^"\\]|\\.)*"'
$bad = 0
foreach ($f in $files) {
  $t = [IO.File]::ReadAllText($f)
  $n = $rx.Matches($t).Count
  $t = $rx.Replace($t, { param($m) '"Expression":' + $m.Groups[1].Value + $enc })
  $t = [regex]::Replace($t, '"(_?MatrixBrightness)":(\s*)[\d.]+', ('"$1":${2}' + $Brightness + '.0'))
  $null = $t | ConvertFrom-Json
  [IO.File]::WriteAllText($f, $t)
  "$(Split-Path $f -Leaf): script replaced $n time(s), brightness $Brightness"
  if ($n -ne 1) { $bad++ }
}
Start-Process explorer.exe -ArgumentList '"C:\Program Files (x86)\SimHub\SimHubWPF.exe"'
if ($bad) { 'WARNING: the script was not found exactly once in every file.'; exit 1 }
exit 0
