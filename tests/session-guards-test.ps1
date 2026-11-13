# session-guards-test.ps1 (W0-2) - nothing that clicks in iRacing, restarts an app or moves/deletes files runs while a session is on;
# a paired phone keeps only its in-session buttons; a route that changes something needs X-Paddock: 1, so a web page's blind
# fetch('http://localhost:8199/api/do?c=...') is refused. OFFLINE:
#   1-7  dash\src\rigstate.cs compiled alone with tests\session-guards-unit.cs: the rules with a pretend session on and off
#   8    a real browser (headless Chrome) against a pretend irdash on port 8299 that answers with the SAME Gate functions: the add-on's
#        page (file://, Origin null) with the header, the top screen's same-origin fetch, and a foreign site's blind fetch, image and
#        header fetch. Nothing reaches the real irdash (8199).
#   9    irdash.cs, phone.cs, vault.cs, recorder.cs, doctor.cs, plugin.html and irdeck are wired to those rules (source).
#   powershell -ExecutionPolicy Bypass -File tests\session-guards-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { }
$root = Split-Path -Parent $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$tmp = Join-Path $env:TEMP "session-guards-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }
$server = $null
try {
  '0. build'
  $exe = Join-Path $tmp 'guards.exe'
  $out = & $csc /nologo /target:exe "/out:$exe" /r:System.dll /r:System.Core.dll (Join-Path $root 'dash\src\rigstate.cs') (Join-Path $PSScriptRoot 'session-guards-unit.cs') 2>&1
  Check 'rigstate.cs + the test harness compile' ((Test-Path $exe) -and -not ($out | Where-Object { $_ -match 'error' }))
  if (-not (Test-Path $exe)) { $out; throw 'no build' }
  foreach ($l in (& $exe unit)) { if ($l -match '^\s+ok\s') { $script:pass++; $l } elseif ($l -match '^\s+FAIL\s') { $script:fail++; $l } elseif ($l -notmatch 'passed, .* failed') { $l } }

  ''; '8. a real browser against the same rules (pretend irdash on 8299, a "foreign" site on 8298)'
  $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  $busy = @(Get-NetTCPConnection -State Listen -LocalPort 8298, 8299 -ErrorAction SilentlyContinue)
  if (-not $chrome) { Check 'Chrome found' $false }
  elseif ($busy.Count -gt 0) { Check 'ports 8298 / 8299 are free for the pretend irdash (another test is using them: run again later)' $false }
  else {
    $log = Join-Path $tmp 'server.log'
    $done = "window.__done = (r) => { document.getElementById('out').textContent = r.join('\n'); };"
    # the Stream Deck add-on: a local file page, Origin "null". With the header (after Peter installs the new add-on) and without (before).
    Set-Content (Join-Path $tmp 'addon.html') -Encoding UTF8 -Value @"
<pre id="out">waiting</pre><script>$done
(async () => { const r = [];
  try { const a = await fetch('http://localhost:8299/api/do?c=addonhdr', { cache: 'no-store', headers: { 'X-Paddock': '1' } }); r.push('addonhdr ' + a.status); } catch (e) { r.push('addonhdr failed ' + e.name); }
  try { const b = await fetch('http://localhost:8299/api/do?c=addonplain', { cache: 'no-store' }); r.push('addonplain ' + b.status); } catch (e) { r.push('addonplain failed ' + e.name); }
  __done(r); })();</script>
"@
    # the top screen: a page irdash serves itself, fetching a command with no header (Chrome marks it same-origin)
    Set-Content (Join-Path $tmp 'top.html') -Encoding UTF8 -Value @"
<pre id="out">waiting</pre><script>$done
(async () => { const r = [];
  try { const a = await fetch('/api/do?c=topsame', { cache: 'no-store' }); r.push('topsame ' + a.status); } catch (e) { r.push('topsame failed ' + e.name); }
  __done(r); })();</script>
"@
    # any other web page: a blind no-cors fetch, an image, and a fetch that tries to send the header itself
    Set-Content (Join-Path $tmp 'evil.html') -Encoding UTF8 -Value @"
<pre id="out">waiting</pre><script>$done
(async () => { const r = [];
  try { await fetch('http://localhost:8299/api/do?c=evilblind', { mode: 'no-cors', cache: 'no-store' }); r.push('evilblind sent'); } catch (e) { r.push('evilblind failed ' + e.name); }
  await new Promise(res => { const i = new Image(); i.onload = i.onerror = () => res(); i.src = 'http://localhost:8299/api/do?c=evilimg'; });
  try { const c = await fetch('http://localhost:8299/api/do?c=evilhdr', { cache: 'no-store', headers: { 'X-Paddock': '1' } }); r.push('evilhdr ' + c.status); } catch (e) { r.push('evilhdr failed ' + e.name); }
  __done(r); })();</script>
"@
    $server = Start-Process -FilePath $exe -ArgumentList @('serve', "`"$tmp`"", '60', "`"$log`"") -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 50 -and -not ((Test-Path $log) -and ((Get-Content $log -Raw) -match 'ready')); $i++) { Start-Sleep -Milliseconds 100 }
    function Dump($url) {
      $prof = Join-Path $tmp ('chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
      $dump = Join-Path $tmp ('dom-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
      $null = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', "--user-data-dir=$prof", '--virtual-time-budget=8000', '--dump-dom', $url) -NoNewWindow -PassThru -RedirectStandardOutput $dump -RedirectStandardError ($dump + '.err') -Wait
      if (Test-Path $dump) { return (Get-Content $dump -Raw) }; return ''
    }
    $a = Dump ('file:///' + ((Join-Path $tmp 'addon.html') -replace '\\', '/'))
    $t = Dump 'http://localhost:8299/top.html'
    $e = Dump 'http://127.0.0.1:8298/evil.html'
    Start-Sleep -Milliseconds 300
    $seen = if (Test-Path $log) { Get-Content $log -Raw } else { '' }
    Check 'the add-on WITH the header: the browser asks first (OPTIONS, Origin null) and gets a yes' ($seen -match 'OPTIONS /api/do\?c=addonhdr origin=null -> 204')
    Check '... and then its command answers 200' ($a -match 'addonhdr 200' -and $seen -match 'GET c=addonhdr origin=null site=\S* paddock=1 -> 200')
    Check 'the add-on as installed today (no header yet): still 200, so the deck keeps working until Peter clicks Install' ($a -match 'addonplain 200')
    Check 'the top screen''s own page, no header: Chrome marks it same-origin -> 200' ($t -match 'topsame 200' -and $seen -match 'GET c=topsame origin= site=same-origin paddock= -> 200')
    Check 'a foreign page''s blind fetch reaches irdash marked cross-site and is REFUSED (403)' ($seen -match 'GET c=evilblind origin=\S* site=cross-site paddock= -> 403')
    Check 'a foreign page''s <img src=...api/do...> is REFUSED (403)' ($seen -match 'GET c=evilimg origin=\S* site=cross-site paddock= -> 403')
    Check 'a foreign page that adds the header itself is stopped at the preflight: the command never arrives' ($seen -match 'OPTIONS /api/do\?c=evilhdr origin=http://127\.0\.0\.1:8298 -> 403' -and $seen -notmatch 'GET c=evilhdr' -and $e -match 'evilhdr failed')
    if ($fail -gt 0) { '  server saw:'; $seen; '  pages:'; $a; $t; $e }
  }

  ''; '9. wired into irdash, the phone, the Vault, the recorder, the add-on and irdeck (source)'
  function ReadSrc($p) { [IO.File]::ReadAllText((Join-Path $root $p)) }
  $ir = ReadSrc 'dash\src\irdash.cs'; $ph = ReadSrc 'dash\src\phone.cs'; $va = ReadSrc 'dash\src\vault.cs'; $re = ReadSrc 'dash\src\recorder.cs'; $dr = ReadSrc 'dash\src\doctor.cs'; $pl = ReadSrc 'deck-intro\plugin.html'
  Check 'irdash answers OPTIONS with Gate.PreflightOk' ($ir -match 'if \(method == "OPTIONS"\)' -and $ir -match 'Gate\.PreflightOk\(hdr, port\)')
  Check 'irdash refuses a changing route without the header (403), before any route runs' ($ir -match 'if \(Gate\.ChangesState\(method, path\)\)' -and $ir -match 'Gate\.HeaderRefusal\(hdr, !asPhone, port\)' -and $ir.IndexOf('Gate.ChangesState(method, path)') -lt $ir.IndexOf('path == "/api/do"'))
  Check 'irdash answers the guarded routes 409 with the sentence' ($ir -match 'string sg = Gate\.GuardRoute\(path, ParseQuery\(query\)\);' -and $ir -match 'Send\(s, 409, "application/json; charset=utf-8", Encoding\.UTF8\.GetBytes\("\{\\"error\\":" \+ Json\.Str\(sg\)')
  Check '/api/do: guarded commands and the phone''s in-session list answer 409, and the top screen says why (KeyMsg)' ($ir -match 'string dg = Gate\.GuardDo\(dc, da\);' -and $ir -match 'asPhone && RigState\.SessionOn && !Gate\.PhoneMayWhileSession\(dc, da\)' -and $ir -match 'KeyMsg\.Set\([^;]*dg, "no"\); Send\(s, 409')
  Check 'the LAN gate is an allow-list (Gate.PhonePath), the deny-list stays as a second wall' ($ir -match 'if \(!Gate\.PhonePath\(path\) \|\| Phone\.Hidden\(path, method\)\)')
  Check 'the Stream Deck restart stays allowed in a session, logged as such' (([regex]::Matches($ir, 'Stream Deck restarted during a session')).Count -ge 2)
  Check 'the Rig Doctor shows its last result instead of running (and its timer waits) while a session is on' ($dr -match 'if \(RigState\.SessionOn\) \{ RigState\.Refuse\("Rig Doctor check' -and $dr -match 'if \(RigState\.SessionOn\) return;')
  Check 'Recorder.Save refuses the big move of a FINISHED session in a session (SESSION), the open session''s SAVE is a note' ($re -match 'if \(RigState\.SessionOn\) \{ RigState\.Refuse\("SAVE of finished session " \+ s\.Id\); recState = "SESSION"; return "SESSION"; \}')
  Check 'phone: the token from the header or the cookie only (no ?t=)' ($ph -notmatch 'q\.TryGetValue\("t", out tok\)')
  Check 'phone: the cookie is HttpOnly' ($ph -match 'SameSite=Lax; HttpOnly')
  Check 'phone: 8 wrong codes lock pairing for 60 s' ($ph -match 'lockedUntil = DateTime\.UtcNow\.AddSeconds\(60\)' -and $ph -match 'if \(DateTime\.UtcNow < lockedUntil\)')
  Check 'phone: forget-every-phone only from this PC' ($ph -match 'if \(q\.ContainsKey\("all"\) && !local\) \{ code = 403;')
  Check 'phone: listens on the default-route adapter only' ($ph -match 'GetBestInterface' -and $ph -match 'if \(best >= 0 \? index != best : !HasGateway\(ip\)\) continue;')
  Check 'the add-on sends X-Paddock with every command (cmd, the name draft, the doctor key)' (([regex]::Matches($pl, "headers: \{ 'X-Paddock': '1' \}")).Count -eq 3)
  $irdeck = (ReadSrc 'src\irdeck.cs') + (ReadSrc 'src\spot.cs') + (ReadSrc 'src\keymsg.cs') + (ReadSrc 'src\overlays.cs') + (ReadSrc 'src\official.cs')
  Check 'irdeck sends X-Paddock on every call to irdash that changes something (6)' (([regex]::Matches($irdeck, 'Headers\["X-Paddock"\] = "1"')).Count -eq 6)
  Check 'irdash''s own second-start call sends it too' ($ir -match 'wc\.Headers\["X-Paddock"\] = "1"; wc\.DownloadString\("http://localhost:" \+ cfg\.Port \+ "/api/open"\)')
  Check 'RACES and the recorder answer whether the Vault is on or off' ($va -match 'public static bool RecorderRoute\(string path\)' -and $va -match 'if \(!Serving && !RecorderRoute\(path\)' -and $va -match 'return \(Serving \|\| RecorderCommand\(c\)\)' -and $ir -match '!Vault\.Serving && !vaultTest && !Vault\.RecorderRoute\(path\)')
}
finally {
  if ($server) { try { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue } catch { } }
  Start-Sleep -Milliseconds 300
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
