Set-Location 'C:\Users\peter\iRacingDeck'; while (-not (Test-Path docs\tasks\log\cx\DK-1s.done)) { Start-Sleep 20 }; & .\tools\cx-run.ps1 -Prompt docs\cards\S1d.md -Id S1d -Sandbox workspace-write
