# addon-install-test.ps1 (W1-8) - the Stream Deck add-on installs itself: install.ps1 -Stage, AddOn.Install (dash\src\addon.cs), the
# guard lists and tools\addon-update.ps1. OFFLINE: scratch folders and a pretend irdash on another port. It never touches
# %APPDATA%, Stream Deck or the real irdash.
#   powershell -ExecutionPolicy Bypass -File tests\addon-install-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
$root = Split-Path -Parent $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP "addon-install-test-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$pass = 0; $fail = 0
function Section($n) { Assert-RigFree -Where $n; "$n" }
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
$job = $null
try {
  Section '1. install.ps1 -Stage builds the folder and stops'
  $pkg = Join-Path $root 'deck-intro\build\com.peter.rigintro.streamDeckPlugin'
  if (Test-Path $pkg) { Remove-Item $pkg -Force }
  $before = @(Get-Process explorer -ErrorAction SilentlyContinue).Count
  $o = (& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'deck-intro\install.ps1') -Stage) -join "`n"
  $stage = Join-Path $root 'deck-intro\build\com.peter.rigintro.sdPlugin'
  $ver = [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'deck-intro\install.ps1')), "\`$ver = '([0-9.]+)'").Groups[1].Value
  Check "-Stage says staged ($o)" ($o -match '^staged ')
  Check "manifest.json has Version = `$ver ($ver)" ((Test-Path "$stage\manifest.json") -and (([IO.File]::ReadAllText("$stage\manifest.json")) -match "`"Version`":\s*`"$([regex]::Escape($ver))`""))
  Check 'plugin.html is there' (Test-Path "$stage\plugin.html")
  Check 'the 11 bundled profiles are there' ((Get-ChildItem $stage -Filter *.streamDeckProfile).Count -eq 11)
  Check 'no .streamDeckPlugin package was made, nothing was opened' (-not (Test-Path $pkg))

  Section '2. AddOn.Install on scratch folders'
  $out = & $csc /nologo /target:exe "/out:$tmp\addon-main.exe" /r:System.dll /r:System.Core.dll (Join-Path $root 'dash\src\addon.cs') (Join-Path $PSScriptRoot 'addon-install-main.cs') 2>&1
  Check 'addon.cs compiles alone (C# 5, Windows csc)' ((Test-Path "$tmp\addon-main.exe") -and -not ($out | Where-Object { $_ -match 'error' }))
  if (Test-Path "$tmp\addon-main.exe") {
    Assert-RigFree -Where 'addon rules'
    & "$tmp\addon-main.exe" "$tmp\run" | Out-File "$tmp\out.txt" -Encoding utf8
    foreach ($l in (Get-Content "$tmp\out.txt" -Encoding utf8)) {
      if ($l -match '^\s+ok\s') { $script:pass++; $l } elseif ($l -match '^\s+FAIL\s') { $script:fail++; $l } elseif ($l -notmatch 'passed, .* failed') { $l }
    }
  } else { $out }
  $b = [IO.File]::ReadAllText((Join-Path $root 'dash\build.ps1'))
  Check 'addon.cs is in dash\build.ps1' ($b -match 'src\\addon\.cs')
  Check 'addon.cs stays C# 5 (no $", ?., nameof, out var)' (-not ([IO.File]::ReadAllText((Join-Path $root 'dash\src\addon.cs')) -match '\$"|\?\.[A-Za-z]|nameof\(|out var '))

  Section '3. the guard lists and the route'
  $rs = [IO.File]::ReadAllText((Join-Path $root 'dash\src\rigstate.cs'))
  Check 'addoninstall is in Gate.GuardedDo' ($rs -match '(?s)GuardedDo = new HashSet<string> \{.*?"addoninstall".*?\};')
  Check '/api/addon is in the read-only API list' ($rs -match '(?s)ReadOnlyApi = new HashSet<string> \{.*?"/api/addon".*?\};')
  $id = [IO.File]::ReadAllText((Join-Path $root 'dash\src\irdash.cs'))
  Check 'irdash.cs routes addoninstall (AddOn.Handles) and GET /api/addon' (($id -match 'AddOn\.Handles\(dc\)') -and ($id -match 'path == "/api/addon"'))

  Section '4. tools\addon-update.ps1 against a pretend irdash'
  $port = 18199
  $job = Start-Job -ArgumentList $port, $tmp -ScriptBlock {
    param($port, $tmp)
    $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$port/"); $l.Start()
    while ($true) {
      $c = $l.GetContext()
      $say = [IO.File]::ReadAllText("$tmp\say.txt"); $code = [int][IO.File]::ReadAllText("$tmp\code.txt")
      [IO.File]::WriteAllText("$tmp\seen.txt", "$($c.Request.Url.PathAndQuery)|$($c.Request.Headers['X-Paddock'])")
      $bytes = [Text.Encoding]::UTF8.GetBytes('{"say":"' + $say + '"}'); $c.Response.StatusCode = $code; $c.Response.ContentType = 'application/json'
      $c.Response.OutputStream.Write($bytes, 0, $bytes.Length); $c.Response.Close()
    }
  }
  Start-Sleep -Milliseconds 1500
  $upd = Join-Path $root 'tools\addon-update.ps1'
  foreach ($case in @(@('Add-on 1.9.2.0 installed and running', 200, 0), @('Add-on 1.9.2.0 copied, but it has not connected yet - look at the deck', 409, 1), @('Add-on 1.9.2.0 is already installed', 200, 1))) {
    [IO.File]::WriteAllText("$tmp\say.txt", $case[0]); [IO.File]::WriteAllText("$tmp\code.txt", [string]$case[1]); Remove-Item "$tmp\seen.txt" -ErrorAction SilentlyContinue
    $o = (& powershell -ExecutionPolicy Bypass -File $upd -Port $port) -join "`n"; $ec = $LASTEXITCODE
    Check "'$($case[0])': words printed, exit code $($case[2])" (($o -match [regex]::Escape($case[0])) -and ($ec -eq $case[2]))
    Check '  the request was /api/do?c=addoninstall with X-Paddock: 1' ((Test-Path "$tmp\seen.txt") -and ([IO.File]::ReadAllText("$tmp\seen.txt") -eq '/api/do?c=addoninstall|1'))
  }
  Stop-Job $job; Remove-Job $job -Force; $job = $null
  $o = (& powershell -ExecutionPolicy Bypass -File $upd -Port $port) -join "`n"; $ec = $LASTEXITCODE
  Check 'no irdash answering: a plain sentence and exit code 1' (($o -match 'irdash did not answer') -and ($ec -eq 1))
} finally {
  if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
''; "$pass ok, $fail FAIL"
if ($fail -gt 0) { exit 1 }
