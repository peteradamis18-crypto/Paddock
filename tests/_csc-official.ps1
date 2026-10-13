$ErrorActionPreference = 'Continue'
# throwaway compile for H-02; delete after gate
$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $env:TEMP "official-unit-csc.exe"
& "$fw\csc.exe" -nologo -r:System.Web.Extensions.dll "-out:$out" "$root\tests\official-unit.cs" "$root\dash\src\officialcore.cs" "$root\dash\src\official.cs"
