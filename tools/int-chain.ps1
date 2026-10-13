Set-Location 'C:\Users\peter\iRacingDeck'; while (-not (Test-Path docs\tasks\log\cx\S1g.done)) { Start-Sleep 30 }; & .\tools\cx-run.ps1 -Prompt docs\cards\INT-1.md -Id INT-1 -Sandbox workspace-write
