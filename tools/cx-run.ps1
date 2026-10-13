# Run one job through OpenAI Codex on Peter's ChatGPT Pro plan (no API cost) as its own process.
#   cx-run.ps1 -Prompt docs\cards\X.md -Id X [-Sandbox read-only|workspace-write] [-Images a.png,b.png]
# Output: docs\tasks\log\cx\<Id>.txt (+ <Id>.last.md = final answer, <Id>.done when finished). Codex reads AGENTS.md itself.
param([Parameter(Mandatory)][string]$Prompt, [Parameter(Mandatory)][string]$Id, [string]$Sandbox = 'read-only', [string[]]$Images = @())
# build/fix jobs: pass -Sandbox workspace-write; it is upgraded to full access so Chrome-based tests can run (deploys still go through tools\deploy-broker.ps1)
if ($Sandbox -eq 'workspace-write') { $Sandbox = 'danger-full-access' }
$root = Split-Path -Parent $PSScriptRoot; Set-Location $root
$dir = Join-Path $root 'docs\tasks\log\cx'; New-Item -ItemType Directory -Force $dir | Out-Null
Remove-Item (Join-Path $dir "$Id.done") -EA SilentlyContinue
$cx = Join-Path $root 'tools\codex\codex-x86_64-pc-windows-msvc.exe'
$env:PADDOCK_NO_DEPLOY = '1'   # dash\build.ps1 refuses to deploy from a Codex job (an irdash started there filmed 0 frames)
$text = [IO.File]::ReadAllText((Join-Path $root $Prompt), [Text.Encoding]::UTF8)
# Peter's own Codex app config stays untouched; per run: the no-admin sandbox, and no screen/browser control (CLAUDE.md rule 1)
$a = @('exec', '-s', $Sandbox, '--skip-git-repo-check', '-C', $root, '--output-last-message', (Join-Path $dir "$Id.last.md"),
  '-c', 'windows.sandbox="unelevated"', '-c', 'model_reasoning_effort="high"',
  '-c', 'plugins."computer-use@openai-bundled".enabled=false', '-c', 'plugins."unified-computer-use@openai-bundled".enabled=false',
  '-c', 'plugins."browser@openai-bundled".enabled=false', '-c', 'mcp_servers.node_repl.enabled=false')
foreach ($i in $Images) { $a += @('-i', (Join-Path $root $i)) }
$text | & $cx @a - *> (Join-Path $dir "$Id.txt")
Set-Content (Join-Path $dir "$Id.done") "exit $LASTEXITCODE $(Get-Date -Format s)"
