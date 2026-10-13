# Paddock: let Peter's iPhone reach Paddock on the home network (P1). Run by tools\phone-allow.cmd / phone-undo.cmd (his double-click).
# Paddock itself NEVER changes Windows: this script asks Windows for admin once (UAC) and then does three small things:
#   allow  1. if Windows calls the home network "Public", mark it "Private" (home) - the firewall rule below is Private-only - and
#             remember what it was, so UNDO can put it back
#          2. one firewall rule, exact name 'Paddock phone (irdash 8199 in)': TCP 8199 in, Private profile only, local subnet only,
#             program dash\irdash.exe only
#          3. write dash\phone-allowed.txt: irdash sees it within 30 s and starts listening on the home address (no restart)
#   undo   remove the rule, put the network category back, delete the flag and forget every paired phone (dash\phone-tokens.txt)
# Everything is logged to tools\phone-tools.log.
param([ValidateSet('allow', 'undo')][string]$Do = 'allow')
$root = Split-Path -Parent $PSScriptRoot
$rule = 'Paddock phone (irdash 8199 in)'
$flag = Join-Path $root 'dash\phone-allowed.txt'
$tokens = Join-Path $root 'dash\phone-tokens.txt'
$log = Join-Path $PSScriptRoot 'phone-tools.log'
function L($m) { try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Do  $m" | Add-Content $log } catch { }; Write-Host $m }
$host.UI.RawUI.WindowTitle = "Paddock: phone $Do"
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  Write-Host 'Windows will ask for permission: click Yes.'
  Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Do', $Do)
  exit
}
try {
  if ($Do -eq 'allow') {
    $prof = Get-NetConnectionProfile | Where-Object { $_.IPv4Connectivity -ne 'Disconnected' -and $_.IPv4Connectivity -ne 'NoTraffic' } | Select-Object -First 1
    if (-not $prof) { $prof = Get-NetConnectionProfile | Select-Object -First 1 }
    $was = ''
    if ($prof) {
      $was = "$($prof.NetworkCategory)"
      if ($prof.NetworkCategory -eq 'Public') { Set-NetConnectionProfile -InterfaceIndex $prof.InterfaceIndex -NetworkCategory Private; L "network '$($prof.Name)' is now Private (home). It was Public." }
      else { L "network '$($prof.Name)' is already $($prof.NetworkCategory)." }
    }
    Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8199 -Profile Private -RemoteAddress LocalSubnet `
      -Program (Join-Path $root 'dash\irdash.exe') -Description 'Paddock: your phone on the home network. Remove with tools\phone-undo.cmd.' | Out-Null
    L "firewall rule '$rule' added: TCP 8199 in, Private network only, your own network only, dash\irdash.exe only."
    "allowed`t$(Get-Date -Format s)`tnetwork=$(if ($prof) { $prof.Name })`twas=$was`tinterface=$(if ($prof) { $prof.InterfaceIndex })" | Set-Content $flag -Encoding ASCII
    L 'Done. Within 30 seconds the top screen shows a code to scan with your iPhone.'
  } else {
    Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    L "firewall rule '$rule' removed."
    if (Test-Path $flag) {
      $p = (Get-Content $flag -First 1) -split "`t"
      $was = ($p | Where-Object { $_ -like 'was=*' } | Select-Object -First 1) -replace '^was=', ''
      $ifx = ($p | Where-Object { $_ -like 'interface=*' } | Select-Object -First 1) -replace '^interface=', ''
      if ($was -eq 'Public' -and $ifx) { try { Set-NetConnectionProfile -InterfaceIndex ([int]$ifx) -NetworkCategory Public -ErrorAction Stop; L 'network marked Public again, as it was.' } catch { L "could not put the network back to Public: $($_.Exception.Message)" } }
      Remove-Item $flag -Force
    }
    if (Test-Path $tokens) { Remove-Item $tokens -Force; L 'every paired phone forgotten.' }
    L 'Done. Within 30 seconds Paddock answers this PC only again.'
  }
} catch { L "FAILED: $($_.Exception.Message)" }
Write-Host ''
Write-Host 'This window closes by itself.'
Start-Sleep -Seconds 12
