# shot.ps1 - a 1920 x 1080 picture of one page of the running irdash, in headless Chrome (nothing on Peter's screens).
#   powershell -File tests\shot.ps1 -Url "http://localhost:8199/v2/coach.html?id=..." -Out tests\shots\coach.png [-Wait 6000]
param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Out, [int]$Wait = 6000)
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$prof = Join-Path $env:TEMP ('shot-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $raw = "$prof.png"
# headless Chrome loses a strip of the window to its own frame: render taller, then crop to exactly 1920 x 1080
$null = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', '--hide-scrollbars', '--mute-audio', "--user-data-dir=$prof", "--virtual-time-budget=$Wait", '--window-size=1920,1200', "--screenshot=$raw", $Url) -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$prof.o" -RedirectStandardError "$prof.e"
Add-Type -AssemblyName System.Drawing
if (-not (Test-Path $raw)) { Write-Host 'no picture'; exit 1 }
$img = [Drawing.Image]::FromFile($raw); $bmp = New-Object Drawing.Bitmap 1920, 1080; $g = [Drawing.Graphics]::FromImage($bmp)
$g.DrawImage($img, (New-Object Drawing.Rectangle 0, 0, 1920, 1080), (New-Object Drawing.Rectangle 0, 0, 1920, 1080), [Drawing.GraphicsUnit]::Pixel)
$g.Dispose(); $img.Dispose(); New-Item -ItemType Directory -Force (Split-Path -Parent $Out) | Out-Null; $bmp.Save($Out, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
Remove-Item $raw, "$prof.o", "$prof.e" -ErrorAction SilentlyContinue; Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "picture $Out"
