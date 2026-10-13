# Run one card through OpenCode (cheap OpenRouter model) as its own process, so no 10-minute tool limit cuts it off.
#   oc-card.ps1 -Card docs\cards\S1-save-recording.md -Id S1 [-Model deepseek/deepseek-v4.1-flash]
# Output: docs\tasks\log\or\<Id>-opencode.txt, and <Id>-opencode.done (exit code) when it ends.
param([Parameter(Mandatory)][string]$Card, [Parameter(Mandatory)][string]$Id, [string]$Model = 'deepseek/deepseek-v4.1-flash')
$root = Split-Path -Parent $PSScriptRoot; Set-Location $root
$env:OPENROUTER_API_KEY = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User')
$out = "docs\tasks\log\or\$Id-opencode.txt"; Remove-Item "docs\tasks\log\or\$Id-opencode.done" -EA SilentlyContinue
& .\tools\opencode\opencode.exe run --model "openrouter/$Model" "Do the card in $Card. Follow AGENTS.md. Iterate until the gate passes or you are blocked, then write the report." *> $out
Set-Content "docs\tasks\log\or\$Id-opencode.done" "exit $LASTEXITCODE $(Get-Date -Format s)"
