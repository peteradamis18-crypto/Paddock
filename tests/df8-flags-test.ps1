# df8-flags-test.ps1 - the real tools\df8-flags.js, run in headless Edge with pretend flags (offline: touches no live app, safe while
# Peter races). The lights must follow iRacing's bits exactly and agree with Paddock's flag panel (dash\www\v2\ui.js).
#   powershell -ExecutionPolicy Bypass -File tests\df8-flags-test.ps1
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check($what, $ok, $detail = '') { if ($ok) { $script:pass++; "  ok    $what" } else { $script:fail++; "  FAIL  $what"; if ($detail) { "        $detail" } } }
$js = [IO.File]::ReadAllText((Join-Path $root 'tools\df8-flags.js')); $ui = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\ui.js'))
function Table($s) { $m = [regex]::Match($s, '(?s)FLAG TABLE START[^\r\n]*\r?\n(.*?)//\s*FLAG TABLE END'); (($m.Groups[1].Value -split '\r?\n') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n" }
$a = Table $js; $b = Table $ui
Check 'the lights and Paddock use the very same flag table' ($a.Length -gt 50 -and $a -ceq $b) "lights: $a`npaddock: $b"
$dir = Join-Path $env:TEMP ('df8test-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $dir | Out-Null
$src = ConvertTo-Json $js
$uiSrc = ConvertTo-Json ([regex]::Match($ui, '(?s)  flags\(f\) \{.*?\n  \},').Value)
$html = @"
<!doctype html><meta charset=utf-8><pre id=r></pre><script>
const SRC=$src; const UISRC=$uiSrc; const realNow=Date.now; const T=1000000000000; const R={};
const RAW='DataCorePlugin.GameRawData.Telemetry.SessionFlags';
function colours(p,t){ Date.now=()=>t; try { return new Function('`$prop',SRC)(k=>k in p?p[k]:null); } finally { Date.now=realNow; } }
function lit(p,t){ return colours(p,t).filter(c=>c!=='#FF000000').length; }
function reset(){ globalThis.__ssgFlags=undefined; }
const bits=b=>({[RAW]:b});
// the flag held on: most lights seen in the 1 s around that moment (strobes go dark every other frame)
function peak(p,from,to){ reset(); let m=0; for(let ms=0;ms<=to;ms+=100){ const n=lit(p,T+ms); if(ms>=from&&n>m)m=n; } return m; }
const FL={checkered:0x1,white:0x2,green:0x4,yellow:0x8,red:0x10,blue:0x20,debris:0x40,waving:0x100,caution:0x4000,black:0x10000,repair:0x100000};
for(const k in FL){ R[k+'_start']=peak(bits(FL[k]),0,1000); R[k+'_60s']=peak(bits(FL[k]),60000,61000); }
// green ends when iRacing ends it: 44 s on, then dark at once (past the 3 s minimum)
reset(); for(let ms=0;ms<=44000;ms+=100) lit(bits(4),T+ms); R.green_at44=lit(bits(4),T+44000); R.green_after=lit(bits(0),T+44100);
// the real blue from his race: 1.1 s. Still on the box at 2.5 s, gone by 3.1 s.
reset(); for(let ms=0;ms<=1100;ms+=100) lit(bits(0x20),T+ms); R.blue_25=lit(bits(0),T+2500); R.blue_31=lit(bits(0),T+3100);
// the bits iRacing sets around a start are not flags: nothing before the green bit
reset(); R.before_green=lit(bits(0x20040600|0),T);
// blue on top of green (his race, 224.7 s) shows blue
reset(); for(let ms=0;ms<=9000;ms+=100) lit(bits(4),T+ms); R.blue_over_green=colours(bits(0x24),T+9100).filter(c=>c==='#FF0050FF').length;
// a blue over green at 13 s: green comes back steady, it does not flash again (lit on two frames in a row)
reset(); for(let ms=0;ms<=13000;ms+=100) lit(bits(4),T+ms); for(let ms=13100;ms<=14200;ms+=100) lit(bits(0x24),T+ms); for(let ms=14300;ms<=17200;ms+=100) lit(bits(4),T+ms); R.green_back=Math.min(lit(bits(4),T+17300),lit(bits(4),T+17400),lit(bits(4),T+17500));
// the high start bit (0x80000000) arrives as a big number: green still seen
reset(); R.big=Math.max(lit(bits(0x80000004),T),lit(bits(0x80000004),T+200));
// written as names
reset(); R.names=Math.max(lit({[RAW]:'green, servicible'},T),lit({[RAW]:'green, servicible'},T+200));
// raw value missing: SimHub's own signals keep the box working
reset(); R.fallback=peak({Flag_Blue:1},0,500);
reset(); R.fallback2=peak({'DataCorePlugin.GameRawData.Telemetry.SessionFlagsDetails.IsBlue':1},0,500);
reset(); R.fallback3=peak({'GameRawData.Telemetry.SessionFlagsDetails.IsBlue':1},0,500);
reset(); lit({},T); R.none=lit(bits(0),T+100);
reset(); R.pit=lit({[RAW]:0,PitLimiterOn:1},T); reset(); R.spot=lit({[RAW]:0,SpotterCarLeft:1},T);
reset(); R.white_again=(()=>{ for(let ms=0;ms<=10000;ms+=100) lit(bits(2),T+ms); for(let ms=10100;ms<=20000;ms+=100) lit(bits(0),T+ms); let m=0; for(let ms=30000;ms<=31000;ms+=100) m=Math.max(m,lit(bits(2),T+ms)); return m; })();
// Paddock's panel and the box name the same flag for every flag bit and every pair
const isRace=()=>true; const box={ flags:null, setFlag(c,t){ this.c=c; this.t=t; } };
box.flags=new Function('f','isRace',UISRC.replace(/^\s*flags\(f\) \{/,'').replace(/\},\s*$/,'')).bind(box);
const MAP={black:'black',meatball:'orange',checkered:'checkered',red:'red',yellow:'yellow',blue:'blue',white:'white',green:'green','':''};
const list=Object.values(FL).concat([0x20000,0x8000,0x80000,0x200,0x400]); let bad=[];
for(const x of list) for(const y of list){ const f=x|y; reset(); box.flagSt=null; box.flags(f,isRace);
  const c=colours(bits(f),T); const name=(globalThis.__ssgFlags||{}).cur; const want=box.t==='Warning'?'warning':MAP[box.c]; if(want!==name) bad.push(f.toString(16)+':'+box.c+'/'+name); }
R.disagree=bad.slice(0,8).join(' '); R.pairs=list.length*list.length;
// Peter's real race, 2026-11-02 10:50 Laguna (the .ibt's own bit changes): lights and panel frame by frame at the box's 10 frames a second
const REAL=[[153.22,0x20040600],[170.02,0x80040604],[170.12,0x80040004],[175.02,0x10040004],[182.42,0x10040024],[184.22,0x10040004],[214.12,0x10040000],[817.30,0x10040002],[908.77,0x10040001],[1029.25,0x100C0001],[1032.98,0x10040001],[1044.45,0x10040201]];
reset(); box.flagSt=null; let spans=[], realBad=0;
for(let ms=153300;ms<=1067000;ms+=100){ let f=0; for(const [s,b] of REAL) if(s*1000<=ms) f=b;
  const t=T+ms; colours(bits(f),t); const name=globalThis.__ssgFlags.cur; Date.now=()=>t; try { box.flags(f,isRace); } finally { Date.now=realNow; }
  if((box.flagName||'')!==name) realBad++;
  if(!spans.length||spans[spans.length-1][0]!==name) spans.push([name,ms/1000]); }
R.realBad=realBad; R.realSpans=spans.map(s=>(s[0]||'dark')+'@'+s[1].toFixed(1)).join(' ');
document.getElementById('r').textContent=JSON.stringify(R);
</script>
"@
[IO.File]::WriteAllText("$dir\t.html", $html)
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$pr = Start-Process $edge -ArgumentList '--headless', '--disable-gpu', "--user-data-dir=$dir\e", '--virtual-time-budget=5000', '--dump-dom', ("file:///" + ($dir -replace '\\', '/') + "/t.html") -RedirectStandardOutput "$dir\o.txt" -PassThru -WindowStyle Hidden
$null = $pr.WaitForExit(30000); if (-not $pr.HasExited) { $pr.Kill() }
$m = [regex]::Match((Get-Content "$dir\o.txt" -Raw), '<pre id="r">(.*?)</pre>')
Check 'the script ran' $m.Success
if ($m.Success) {
  $r = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) | ConvertFrom-Json
  foreach ($k in 'yellow', 'blue', 'white', 'green', 'red', 'debris', 'waving', 'caution', 'repair') { Check "$k fills the box at the start ($($r."${k}_start") lights)" ($r."${k}_start" -ge 48) }
  Check "black is big at the start ($($r.black_start))" ($r.black_start -ge 16)
  Check "chequered is big at the start ($($r.checkered_start))" ($r.checkered_start -ge 32)
  foreach ($k in 'yellow', 'blue', 'green', 'red', 'debris', 'waving', 'caution', 'repair') { Check "$k is still big after 60 s, no small marker ($($r."${k}_60s") lights)" ($r."${k}_60s" -ge 32) }
  Check "white is a full frame for the rest of the lap ($($r.white_60s) lights)" ($r.white_60s -eq 28)
  Check "black ($($r.black_60s)) and chequered ($($r.checkered_60s)) stay big until they end" ($r.black_60s -ge 16 -and $r.checkered_60s -ge 32)
  Check "green stays on for iRacing's whole 44 s ($($r.green_at44) lights), then goes dark at once ($($r.green_after))" ($r.green_at44 -eq 64 -and $r.green_after -eq 0)
  Check "the real 1.1 s blue is on the box at 2.5 s ($($r.blue_25)), gone by 3.1 s ($($r.blue_31))" ($r.blue_25 -ge 48 -and $r.blue_31 -eq 0)
  Check "one to green is dark, like Paddock ($($r.before_green))" ($r.before_green -eq 0)
  Check "blue on top of green shows blue ($($r.blue_over_green) blue lights)" ($r.blue_over_green -ge 48)
  Check "green comes back steady after a blue, no second flash ($($r.green_back) lights)" ($r.green_back -eq 64)
  Check "iRacing's top start bit does not break green ($($r.big))" ($r.big -eq 64)
  Check "the flags written as names also work ($($r.names))" ($r.names -eq 64)
  Check "raw value missing: SimHub's own signals still work ($($r.fallback))" ($r.fallback -ge 48)
  Check "raw value missing: SimHub's raw blue is read under both of its names ($($r.fallback2), $($r.fallback3))" ($r.fallback2 -ge 48 -and $r.fallback3 -ge 48)
  Check 'no flag = dark' ($r.none -eq 0)
  Check "pit limiter P ($($r.pit)), spotter column ($($r.spot))" ($r.pit -eq 24 -and $r.spot -eq 8)
  Check "a new white flag later on flashes again ($($r.white_again))" ($r.white_again -eq 64)
  Check "Paddock and the box name the same flag in all $($r.pairs) combinations" ($r.disagree -eq '') $r.disagree
  Check "his real race: lights and Paddock agree on every frame ($($r.realBad) differ)" ($r.realBad -eq 0)
  $wantSpans = 'dark@153.3 green@170.1 blue@182.5 green@185.5 dark@214.2 white@817.3 checkered@908.8 warning@1029.3 checkered@1033.0'
  Check "his real race: green 44 s, the 1.8 s blue held 3 s, white for the last lap, then chequered" ($r.realSpans -eq $wantSpans) "got:  $($r.realSpans)`n        want: $wantSpans"
}
$fg = [IO.File]::ReadAllText((Join-Path $root 'dash\www\v2\flaglow.js'))
Check 'the top screen glow shows the very flag the panel shows' ($fg -match 'UI\.flagName' -and $fg -notmatch 'SessionFlags >>>|greenUntil')
Start-Sleep -Milliseconds 500; Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
"$pass passed, $fail failed."
if ($fail -gt 0) { exit 1 }
