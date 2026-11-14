# deck-render.ps1 (W3-4): the ONLY maker of the deck's key pictures. Opens deck\render.html in headless Chrome (the same drawing
# as the add-on: deck\keyart.js) with deck\layout.json, and writes
#   deck\keys\<PAGE>\<c>,<r>.png   one 144 px picture per key (build-deck.ps1 packages these)
#   deck\preview-<PAGE>.png        the whole page as a contact sheet (look at it before the lead ships)
#   deck\keys\measure.json         what each label measured (tests\deck-render-test.ps1), deck\keys\exit-96.png (the add-on's EXIT key)
# Writes nothing outside deck\ and %TEMP%. Safe while Peter races (one headless Chrome for a few seconds, BelowNormal).
#   powershell -ExecutionPolicy Bypass -File tools\deck-render.ps1 [-Layout <layout.json>] [-Out <folder>]
param([string]$Layout = '', [string]$Out = '')
$ErrorActionPreference = 'Stop'
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$deck = Join-Path $root 'deck'
if (-not $Layout) { $Layout = Join-Path $deck 'layout.json' }
if (-not $Out) { $Out = $deck }
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { throw 'deck-render: Chrome not found - no key pictures made' }
$u8 = New-Object Text.UTF8Encoding $false

$tmp = Join-Path $env:TEMP ('deck-render-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  Copy-Item (Join-Path $deck 'render.html') "$tmp\render.html"
  Copy-Item (Join-Path $deck 'keyart.js') "$tmp\keyart.js"
  $json = [IO.File]::ReadAllText($Layout, [Text.Encoding]::UTF8)
  $null = $json | ConvertFrom-Json   # a broken layout.json stops here, loudly
  [IO.File]::WriteAllText("$tmp\layout.js", 'window.DECK_LAYOUT = ' + $json + ';', $u8)
  $url = 'file:///' + ("$tmp\render.html" -replace '\\', '/')
  $ErrorActionPreference = 'Continue'   # Chrome writes harmless lines to stderr; Windows PowerShell would stop on them
  $dom = & $chrome --headless=new --disable-gpu --no-first-run --hide-scrollbars "--user-data-dir=$tmp\prof" --allow-file-access-from-files --virtual-time-budget=8000 --dump-dom $url 2>$null | Out-String
  $ErrorActionPreference = 'Stop'
  $m = [regex]::Match($dom, '(?s)<pre id="out">(.*?)</pre>')
  if (-not $m.Success -or $m.Groups[1].Value.Length -lt 10) { throw 'deck-render: render.html gave no pictures' }
  $text = $m.Groups[1].Value.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&amp;', '&')
  $r = $text | ConvertFrom-Json
  if ($r.error) { throw ('deck-render: render.html failed: ' + $r.error) }
  function Save($dataUrl, $path) { [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($dataUrl.Substring($dataUrl.IndexOf(',') + 1))) }
  $keysDir = Join-Path $Out 'keys'
  if (Test-Path $keysDir) { Remove-Item -LiteralPath $keysDir -Recurse -Force }   # no stale picture of a key that left the layout
  $n = 0
  foreach ($page in $r.keys.PSObject.Properties) {
    $pd = Join-Path $keysDir $page.Name; New-Item -ItemType Directory -Force $pd | Out-Null
    foreach ($k in $page.Value.PSObject.Properties) { Save $k.Value (Join-Path $pd ($k.Name + '.png')); $n++ }
  }
  foreach ($s in $r.sheets.PSObject.Properties) { Save $s.Value (Join-Path $Out ('preview-' + $s.Name + '.png')) }
  Save $r.exit96 (Join-Path $keysDir 'exit-96.png')
  [IO.File]::WriteAllText((Join-Path $keysDir 'measure.json'), ((@{ measure = $r.measure; glyphs = $r.glyphs }) | ConvertTo-Json -Depth 8), $u8)
  "rendered $n keys to $keysDir and the preview sheets deck\preview-*.png"
}
finally {
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$tmp*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 200
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
