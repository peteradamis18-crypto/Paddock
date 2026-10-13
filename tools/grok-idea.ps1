# Asks for an idea in plain words; Grok (strong model) turns it into a proper task card in docs\TASKS.md + the roadmap.
Add-Type -AssemblyName Microsoft.VisualBasic, PresentationFramework
$t = [Microsoft.VisualBasic.Interaction]::InputBox('Describe the new feature or change in plain words:', 'Paddock - new idea for Grok', '')
if (-not $t -or -not $t.Trim()) { exit 0 }
[void][System.Windows.MessageBox]::Show('Grok is writing the task card now (a few minutes). It gets built the next time "Grok - Build all" runs.', 'Paddock - Grok')
& (Join-Path $PSScriptRoot 'grok-run.ps1') -Idea $t.Trim()
