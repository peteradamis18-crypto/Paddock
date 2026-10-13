# Paddock: store Peter's OpenRouter key on this PC (run by tools\openrouter-key.cmd - his double-click).
# The key is typed/pasted by Peter into this window (hidden), saved as his user environment variable OPENROUTER_API_KEY
# and never shown, logged or written to any file. Claude never sees it. To remove: tools\openrouter-key.cmd -Remove.
param([switch]$Remove)
$host.UI.RawUI.WindowTitle = 'Paddock: OpenRouter key'
if ($Remove) {
  [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $null, 'User')
  Write-Host 'OpenRouter key removed from this PC.'
  Start-Sleep -Seconds 5; exit 0
}
Write-Host 'Paste your OpenRouter key (starts with sk-or-) and press Enter. It will not be shown.'
$s = Read-Host -AsSecureString 'Key'
$b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
try { $k = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
$k = $k.Trim()
if ($k -notmatch '^sk-or-[A-Za-z0-9\-]{20,}$') { Write-Host 'That does not look like an OpenRouter key (sk-or-...). Nothing saved.'; Start-Sleep -Seconds 8; exit 1 }
# check it works before saving (key info only, no model call, costs nothing)
try {
  $r = Invoke-RestMethod 'https://openrouter.ai/api/v1/key' -Headers @{ Authorization = "Bearer $k" } -TimeoutSec 20
  $lim = if ($r.data.limit) { '$' + $r.data.limit } else { 'no limit set on this key' }
  Write-Host ("Key works. Spent so far: `$" + $r.data.usage + ". Limit: " + $lim + ".")
} catch { Write-Host ('OpenRouter did not accept the key: ' + $_.Exception.Message + '. Nothing saved.'); Start-Sleep -Seconds 10; exit 1 }
[Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $k, 'User')
$k = $null
Write-Host 'Saved. Paddock can now use OpenRouter. This window closes by itself.'
Start-Sleep -Seconds 8
