# samples GET /tv/data every 5 s while the sim runs (read-only, BelowNormal) -> docs\tasks\log\tv-live-<stamp>.jsonl
$root = Split-Path -Parent $PSScriptRoot; Set-Location $root
try { $me = Get-Process -Id $PID; $me.PriorityClass = 'BelowNormal'; $me.ProcessorAffinity = [IntPtr]0xC000 } catch { }
$out = Join-Path $root ("docs\tasks\log\tv-live-" + (Get-Date -Format 'yyyyMMdd-HHmm') + ".jsonl"); $off = 0
while ($off -lt 24) {
  if ((& .\irdeck-cli.exe state | Out-String) -match 'sim=True') { $off = 0 } else { $off++ }
  try { $c = (Invoke-WebRequest http://localhost:8199/tv/data -UseBasicParsing -TimeoutSec 3).Content; Add-Content $out ("{""at"":""" + (Get-Date -Format s) + """,""d"":" + $c + "}") } catch { }
  Start-Sleep 5
}