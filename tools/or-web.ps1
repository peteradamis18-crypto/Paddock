# Cheap web research through OpenRouter's web plugin (no Claude tokens). The model searches, reads results and writes a sourced answer.
#   or-web.ps1 -Ask docs\cards\R2.md -Out docs\research\x.md [-Model deepseek/deepseek-v4-pro-0813] [-Results 15]
# Key: user env var OPENROUTER_API_KEY (never printed). Cost goes to docs\tasks\log\or\ like or-run.ps1.
param([Parameter(Mandatory)][string]$Ask, [Parameter(Mandatory)][string]$Out, [string]$Model = 'deepseek/deepseek-v4-pro-0813', [int]$Results = 15, [int]$MaxOutTokens = 16000)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot; Set-Location $root
$key = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User'); if (-not $key) { throw 'OPENROUTER_API_KEY is not set' }
$prompt = [IO.File]::ReadAllText((Join-Path $root $Ask), [Text.Encoding]::UTF8)   # Get-Content -Raw adds note properties that ConvertTo-Json turns into an object
$body = @{ model = $Model; max_tokens = $MaxOutTokens; usage = @{ include = $true }
  plugins = @(@{ id = 'web'; max_results = $Results })
  messages = @(@{ role = 'user'; content = $prompt }) } | ConvertTo-Json -Depth 6
$t0 = Get-Date
try {
  $r = Invoke-RestMethod https://openrouter.ai/api/v1/chat/completions -Method Post -ContentType 'application/json; charset=utf-8' `
    -Headers @{ Authorization = "Bearer $key"; 'X-Title' = 'Paddock or-web' } -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 900
} catch {
  # PowerShell 5.1 hides OpenRouter's reason; read it from the response
  $why = ''; try { $why = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
  throw "OpenRouter refused: $($_.Exception.Message) $why"
}
$text = $r.choices[0].message.content
$cites = @($r.choices[0].message.annotations | Where-Object { $_.type -eq 'url_citation' } | ForEach-Object { '- ' + $_.url_citation.title + ' ' + $_.url_citation.url } | Select-Object -Unique)
$outPath = Join-Path $root $Out; New-Item -ItemType Directory -Force (Split-Path $outPath) | Out-Null
Set-Content $outPath ($text + "`n`n## Sources the search returned`n" + ($cites -join "`n")) -Encoding UTF8
$u = $r.usage
$line = "or-web $Ask -> $Out | $Model | in $($u.prompt_tokens) out $($u.completion_tokens) | cost `$$($u.cost) | $([int]((Get-Date)-$t0).TotalSeconds) s"
$logDir = Join-Path $root 'docs\tasks\log\or'; New-Item -ItemType Directory -Force $logDir | Out-Null
Add-Content (Join-Path $logDir 'or-web.log') ("$(Get-Date -Format s) " + $line) -Encoding UTF8
Write-Host $line
