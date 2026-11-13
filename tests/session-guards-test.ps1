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
    # the Stream Deck add-on: a local file page, Origin "null". With its secret as X-Paddock (the installed new add-on) and without (today's).
    $secret = -join ((1..16) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) })
    function AddonPage($run) { Set-Content (Join-Path $tmp "addon$run.html") -Encoding UTF8 -Value @"
<pre id="out">waiting</pre><script>$done
(async () => { const r = [];
  try { const a = await fetch('http://localhost:8299/api/do?c=addonhdr$run', { cache: 'no-store', headers: { 'X-Paddock': '$secret' } }); r.push('addonhdr$run ' + a.status); } catch (e) { r.push('addonhdr$run failed ' + e.name); }
  try { const b = await fetch('http://localhost:8299/api/do?c=addonplain$run', { cache: 'no-store' }); r.push('addonplain$run ' + b.status); } catch (e) { r.push('addonplain$run failed ' + e.name); }
  __done(r); })();</script>
"@ }
    AddonPage 'A'; AddonPage 'B'
    # any web page that hides in a sandboxed iframe (Origin "null") and sends X-Paddock: 1 itself, and one with no header at all
    $inner = "<script>fetch('http://localhost:8299/api/do?c=sbxhdr', { headers: { 'X-Paddock': '1' } }).catch(() => 0); fetch('http://localhost:8299/api/do?c=sbxplain').catch(() => 0);</script>"
    Set-Content (Join-Path $tmp 'sandbox.html') -Encoding UTF8 -Value ('<pre id="out">sandbox</pre><iframe sandbox="allow-scripts" srcdoc="' + $inner.Replace('"', '&quot;') + '"></iframe>')
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
    # run A: no secret in force yet (dash\deck-secret.txt missing): the transition, everything from the add-on works
    $a = Dump ('file:///' + ((Join-Path $tmp 'addonA.html') -replace '\\', '/'))
    $t = Dump 'http://localhost:8299/top.html'
    $e = Dump 'http://127.0.0.1:8298/evil.html'
    # run B: the secret is in force (the new add-on is installed)
    [IO.File]::WriteAllText((Join-Path $tmp 'deck-secret.txt'), $secret)
    $b2 = Dump ('file:///' + ((Join-Path $tmp 'addonB.html') -replace '\\', '/'))
    $sb = Dump 'http://127.0.0.1:8298/sandbox.html'
    Start-Sleep -Milliseconds 300
    $seen = if (Test-Path $log) { Get-Content $log -Raw } else { '' }
    Check 'the add-on WITH the header: the browser asks first (OPTIONS, Origin null) and gets a yes' ($seen -match 'OPTIONS /api/do\?c=addonhdrA origin=null -> 204')
    Check 'no secret in force yet: the add-on''s commands answer 200, with or without the header (the deck keeps working until Peter clicks Install)' ($a -match 'addonhdrA 200' -and $a -match 'addonplainA 200')
    Check 'secret in force: the add-on with its secret -> 200' ($b2 -match 'addonhdrB 200' -and $seen -match "GET c=addonhdrB origin=null site=\S* paddock=$secret -> 200")
    Check 'secret in force: Origin null without the secret -> 403' ($b2 -match 'addonplainB 403')
    Check 'secret in force: a web page in a sandboxed iframe sending X-Paddock: 1 itself passes the preflight but its command is REFUSED (403)' ($seen -match 'GET c=sbxhdr origin=null site=cross-site paddock=1 -> 403')
    Check 'secret in force: the sandboxed iframe''s plain fetch is REFUSED (403)' ($seen -match 'GET c=sbxplain origin=null site=cross-site paddock= -> 403')
    Check 'the top screen''s own page, no header: Chrome marks it same-origin -> 200' ($t -match 'topsame 200' -and $seen -match 'GET c=topsame origin= site=same-origin paddock= -> 200')
    Check 'a foreign page''s blind fetch reaches irdash marked cross-site and is REFUSED (403)' ($seen -match 'GET c=evilblind origin=\S* site=cross-site paddock= -> 403')
    Check 'a foreign page''s <img src=...api/do...> is REFUSED (403)' ($seen -match 'GET c=evilimg origin=\S* site=cross-site paddock= -> 403')
    Check 'a foreign page that adds the header itself is stopped at the preflight: the command never arrives' ($seen -match 'OPTIONS /api/do\?c=evilhdr origin=http://127\.0\.0\.1:8298 -> 403' -and $seen -notmatch 'GET c=evilhdr' -and $e -match 'evilhdr failed')
    if ($fail -gt 0) { '  server saw:'; $seen; '  pages:'; $a; $t; $e; $b2; $sb }
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
  Check 'phone: listens on the home network adapters only (default route or a gateway, never VPN or virtual: Gate.PhoneAdapter)' ($ph -match 'GetBestInterface' -and $ph -match 'if \(!Gate\.PhoneAdapter\(ni\.Name, ni\.Description, index >= 0 && index == best, HasGateway\(ip\)\)\) continue;')
  # W0-1 merged in: one helper (sendCmd) puts the 2 s timeout and X-Paddock: PADDOCK_SECRET on every command; cmd, the name draft, the doctor key and the CONFIRM screen use it
  Check 'the add-on sends its secret as X-Paddock with every command (cmd, the name draft, the doctor key, the CONFIRM screen)' (([regex]::Matches($pl, "\{ 'X-Paddock': PADDOCK_SECRET \}")).Count -eq 1 -and $pl -match "function sendCmd\(path\) \{\s*return fetchT\(API \+ path, 0, \{ 'X-Paddock': PADDOCK_SECRET \}\);" -and $pl -match "await sendCmd\(\(base \|\| '/api/do'\)" -and $pl -match "draft\(\) \{ sendCmd\('/api/guest/draft'" -and $pl -match "await sendCmd\('/api/do\?c=doctor'\)" -and $pl -match "const r = await sendCmd\('/api/do\?c=' \+ encodeURIComponent\(c\)" -and $pl -notmatch "fetchT\(API \+ '/api/" -and $pl -match "const PADDOCK_SECRET = '1';")
  $irdeck = (ReadSrc 'src\irdeck.cs') + (ReadSrc 'src\spot.cs') + (ReadSrc 'src\keymsg.cs') + (ReadSrc 'src\overlays.cs') + (ReadSrc 'src\official.cs')
  Check 'irdeck sends X-Paddock on every call to irdash that changes something (6)' (([regex]::Matches($irdeck, 'Headers\["X-Paddock"\] = "1"')).Count -eq 6)
  Check 'irdash''s own second-start call sends it too' ($ir -match 'wc\.Headers\["X-Paddock"\] = "1"; wc\.DownloadString\("http://localhost:" \+ cfg\.Port \+ "/api/open"\)')
  Check 'RACES and the recorder answer whether the Vault is on or off' ($va -match 'public static bool RecorderRoute\(string path\)' -and $va -match 'if \(!Serving && !RecorderRoute\(path\)' -and $va -match 'return \(Serving \|\| RecorderCommand\(c\)\)' -and $ir -match '!Vault\.Serving && !vaultTest && !Vault\.RecorderRoute\(path\)')
  $inst = ReadSrc 'deck-intro\install.ps1'
  Check 'install.ps1 puts a random secret into the installed plugin.html and (first time) into dash\deck-secret-new.txt, reusing the one in force' ($inst -match 'RNGCryptoServiceProvider' -and $inst -match "-replace `"const PADDOCK_SECRET = '\[\^'\]\*';`"" -and $inst -match 'deck-secret-new\.txt' -and $inst -match "foreach \(\`$f in 'deck-secret\.txt', 'deck-secret-new\.txt'\)")
  Check 'the secret files never go to git (*.txt is ignored)' ((git -C $root check-ignore dash/deck-secret.txt) -and (git -C $root check-ignore dash/deck-secret-new.txt))
  $deb = ReadSrc 'dash\src\debrief.cs'
  Check 'DEBRIEF OPEN IN COSWORTH waits for the session to end (not only for driving)' ($deb -match 'if \(!Handles\(c\) \|\| RigState\.SessionOn\) return false;')
  Check 'KEEP in a session says why: Vault.Do sets the sentence, /api/do answers 409 with it' ($va -match 'if \(st == "SESSION"\) Refused = RigState\.NotInSession;' -and $ir -match 'if \(!ok && Vault\.Refused != null\)')
  $www = (ReadSrc 'dash\www\v2\races.js') + (ReadSrc 'dash\www\v2\coach.js') + (ReadSrc 'dash\www\v2\debrief-v4.js') + (ReadSrc 'dash\www\v2\sessionreview.js') + (ReadSrc 'dash\www\phone\app.js')
  Check 'RACES, the coach, the debrief, the session review and the phone say "Not while a session is on" for KEEP' (([regex]::Matches($www, '(?i)not while a session is on')).Count -ge 7)
  Check 'the clip list follows the vault when it changes (a test''s clips do not stay)' ($re -match '(?s)public static void VaultRootChanged\(\).{0,400}LoadSessions\(\);\s+LoadClips\(\);')
  $app = ReadSrc 'dash\www\phone\app.js'
  Check 'the phone app never puts the token in the address, a script cookie or localStorage, and sends X-Paddock: 1' ($app -notmatch "\?t=' \+" -and $app -notmatch 'document\.cookie' -and $app -notmatch "localStorage\.setItem\('pt'" -and $app -notmatch "q\.get\('t'\)" -and $app -match "const h = \{ 'X-Paddock': '1' \};")
  Check 'irdash re-writes an older phone''s cookie as HttpOnly' ($ph -match 'if \(ck != null && TokenOk\(null, hdr\)\) extra \+= "Set-Cookie: pt=" \+ ck \+ "; Path=/; Max-Age=31536000; SameSite=Lax; HttpOnly')
  Check 'the phone listener says so (hourly) when no adapter is left' ($ph -match 'if \(Allowed && want\.Count == 0\) RigState\.LogEvery\("phone-no-lan"' -and $ph -match 'Gate\.PhoneAdapter\(ni\.Name, ni\.Description')
  # the phone's in-session list = its own buttons (app.js KEYS) that are deck keys, in the pit / chat / volume / black-box groups plus the in-car helpers
  $keys = @([regex]::Matches($app, "\['(car|ses|pit|talk|vol|box|pc)', '([a-z0-9-]+)'") | ForEach-Object { @{ g = $_.Groups[1].Value; k = $_.Groups[2].Value } })
  $kmPath = @((Join-Path $root 'keys\keys.map'), 'C:\Users\peter\iRacingDeck\keys\keys.map') | Where-Object { Test-Path $_ } | Select-Object -First 1
  $deckKeys = if ($kmPath) { @(Get-Content $kmPath | ForEach-Object { ($_ -split '=')[0].Trim() }) } else { @() }
  $inCar = 'get-out', 'tow', 'spot-save', 'spot-back'
  $want = @($keys | Where-Object { ($_.g -in 'pit', 'talk', 'vol', 'box') -or ($_.g -eq 'ses' -and $_.k -in $inCar) } | ForEach-Object { $_.k } | Sort-Object)
  $have = @(& $exe keys | Sort-Object)
  Check "the phone's in-session list is exactly its own pit, chat, volume, black-box and in-car buttons ($($want.Count))" ((Compare-Object $want $have).Count -eq 0) "want $($want -join ',') have $($have -join ',')"
  if ($kmPath) { $notDeck = @($have | Where-Object { $_ -notin $deckKeys }); Check "every one of them is a deck key in keys.map ($kmPath)" ($notDeck.Count -eq 0) ($notDeck -join ',') } else { '  skip  keys\keys.map not found (a worktree has no keys folder)' }
  Check 'the phone''s spot buttons send the deck''s key names (spot-save, spot-back; reset-save / reset-run are no deck keys)' ($app -match "\['ses', 'spot-save'" -and $app -match "\['ses', 'spot-back'" -and $app -notmatch 'reset-save|reset-run')
}
finally {
  if ($server) { try { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue } catch { } }
  Start-Sleep -Milliseconds 300
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
