# tools\cosworth-workbook.ps1 - make Paddock's ready workbook for Cosworth Pi Toolbox (card W-19).
#
# Pi Toolbox workbooks are .pwb files. This PC's installed iRacing Lite workbook (the read-only Program Files template) is a
# binary OLE2 / Compound File Binary, not text, XML or a ZIP of readable XML. Cosworth does not document that binary format,
# so Paddock cannot safely inject its six ready displays (speed, throttle, brake, steering, gear, delta) or set the PB as the
# datum outing. The script therefore reports NOT SUPPORTED and writes nothing. Text/XML/ZIP formats also remain unsupported
# until Paddock can edit and verify their display structure.
#
#   powershell -ExecutionPolicy Bypass -File tools\cosworth-workbook.ps1 -Check   # decision + path, changes nothing
#   powershell -ExecutionPolicy Bypass -File tools\cosworth-workbook.ps1          # makes the workbook, or NOT SUPPORTED
#
# It never writes under Documents\iRacing or an iRacing install folder, and never runs while Peter drives.
param([switch]$Check, [string]$Dest = '', [string]$Source = '')
$ErrorActionPreference = 'Stop'

$script:docs = [Environment]::GetFolderPath('MyDocuments')

# The iRacing folders this script must never write to (read-only by rule).
function Test-UnderIRacing([string]$p) {
    if ([string]::IsNullOrEmpty($p)) { return $false }
    try { $full = [IO.Path]::GetFullPath($p).TrimEnd([char]92) } catch { return $true }
    foreach ($base in @((Join-Path $script:docs 'iRacing'), 'C:\Program Files (x86)\iRacing', 'C:\Program Files\iRacing')) {
        $root = [IO.Path]::GetFullPath($base).TrimEnd([char]92)
        if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Pi's install folder and the read-only iRacing Lite workbook template it ships.
function Get-PiTemplate {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))
    foreach ($root in $roots) {
        if ([string]::IsNullOrEmpty($root)) { continue }
        $sim = Join-Path (Join-Path $root 'Pi Toolbox') 'Templates\Sim'
        if (-not (Test-Path -LiteralPath $sim)) { continue }
        foreach ($wb in Get-ChildItem -LiteralPath $sim -Filter 'iRacing*.pwb' -ErrorAction SilentlyContinue) {
            if ($wb.Name -match '(?i)lite') { return $wb.FullName }
        }
    }
    return $null
}

# Pi's user folder for documents/workbooks: the "My Documents" browser location in its settings.
function Get-PiUserFolder {
    try {
        $base = 'HKCU:\Software\Pi Research\Pi Toolbox\Document Locations'
        if (Test-Path $base) {
            foreach ($sub in Get-ChildItem $base -ErrorAction SilentlyContinue) {
                $k = Get-Item $sub.PSPath
                $cap = [string]$k.GetValue('Caption')
                $path = [string]$k.GetValue('Path')
                if ($path -and $cap -match '(?i)my documents') { return $path.TrimEnd('\') }
            }
        }
    } catch { }
    return $script:docs
}

# The workbook container format: ole2 (binary compound file), zip, xml, text or binary.
function Get-WorkbookFormat([string]$path) {
    $fs = [IO.File]::OpenRead($path)
    try {
        $n = [int][Math]::Min(4096, $fs.Length); $buf = New-Object byte[] $n; [void]$fs.Read($buf, 0, $n)
    } finally { $fs.Dispose() }
    if ($n -ge 8 -and $buf[0] -eq 0xD0 -and $buf[1] -eq 0xCF -and $buf[2] -eq 0x11 -and $buf[3] -eq 0xE0 -and
        $buf[4] -eq 0xA1 -and $buf[5] -eq 0xB1 -and $buf[6] -eq 0x1A -and $buf[7] -eq 0xE1) { return 'ole2' }
    if ($n -ge 4 -and $buf[0] -eq 0x50 -and $buf[1] -eq 0x4B -and $buf[2] -eq 0x03 -and $buf[3] -eq 0x04) { return 'zip' }
    $txt = [Text.Encoding]::UTF8.GetString($buf).TrimStart([char]0xEF, [char]0xBB, [char]0xBF, ' ', "`t", "`r", "`n")
    if ($txt.StartsWith('<?xml')) { return 'xml' }
    $printable = 0; foreach ($b in $buf) { if (($b -ge 9 -and $b -le 13) -or ($b -ge 32 -and $b -lt 127)) { $printable++ } }
    if ($n -gt 0 -and ($printable / $n) -gt 0.9) { return 'text' }
    return 'binary'
}

$supportedKinds = @()

$template = if ($Source) { $Source } else { Get-PiTemplate }
$userFolder = Get-PiUserFolder
$dest = if ($Dest) { $Dest } else { Join-Path $userFolder 'Paddock.pwb' }

Write-Output ("Pi user folder: {0}" -f $userFolder)
if (-not $template) {
    Write-Output 'Source workbook: (Pi Toolbox not installed)'
    Write-Output 'Format: none'
    Write-Output ("Destination: {0}" -f $dest)
    Write-Output 'Status: NOT SUPPORTED'
    Write-Output 'NOT SUPPORTED'
    exit 3
}
$kind = Get-WorkbookFormat $template
$supported = $supportedKinds -contains $kind
Write-Output ("Source workbook: {0}" -f $template)
Write-Output ("Format: {0}" -f $kind)
Write-Output ("Destination: {0}" -f $dest)
if (Test-UnderIRacing $dest) { Write-Output 'Status: REFUSED'; Write-Output 'REFUSED: destination is under an iRacing folder'; exit 4 }
Write-Output 'Status: NOT SUPPORTED'

if (-not $supported) {
    # Do not call a copied stock template a ready workbook; each format needs a verified editor first.
    Write-Output 'NOT SUPPORTED'
    exit 3
}

