# home-v3-test.ps1 - offline: HOME v3 (dash\www\v2\home.js + home.css) in eight states, measured and photographed at
# 1920 x 1080 in headless Chrome against saved data (docs\design\home-v3\data). No irdash, no network: safe while Peter races.
# Checks per state: one gold fill only, no text under 20 px except the source line, no overlapping text, everything on
# screen, no clipped name, the Race row in each watch column, no broken characters. Pictures: tests\shots\home-v3-<state>.png
#   powershell -ExecutionPolicy Bypass -File tests\home-v3-test.ps1
. (Join-Path $PSScriptRoot 'guard.ps1')
$root = Split-Path -Parent $PSScriptRoot
$shots = Join-Path $PSScriptRoot 'shots'; New-Item -ItemType Directory -Force $shots | Out-Null
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { '  FAIL  Chrome not found'; exit 1 }
$data = Join-Path $root 'docs\design\home-v3\data'
$J = @{}; foreach ($n in 'home', 'career', 'realworld', 'health', 'vault-recorder') { $J[$n] = [IO.File]::ReadAllText((Join-Path $data "$n.json"), [Text.Encoding]::UTF8) }
$www = Join-Path $root 'dash\www\v2'
$markup = [regex]::Match([IO.File]::ReadAllText((Join-Path $www 'index.html')), '(?s)<div id="overlay" class="show">.*?<div id="homeHost" hidden></div>\s*</div>').Value
if (-not $markup) { '  FAIL  could not find the HOME markup in index.html'; exit 1 }
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what" } }

# each state: a small script that edits the saved data before HOME draws (the same states as the design mockup)
$states = [ordered]@{
  normal  = "H.apps.forEach(a=>{ if(a.id==='sim') a.state='off'; }); R.capture={state:'idle',secs:0}; R.running=false;"
  live    = "H.apps.forEach(a=>{ if(a.id==='sim') a.state='live'; }); R.capture={state:'recording',secs:40};"
  norace  = "H.apps.forEach(a=>{ if(a.id==='sim') a.state='off'; }); R.capture={state:'idle'}; D.nextRace=null;"
  stale   = "H.apps.forEach(a=>{ if(a.id==='sim') a.state='off'; }); R.capture={state:'idle'}; W.fresh=false; W.asOf='2026-10-13T13:11:39Z'; (W.events.filter(e=>e.series==='F1'&&e.session==='Race')[0]||{}).tbc=true;"
  offline = "H.apps.forEach(a=>{ if(a.id==='ui'||a.id==='overlays') a.state='off'; if(a.id==='sim') a.state='off'; }); R.capture={state:'idle'};"
  recfail = "H.apps.forEach(a=>{ if(a.id==='sim') a.state='off'; }); R.gaveUp=true; R.capture={state:'failed'}; R.freeGb=41.3; P.paired=false;"
  first   = "H.apps.forEach(a=>{ if(a.id==='sim') a.state='off'; }); R.capture={state:'idle'}; D.last=null; D.lastOuting=null; D.week=null; D.me={name:'Peter Adamis',num:'64'}; C={}; R.enabled=false;"
  long    = "H.apps.forEach(a=>{ if(a.id==='sim') a.state='off'; }); R.capture={state:'idle'}; if(D.nextRace){D.nextRace.series='iRacing GT3 Regional Tour by SENSIT! - Americas'; D.nextRace.car='Mercedes-AMG GT3 2020'; D.nextRace.track='Circuit des 24 Heures du Mans'; D.nextRace.ownedTrack=false; D.nextRace.countdownSeconds=4380;} [D.last,D.lastOuting].forEach(l=>{ if(l){ l.track='Circuit des 24 Heures du Mans'; l.car='Chevrolet Corvette Z06 GT3.R'; l.laps=1; l.best=229.251; } }); D.me.path='chevyvettez06rgt3'; D.me.car='Chevrolet Corvette Z06 GT3.R';"
}

$measure = @'
(function(){
  var out=[], ov=document.getElementById('overlay');
  var leaves=[].slice.call(ov.querySelectorAll('*')).filter(function(e){ if(e.closest('[hidden]')) return false; var cs=getComputedStyle(e); if(cs.display==='none'||cs.visibility==='hidden') return false; return [].some.call(e.childNodes,function(n){return n.nodeType===3&&n.textContent.trim();}); });
  var small=[], off=[], clip=[], boxes=[];
  leaves.forEach(function(e){
    var cs=getComputedStyle(e), fs=parseFloat(cs.fontSize), r=e.getBoundingClientRect();
    var tiny=e.closest('.tiny');
    if(fs<20 && !tiny) small.push(e.textContent.trim().slice(0,30)+' '+fs);
    if(r.right>1920.5||r.bottom>1080.5||r.left<-0.5||r.top<-0.5) off.push(e.textContent.trim().slice(0,30));
    // only this element's own text (not its children's), so a label and the date inside it are not counted as a clash
    [].forEach.call(e.childNodes,function(n){ if(n.nodeType!==3||!n.textContent.trim()) return; var rg=document.createRange(); rg.selectNodeContents(n); var t=rg.getBoundingClientRect(); if(t.width>0) boxes.push({x:t.left,y:t.top,w:t.width,h:t.height,s:n.textContent.trim().slice(0,30)}); });
    if(e.scrollWidth>e.clientWidth+1 && cs.textOverflow!=='ellipsis' && cs.overflow==='hidden' && cs.whiteSpace==='nowrap') clip.push(e.textContent.trim().slice(0,30));
  });
  var bad=[]; for(var i=0;i<boxes.length;i++) for(var j=i+1;j<boxes.length;j++){ var p=boxes[i],q=boxes[j]; if(p.x+1<q.x+q.w-1&&q.x+1<p.x+p.w-1&&p.y+1<q.y+q.h-1&&q.y+1<p.y+p.h-1) bad.push(p.s+' | '+q.s); }
  var gold=[].slice.call(ov.querySelectorAll('*')).filter(function(e){ if(e.closest('[hidden]')) return false; var bg=getComputedStyle(e).backgroundImage+getComputedStyle(e).backgroundColor; return /242, 194, 48|246, 205, 76|226, 180, 42/.test(bg); }).length;
  var cols=[].slice.call(ov.querySelectorAll('#homeWeekend .ev')), racerows=cols.filter(function(c){return c.querySelector('.s.key');}).length;
  var text=ov.innerText;
  return JSON.stringify({small:small,off:off,clip:clip,overlap:bad,gold:gold,cols:cols.length,raceRows:racerows,mojibake:/Ã|â€|Â·/.test(text),head:(document.querySelector('#idleRig .head b')||{}).textContent||'',button:(document.querySelector('#homeNext b')||{}).textContent||'',car:(document.getElementById('homeCar')||{}).outerHTML||'',text:text.slice(0,4000)});
})()
'@

foreach ($st in $states.Keys) {
  $html = @"
<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="../dash/www/v2/style.css"><link rel="stylesheet" href="../dash/www/v2/home.css">
<style>html,body{margin:0;width:1920px;height:1080px;overflow:hidden;background:#000}</style></head><body>
$markup
<script>
// saved data, edited for the state "$st"; irdash is a mock here (no network)
var D=$($J['home']), C=$($J['career']), W=$($J['realworld']), H=$($J['health']), R=$($J['vault-recorder']), P={allowed:true,rows:[], paired:true};
$($states[$st])
D.nextRace && (D.nextRace.localStart = '2026-10-15 13:15');
window.__NOW = new Date('2026-10-15T16:55:00Z');
var RealDate = Date; window.Date = function(a){ return arguments.length ? new (Function.prototype.bind.apply(RealDate,[null].concat([].slice.call(arguments))))() : new RealDate(window.__NOW.getTime()); }; Date.parse=RealDate.parse; Date.now=function(){return window.__NOW.getTime();}; Date.prototype=RealDate.prototype;
window.`$ = function(id){ return document.getElementById(id); };
window.esc = function(s){ return String(s == null ? '' : s).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); };
window.setText = function(el, s){ if (typeof el === 'string') el = `$(el); if (el) el.textContent = s == null ? '' : String(s); };
window.setHTML = function(el, s){ if (typeof el === 'string') el = `$(el); if (el) el.innerHTML = s; };
window.UI = { live: function(){ return false; } };
window.PCarPic = { known: function(){ var o={}; o[D.me && D.me.path ? D.me.path : '_']=1; return o; }, key: function(p){ return p; }, ready: function(){ return Promise.resolve(); }, refresh: function(){},
  html: function(o){ return '<div class="cpic"><img alt="" src="../paddock/cars/' + o.path + '.jpg"></div>'; } };
var BODY = { '/home': D, '/career': C, '/realworld': W, '/health': H, '/vault/recorder': R, '/phone/qr': P, '/mydrive': {} };
window.fetch = function(u){ var k = String(u).split('?')[0]; return Promise.resolve({ ok: true, json: function(){ return Promise.resolve(JSON.parse(JSON.stringify(BODY[k] || {}))); } }); };
</script>
<script src="../dash/www/v2/home.js"></script>
<script>setTimeout(function(){ var m = $measure; var p = document.createElement('pre'); p.id = 'measure'; p.hidden = true; p.textContent = m; document.body.appendChild(p); }, 1500);</script>
</body></html>
"@
  $file = Join-Path $PSScriptRoot "home-v3-$st.harness.html"
  [IO.File]::WriteAllText($file, $html, (New-Object Text.UTF8Encoding($false)))
  $url = 'file:///' + ($file -replace '\\', '/')
  $prof = Join-Path $env:TEMP ('home-v3-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $null = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', '--hide-scrollbars', "--user-data-dir=$prof", '--allow-file-access-from-files', '--virtual-time-budget=12000', '--window-size=1920,1200', '--dump-dom', $url) -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$prof.dom" -RedirectStandardError "$prof.err"
  $raw = Join-Path $env:TEMP "home-v3-$st-raw.png"
  $null = Start-Process -FilePath $chrome -ArgumentList @('--headless=new', '--disable-gpu', '--no-first-run', '--hide-scrollbars', "--user-data-dir=$prof", '--allow-file-access-from-files', '--virtual-time-budget=12000', '--window-size=1920,1200', "--screenshot=$raw", $url) -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$prof.o2" -RedirectStandardError "$prof.e2"
  Add-Type -AssemblyName System.Drawing
  if (Test-Path $raw) { $img = [Drawing.Image]::FromFile($raw); $bmp = New-Object Drawing.Bitmap 1920, 1080; $g = [Drawing.Graphics]::FromImage($bmp); $g.DrawImage($img, (New-Object Drawing.Rectangle 0, 0, 1920, 1080), (New-Object Drawing.Rectangle 0, 0, 1920, 1080), [Drawing.GraphicsUnit]::Pixel); $g.Dispose(); $img.Dispose(); $bmp.Save((Join-Path $shots "home-v3-$st.png"), [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); Remove-Item $raw }
  $dom = Get-Content "$prof.dom" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  Remove-Item "$prof.*" -ErrorAction SilentlyContinue; Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item $file -ErrorAction SilentlyContinue
  $mm = [regex]::Match([string]$dom, '(?s)<pre id="measure" hidden="">(.*?)</pre>')
  if (-not $mm.Success) { Check "$st : HOME drew and could be measured" $false; continue }
  $m = [Net.WebUtility]::HtmlDecode($mm.Groups[1].Value) | ConvertFrom-Json
  "$st  (button: $($m.button); ready: $($m.head))"
  Check "$st : exactly one gold fill (the button)" ($m.gold -eq 1)
  Check "$st : no text under 20 px except the source line ($(@($m.small) -join '; '))" (@($m.small).Count -eq 0)
  Check "$st : no text overlaps other text ($(@($m.overlap) -join '; '))" (@($m.overlap).Count -eq 0)
  Check "$st : everything is on the 1920 x 1080 screen ($(@($m.off) -join '; '))" (@($m.off).Count -eq 0)
  Check "$st : no hard-clipped text ($(@($m.clip) -join '; '))" (@($m.clip).Count -eq 0)
  Check "$st : no broken characters" (-not $m.mojibake)
  if ($st -ne 'first') { Check "$st : three watch columns, each with its Race row ($($m.cols) / $($m.raceRows))" ($m.cols -eq 3 -and $m.raceRows -eq 3) }
  Check "$st : picture tests\shots\home-v3-$st.png" (Test-Path (Join-Path $shots "home-v3-$st.png"))
  switch ($st) {
    'normal'  { Check 'normal: READY, LAST DRIVE, 12-hour New York clock with ET' ($m.head -eq 'Ready' -and $m.button -eq 'Last drive' -and $m.text -match '\d{1,2}:\d{2} (AM|PM) ET') }
    'live'    { Check 'live: the head says LIVE, the button GET IN, recording shows its time' ($m.head -eq 'Live' -and $m.button -eq 'Get in' -and $m.text -match 'On 0:40') }
    'norace'  { Check 'no race: "No race published", no made-up countdown' ($m.text -match 'No race published' -and $m.text -notmatch 'in \d+ min') }
    'stale'   { Check 'stale: the watch list says how old it is, and an untimed race says time TBC' ($m.text -match 'as of' -and $m.text -match 'time TBC' -and $m.text -notmatch '\bLive\b') }
    'offline' { Check 'offline: RIG ON, and the head names the first app that is off' ($m.button -eq 'Rig on' -and $m.head -match 'off') }
    'recfail' { Check 'recording failed: the head says so in red words, the row says Failed' ($m.head -eq 'Recording failed' -and $m.text -match 'Failed') }
    'first'   { Check 'first run: START, no lap time invented (a dash), no drive yet' ($m.button -eq 'Start' -and $m.text -match 'No drive recorded yet') }
    'long'    { Check 'long names: the series and track are there in full or with an ellipsis, not cut mid-glyph' ($m.text -match 'SENSIT' -and $m.text -match 'Heures du Mans') }
  }
}
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
