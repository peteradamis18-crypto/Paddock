$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
Enter-TestLock 'tv-test'
$pass = 0; $fail = 0
function Check($name, $ok) { if ($ok) { $script:pass++; "  ok    $name" } else { $script:fail++; "  FAIL  $name" } }
function Section($name) { Assert-RigFree -Where $name; $name }
function Q($s) { [uri]::EscapeDataString($s) }
function Send-Frame($pairs) { $query = ($pairs.GetEnumerator() | ForEach-Object { "$(Q $_.Key)=$(Q ([string]$_.Value))" }) -join '&'; $null = Invoke-WebRequest -UseBasicParsing "http://localhost:8199/api/test/frame?$query" -TimeoutSec 10 }
function Read-TV() { (Invoke-RestMethod -UseBasicParsing 'http://localhost:8199/tv/data' -TimeoutSec 10) }
function Start-TowerBrowser($fixture) {
  $chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
  $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0); $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop(); $script:towerPort = $port
  $prof = Join-Path $env:TEMP ('tv-tower-' + [guid]::NewGuid().ToString('N'))
  $p = Start-Process -FilePath $chrome -ArgumentList @('--headless=new','--disable-gpu','--no-first-run',"--user-data-dir=$prof","--remote-debugging-port=$port",'--window-size=1920,1080','--hide-scrollbars','about:blank') -PassThru -WindowStyle Hidden
  try { $p.PriorityClass = 'BelowNormal' } catch { }
  $page = $null; for ($i=0; $i -lt 50 -and -not $page; $i++) { Start-Sleep -Milliseconds 200; try { $pages = Invoke-RestMethod "http://127.0.0.1:$script:towerPort/json"; $page = $pages | Where-Object { $_.type -eq 'page' } | Select-Object -First 1 } catch { } }
  if (-not $page) { throw 'headless Chrome did not start' }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket; $null = $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl,[Threading.CancellationToken]::None).Wait()
  $script:towerCdp = @{ ws=$ws; proc=$p; prof=$prof; id=0 }
  $null = Tower-Cdp 'Page.enable' @{}; $null = Tower-Cdp 'Runtime.enable' @{}
  $null = Tower-Cdp 'Emulation.setDeviceMetricsOverride' @{width=1920;height=1080;deviceScaleFactor=1;mobile=$false}
  $null = Tower-Cdp 'Page.navigate' @{url='http://localhost:8199/v2/index.html?demo=1'}
  Start-Sleep -Milliseconds 1800
  $json = ConvertTo-Json -InputObject $fixture -Depth 8 -Compress
  $null = Tower-Eval "clearInterval(Tower.timer); Tower.busy=true; Tv.on=true; document.body.classList.add('tv-on'); $('pTv').hidden=false; Tower.data=JSON.parse('$($json.Replace("'","\u0027"))'); Tower.render(); 'ready'"
}
function Tower-Cdp($method,$params) {
  $c=$script:towerCdp; $c.id++; $bytes=[Text.Encoding]::UTF8.GetBytes((@{id=$c.id;method=$method;params=$params}|ConvertTo-Json -Depth 8 -Compress)); $null=$c.ws.SendAsync([ArraySegment[byte]]$bytes,'Text',$true,[Threading.CancellationToken]::None).Wait()
  while ($true) { $buf=New-Object byte[] 262144; $sb=New-Object Text.StringBuilder; do { $seg=New-Object ArraySegment[byte] -ArgumentList @(,$buf); $r=$c.ws.ReceiveAsync($seg,[Threading.CancellationToken]::None); $null=$r.Wait(); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf,0,$r.Result.Count)) } while (-not $r.Result.EndOfMessage); $o=$sb.ToString()|ConvertFrom-Json; if ($o.id -eq $c.id) { return $o } }
}
function Tower-Eval($expr) { $r=Tower-Cdp 'Runtime.evaluate' @{expression=$expr;awaitPromise=$true;returnByValue=$true}; if ($r.result.exceptionDetails) { throw $r.result.exceptionDetails.exception.description }; return $r.result.result.value }
function Tower-Shot($path) { $r=Tower-Cdp 'Page.captureScreenshot' @{format='png'}; [IO.File]::WriteAllBytes($path,[Convert]::FromBase64String($r.result.data)) }
function Chrome-CpuSnapshot { $h=@{}; Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like "*$script:towerCdp.prof*" } | ForEach-Object { try { $h[[int]$_.ProcessId]=(Get-Process -Id $_.ProcessId).CPU } catch { } }; return ,$h }
function Chrome-CpuDelta($before,$after) { $n=0.0; foreach($id in $before.Keys){if($after.ContainsKey($id)){$n += $after[$id]-$before[$id]}}; return $n }
function Stop-TowerBrowser { $c=$script:towerCdp; if (-not $c) { return }; $script:towerCdp=$null; try {$c.ws.Dispose()}catch{}; try {$c.proc|Stop-Process -Force}catch{}; try {Remove-Item -LiteralPath $c.prof -Recurse -Force -ErrorAction SilentlyContinue}catch{} }
function Send-Frame-AtTick($pairs, $tick) {
  # Retry the same timestamp until the sampler publishes it; wall-clock sleeps alone can race 10 Hz sampling.
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    Send-Frame $pairs
    for ($poll = 0; $poll -lt 5; $poll++) { $snap = Read-TV; if ($null -ne $snap.tick -and [math]::Abs([double]$snap.tick - [double]$tick) -lt 0.0005) { return $snap }; Start-Sleep -Milliseconds 20 }
  }
  throw "TV sampler did not publish SessionTime $tick"
}
$api = 'http://localhost:8199'
$hook = Join-Path $root 'dash\test-hook.on'; $testDir = Join-Path $root 'vault-test'; $yamlPath = Join-Path $testDir 'tv-test.yaml'
$started = $false; $madeHook = $false
try {
  Section '1. prepare guarded pretend session'
  try { $null = Invoke-WebRequest -UseBasicParsing "$api/tv" -TimeoutSec 5 } catch { throw 'irdash local server is not running' }
  if (-not (Test-Path $testDir)) { New-Item -ItemType Directory -Force $testDir | Out-Null; $started = $true }
  $yaml = @'
---
WeekendInfo:
 TrackName: pretend tv circuit
 TrackDisplayName: Pretend TV Circuit
 TrackConfigName: Full
 TrackLength: 2.000 km
DriverInfo:
 DriverCarIdx: 1
 PaceCarIdx: 9
 Drivers:
 - CarIdx: 1
   UserName: Driver One
   CarNumberRaw: 4
   CarNumber: "04"
   CarClassID: 10
   CarClassShortName: GT3
   CarClassColor: 0xffaa00
 - CarIdx: 2
   UserName: Driver Two
   CarNumberRaw: 22
   CarClassID: 10
   CarClassShortName: GT3
   CarClassColor: 0xffaa00
 - CarIdx: 3
   UserName: Driver Three
   CarNumberRaw: 7
   CarClassID: 20
   CarClassShortName: GT4
   CarClassColor: 0x33ccff
 - CarIdx: 9
   UserName: Pace
   CarNumberRaw: 0
   CarClassID: 10
   CarIsPaceCar: 1
 - CarIdx: 8
   UserName: Spectator
   CarNumberRaw: 99
   CarClassID: 10
   IsSpectator: 1
...
'@
  [IO.File]::WriteAllText($yamlPath, $yaml, [Text.Encoding]::GetEncoding(28591))
  if (-not (Test-Path $hook)) { [IO.File]::WriteAllText($hook, 'tv-test'); $madeHook = $true }
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/fieldyaml?name=tv-test.yaml" -TimeoutSec 10
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/field?on=1&pump=20&ms=0" -TimeoutSec 10
  $started = $true
  $null = Invoke-RestMethod -UseBasicParsing "$api/api/test/replaylog?clear=1" -TimeoutSec 10
  $seed = [ordered]@{ SessionTime = 123.0; IsOnTrack = 1; CarIdxLapDistPct_1 = 0.99; CarIdxLapDistPct_2 = 0.01; CarIdxLapDistPct_3 = 0.50; CarIdxLap_1 = 5; CarIdxLap_2 = 5; CarIdxLap_3 = 4; CarIdxPosition_1 = 2; CarIdxPosition_2 = 1; CarIdxPosition_3 = 3; CarIdxClassPosition_1 = 1; CarIdxClassPosition_2 = 1; CarIdxClassPosition_3 = 1; CarIdxOnPitRoad_1 = 0; CarIdxOnPitRoad_2 = 1; CarIdxOnPitRoad_3 = 0; CarIdxLastLapTime_1 = 89.123; CarIdxLastLapTime_2 = 90.234; CarIdxLastLapTime_3 = 91.345; CarIdxF2Time_1 = 0.4; CarIdxF2Time_2 = 2.0; CarIdxF2Time_3 = 1.0 }
  $null = Send-Frame-AtTick $seed 123.0
  Section '2. frozen-frame car values and JSON types'
  $d = Read-TV; $by = @{}; foreach ($c in $d.cars) { $by[[int]$c.idx] = $c }
  Check 'snapshot tick comes from frame SessionTime' ([math]::Abs([double]$d.tick - 123.0) -lt 0.001)
  Check 'track/config/length/player metadata from session YAML' ($d.track -eq 'Pretend TV Circuit' -and $d.config -eq 'Full' -and [math]::Abs([double]$d.lengthM - 2000) -lt 0.001 -and [int]$d.playerIdx -eq 1)
  Check 'three active cars, pace car and spectator excluded' ($d.cars.Count -eq 3 -and -not $by.ContainsKey(9) -and -not $by.ContainsKey(8))
  Check 'car 1 identity, class and wrapped-map fraction' ($by[1].num -eq '4' -and $by[1].name -eq 'Driver One' -and [int]$by[1].classId -eq 10 -and $by[1].className -eq 'GT3' -and $by[1].classColor -eq 'ffaa00' -and [math]::Abs([double]$by[1].pct - 0.99) -lt 0.001)
  Check 'car 1 positions, pit, lap and last time types/values' (($by[1].pos -is [int] -or $by[1].pos -is [long]) -and ($by[1].classPos -is [int] -or $by[1].classPos -is [long]) -and $by[1].pit -is [bool] -and [int]$by[1].pos -eq 1 -and [int]$by[1].classPos -eq 1 -and $by[1].pit -eq $false -and [int]$by[1].lap -eq 5 -and [math]::Abs([double]$by[1].last - 89.123) -lt 0.001)
  $wrapFraction = [math]::Abs([double]$by[1].pct - [double]$by[2].pct); $wrapFraction = [math]::Min($wrapFraction, 1 - $wrapFraction)
  Check 'car 2 dot wraps across start/finish and pit is boolean' ([math]::Abs($wrapFraction * [double]$d.lengthM - 40) -lt 1 -and $by[2].pit -eq $true -and [int]$by[2].pos -eq 3)
  Check 'car 3 class metadata and supported values' ([int]$by[3].classId -eq 20 -and $by[3].className -eq 'GT4' -and $by[3].classColor -eq '33ccff' -and [int]$by[3].lap -eq 4 -and [math]::Abs([double]$by[3].last - 91.345) -lt 0.001)
  Check 'F2 timing and derived running order are retained in the snapshot' ([double]$by[1].gap -eq 0 -and [double]$by[1].interval -eq 0 -and [double]$by[3].gap -eq 1 -and [double]$by[3].interval -eq 1 -and [double]$by[2].gap -eq 3 -and [double]$by[2].interval -eq 2)
  $expected = @(
    @{ idx=1; num='4'; name='Driver One'; classId=10; className='GT3'; color='ffaa00'; pct=.99; pos=1; classPos=1; pit=$false; lap=5; last=89.123; gap=0; interval=0 },
    @{ idx=2; num='22'; name='Driver Two'; classId=10; className='GT3'; color='ffaa00'; pct=.01; pos=3; classPos=2; pit=$true; lap=5; last=90.234; gap=3.0; interval=2.0 },
    @{ idx=3; num='7'; name='Driver Three'; classId=20; className='GT4'; color='33ccff'; pct=.50; pos=2; classPos=1; pit=$false; lap=4; last=91.345; gap=1.0; interval=1.0 }
  )
  $all = $true
  foreach ($e in $expected) { $c = $by[$e.idx]; $all = $all -and $c.idx -eq $e.idx -and $c.num -eq $e.num -and $c.name -eq $e.name -and [int]$c.classId -eq $e.classId -and $c.className -eq $e.className -and $c.classColor -eq $e.color -and [math]::Abs([double]$c.pct - $e.pct) -lt .001 -and [int]$c.pos -eq $e.pos -and [int]$c.classPos -eq $e.classPos -and $c.pit -eq $e.pit -and [int]$c.lap -eq $e.lap -and [math]::Abs([double]$c.last - $e.last) -lt .001 -and [math]::Abs([double]$c.gap - $e.gap) -lt .001 -and [math]::Abs([double]$c.interval - $e.interval) -lt .001 }
  Check 'every listed field matches all three fixed frame cars' $all
  Check 'live data route is readable while pretend IsOnTrack is true' ($d.cars.Count -eq 3 -and [int](Read-TV).tick -eq 123)
  Section '3. timing tower renders the frozen server shape'
  $towerCars = @(); for ($i=1; $i -le 20; $i++) { $cid=20; $cname='GT4'; $color='33ccff'; $cp=$i-10; if($i -le 10){$cid=10;$cname='GT3';$color='ffaa00';$cp=$i}; $towerCars += @{idx=$i;num=[string]$i;name=('Driver ' + $i.ToString('00'));classId=$cid;className=$cname;classColor=$color;pos=$i;classPos=$cp;pit=($i -eq 2);last=(89.0+$i/10);gap=($i/10);interval=$null} }
  $towerFixture = @{tick=100.0;track='Pretend TV Circuit';config='Full';lengthM=2000;playerIdx=4;cars=$towerCars;battles=@()}
  $towerFixture.cars[0].name = 'A deliberately very long driver name that must stay inside its timing tower column'
  $towerFixture.cars[1].classColor = 'not-a-color'
  Start-TowerBrowser $towerFixture
  $towerResult = Tower-Eval "JSON.stringify((()=>{const rows=[...document.querySelectorAll('#tvTowerRows .tv-tower-row')], cells=[...document.querySelectorAll('#tvTowerRows span')], r=document.querySelector('#tvTower').getBoundingClientRect(), name=rows[0].querySelector('.tv-name'), cs=getComputedStyle(name), color=getComputedStyle(rows[1]).getPropertyValue('--class').trim();let overlap=0;for(let i=0;i<cells.length;i++)for(let j=i+1;j<cells.length;j++){let a=cells[i].getBoundingClientRect(),b=cells[j].getBoundingClientRect();if(a.width&&b.width&&Math.min(a.right,b.right)>Math.max(a.left,b.left)+.5&&Math.min(a.bottom,b.bottom)>Math.max(a.top,b.top)+.5)overlap++}return {rows:rows.map(x=>({idx:+x.dataset.idx,text:x.innerText,me:x.classList.contains('tv-me'),multi:x.classList.contains('tv-multi')})),width:r.width,height:r.height,overlap,nameWidth:name.clientWidth,nameScroll:name.scrollWidth,nameOverflow:cs.overflow,nameEllipsis:cs.textOverflow,fallbackColor:color,header:[...document.querySelectorAll('.tv-tower-head span')].map(x=>x.textContent)}})())"
  $towerResult = $towerResult | ConvertFrom-Json
  Check '20 rows sorted in positive overall position order' ($towerResult.rows.Count -eq 20 -and (($towerResult.rows.idx -join ',') -eq (1..20 -join ',')))
  $exact = Tower-Eval "(()=>{const exp=Tower.data.cars.filter(c=>c.pos>0).sort((a,b)=>a.pos-b.pos||(a.classPos||0)-(b.classPos||0)||a.idx-b.idx),rows=[...document.querySelectorAll('#tvTowerRows .tv-tower-row')],gap=n=>typeof n==='number'&&isFinite(n)?(n>0?'+':'')+n.toFixed(1)+' s':'-',time=n=>{if(typeof n!=='number'||!isFinite(n)||n<=0)return '-';const m=Math.floor(n/60),s=(n-m*60).toFixed(1);return m+':'+(s<10?'0':'')+s};return rows.length===20&&rows.every((r,i)=>{const c=exp[i],v=[...r.children].map(x=>x.textContent.replace(/\u2013/g,'-'));return +r.dataset.idx===c.idx&&v[0]===String(c.pos)&&v[1]===String(c.num||'-')&&v[2]===String(c.name||'-')&&v[3]===gap(c.gap)&&v[4]===gap(c.interval)&&v[5]===time(c.last)&&v[6]===(c.pit?'PIT':'')})})()"
  Check 'all 20 positions, numbers, names, gaps and last times match; interval and PIT states are exact' $exact
  Check 'Peter row is gold and multiclass rows have a 4 px class strip' ($towerResult.rows[3].me -and @($towerResult.rows | Where-Object multi).Count -eq 20)
  Check 'invalid class color keeps a safe 4 px fallback strip' ($towerResult.fallbackColor -eq '#77736a' -and (Tower-Eval "getComputedStyle(document.querySelector('#tvTowerRows .tv-tower-row')).borderLeftWidth") -eq '4px')
  Check 'headers meet tower labels and minimum readable sizes' (($towerResult.header -join ',') -eq 'POS,NO.,DRIVER,GAP,INT,LAST,PIT' -and [double](Tower-Eval "parseFloat(getComputedStyle(document.querySelector('.tv-tower-head')).fontSize)") -ge 14 -and [double](Tower-Eval "parseFloat(getComputedStyle(document.querySelector('.tv-tower-row')).fontSize)") -ge 22)
  Check 'long driver name is clipped inside its cell with ellipsis' ($towerResult.nameScroll -gt $towerResult.nameWidth -and $towerResult.nameOverflow -eq 'hidden' -and $towerResult.nameEllipsis -eq 'ellipsis')
  Check 'tower is 560 px wide with no overlapping visible cell text' ([math]::Abs([double]$towerResult.width - 560) -lt 1 -and $towerResult.height -lt 1080 -and $towerResult.overlap -eq 0)
  $shotDir=Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shotDir | Out-Null; Tower-Shot (Join-Path $shotDir 'tv-tower-multiclass.png')
  $null = Tower-Eval "Tower.data.cars=Tower.data.cars.map(c=>({...c,classId:10,classColor:'ffaa00'})); Tower.render(); 'ok'"
  $classCount = Tower-Eval "document.querySelectorAll('#tvTowerRows .tv-multi').length"
  Check 'single class removes every class strip' ([int]$classCount -eq 0)
  Tower-Shot (Join-Path $shotDir 'tv-tower-single-class.png')
  $null = Tower-Eval "Tower.data={tick:100,cars:[],playerIdx:4}; Tower.render(); 'ok'"
  Check 'empty connected field hides the tower and clears rows' ((Tower-Eval "JSON.stringify({hidden:document.querySelector('#tvTower').hidden,rows:document.querySelectorAll('#tvTowerRows .tv-tower-row').length})") | ConvertFrom-Json | ForEach-Object { $_.hidden -and $_.rows -eq 0 })
  $null = Tower-Eval "Tower.data={tick:null,cars:[{idx:4,pos:1,name:'Stale',num:'4'}],playerIdx:4}; Tower.render(); 'ok'"
  Check 'disconnected data hides the tower and clears stale rows' ((Tower-Eval "JSON.stringify({hidden:document.querySelector('#tvTower').hidden,rows:document.querySelectorAll('#tvTowerRows .tv-tower-row').length})") | ConvertFrom-Json | ForEach-Object { $_.hidden -and $_.rows -eq 0 })
  Section '4. real GPS field map projection and drawing cap'
  $mapResult = Tower-Eval "(async()=>{const r=await fetch('/trackmap?key=t127-roadatlanta-full&id=127&name=roadatlanta%20full',{cache:'no-store'}),m=await r.json(),pts=m.pts&&m.pts.length>=20?m.pts:(m.gps&&m.gps.pts)||null;if(!pts)return JSON.stringify({ok:false,source:m.source||'',points:0});TrackMap.pts=pts;TrackMap.source=m.source||(m.gps?'gps':'');TrackMap.key='t127-roadatlanta-full';TrackMap.pit=m.pit||null;TrackMap.view=null;TrackInfo.raw=NO_CORNERS;const cars=Array.from({length:20},(_,i)=>({idx:i+1,pos:i+1,num:String(i+1),classColor:i<10?'ffaa00':'33ccff',pct:i===0?0:i===1?0.99:i===2?1:(i+1)/21}));Tower.data={tick:100,playerIdx:4,cars,battles:[{a:1,b:2}]};const cv=document.createElement('canvas');cv.width=1300;cv.height=700;cv.style.cssText='position:fixed;left:0;top:0;width:1300px;height:700px;z-index:2147483647';document.querySelector('main').style.visibility='hidden';document.querySelector('#overlay').style.visibility='hidden';document.body.appendChild(cv);const x=cv.getContext('2d'),arcs=[],strokes=[],texts=[],arc=x.arc,fill=x.fill,stroke=x.stroke,ft=x.fillText;x.arc=function(a,b,r){arcs.push({x:a,y:b,r});arc.apply(this,arguments)};x.fill=function(){if(arcs.length)arcs[arcs.length-1].fill=this.fillStyle;fill.apply(this,arguments)};x.stroke=function(){if(arcs.length)strokes.push({r:arcs[arcs.length-1].r,color:this.strokeStyle});stroke.apply(this,arguments)};x.fillText=function(t,a,b){texts.push(String(t));ft.apply(this,arguments)};Tv.drawFieldMap(x,Tower.data,1300,700);const dots=arcs.filter(a=>a.r===5||a.r===7),rings=strokes.filter(a=>a.r===8||a.r===10),x0=Math.min(...pts.map(p=>p[0])),x1=Math.max(...pts.map(p=>p[0])),y0=Math.min(...pts.map(p=>p[1])),y1=Math.max(...pts.map(p=>p[1])),tw=x1-x0||1,th=y1-y0||1,pad=46,sA=Math.min((1300-2*pad)/tw,(700-2*pad)/th),sB=Math.min((1300-2*pad)/th,(700-2*pad)/tw),rot=sB>sA*1.08,vw={w:1300,h:700,s:rot?sB:sA,rot,cx:(x0+x1)/2,cy:(y0+y1)/2},ex=c=>{const f=((c.pct%1)+1)%1*pts.length,i=Math.floor(f),t=f-i,a=pts[i],b=pts[(i+1)%pts.length];let xx=(a[0]+(b[0]-a[0])*t-vw.cx)*vw.s,yy=-(a[1]+(b[1]-a[1])*t-vw.cy)*vw.s;if(vw.rot){const z=xx;xx=-yy;yy=z}return [vw.w/2+xx,vw.h/2+yy]};const error=Math.max(...cars.map((c,i)=>{const q=ex(c),d=dots[i];return d?Math.hypot(q[0]-d.x,q[1]-d.y):999})),wrap=Math.hypot(ex(cars[0])[0]-ex(cars[2])[0],ex(cars[0])[1]-ex(cars[2])[1]),colors=dots.every((d,i)=>d.fill===(i===3?'#f2c230':'#'+cars[i].classColor));TrackMap.pts=null;TrackMap.view=null;const cv2=document.createElement('canvas');cv2.width=1300;cv2.height=700;const x2=cv2.getContext('2d');let arcs2=0,text2='';const a2=x2.arc,t2=x2.fillText;x2.arc=function(){arcs2++;a2.apply(this,arguments)};x2.fillText=function(s){text2+=String(s);t2.apply(this,arguments)};Tv.drawFieldMap(x2,Tower.data,1300,700);const im=x2.getImageData(0,0,1300,700).data;let off=0;for(let y=40;y<660;y++){if(Math.abs(y-350)<24)continue;for(let xx=0;xx<1300;xx++){const p=(y*1300+xx)*4;if(im[p]!==7||im[p+1]!==8||im[p+2]!==11)off++}}return JSON.stringify({ok:true,source:m.source||(m.gps?'gps':''),points:pts.length,cars:cars.length,dots:dots.length,error,wrap,rings:rings.map(a=>({r:a.r,color:a.color})),gold:texts.includes('#4'),colors,off,arcs2,text2})})()"
  $mapResult = $mapResult | ConvertFrom-Json
  Check 'fixture loads a real track outline from /trackmap (GPS or library) with at least 20 points' ($mapResult.ok -and $mapResult.points -ge 20 -and $mapResult.source -in @('gps','ibt','library'))
  Check '20 field cars land within 2 px of shared real-map projection at fractions including 0, 0.99 and 1' ($mapResult.cars -eq 20 -and $mapResult.dots -eq 20 -and [double]$mapResult.error -le 2)
  Check 'fraction 0 and 1 resolve to equivalent start/finish centers within 2 px' ([double]$mapResult.wrap -le 2)
  Check 'player #4 is gold; leader and both battle cars are ringed' ($mapResult.gold -and @($mapResult.rings | Where-Object { $_.r -eq 10 -and $_.color -eq '#f2c230' }).Count -eq 1 -and @($mapResult.rings | Where-Object { $_.r -eq 8 }).Count -eq 2)
  Check 'each car uses its class color except the gold player' $mapResult.colors
  Check "missing outline: one status line ('$($mapResult.text2)'), no car dots, no circuit-shaped pixels" ([int]$mapResult.off -eq 0 -and [int]$mapResult.arcs2 -eq 0 -and $mapResult.text2.Length -gt 0)
  Section '4a. shared corner renderer and malformed field data'
  $sharedCorners = Tower-Eval "(()=>{const original=Corners.draw, oldPts=TrackMap.pts, data={turns:[],sectors:[0,.5],pitIn:.1,pitOut:.9,credit:'fixture credit'};TrackMap.pts=[[0,0],[1,0],[0,1]];let got=null;Corners.draw=function(ctx,project,opts){got={data:opts.data,ticks:opts.ticks,pit:opts.pit,credit:opts.credit};return original.call(this,ctx,project,opts)};TrackInfo.raw=data;const cv=document.createElement('canvas'),ctx=cv.getContext('2d');Tv.drawCorners(ctx,p=>[p*100,50],100,100);Corners.draw=original;TrackInfo.raw=null;TrackMap.pts=oldPts;return !!got&&got.data===data&&got.ticks===true&&got.pit===true&&got.credit===true})()"
  Check 'TV camera annotations use Corners.draw with real track data, sectors, pit marks and attribution' $sharedCorners
  $edgeMap = Tower-Eval "(()=>{const cv=document.createElement('canvas'),ctx=cv.getContext('2d'),arc=ctx.arc,stroke=ctx.stroke;let dots=0,rings=0,lastR=0;ctx.arc=function(x,y,r){lastR=r;if(r===5||r===7)dots++;arc.apply(this,arguments)};ctx.stroke=function(){if(lastR===8||lastR===10)rings++;stroke.apply(this,arguments)};const oldP=TrackMap.pts,oldS=TrackMap.source;TrackMap.pts=Array.from({length:720},(_,i)=>[Math.cos(i/720*6.2832)*500,Math.sin(i/720*6.2832)*300]);TrackMap.source='library';TrackMap.view=null;TrackMap.layerKey='';const d={playerIdx:9,cars:[{idx:1,pct:.25,pos:2},{idx:2,pct:-.01},{idx:3,pct:1.01},{idx:4,pct:NaN}]};try{Tv.drawFieldMap(ctx,d,300,160);return dots===1&&rings===0}catch(e){return false}finally{TrackMap.pts=oldP;TrackMap.source=oldS;TrackMap.view=null;TrackMap.layerKey=''}})()"
  Check 'invalid fractions are skipped and absent battle data draws safely without battle rings' $edgeMap
  $rate = Tower-Eval "(()=>{let n=0;Tv.on=true;Tv.driving=()=>true;Tv.draw=()=>{n++};Tv.lastRenderAt=-1000;for(let t=0;t<2000;t+=16)Tv.renderFrame(1/60,t);Tv.on=false;return n})()"
  Check "TV map render cap stays at 60 or fewer draws in 2 seconds ($rate)" ([int]$rate -le 60 -and [int]$rate -gt 0)
  $null = Tower-Cdp 'Emulation.setDeviceMetricsOverride' @{width=1300;height=700;deviceScaleFactor=1;mobile=$false}
  Tower-Shot (Join-Path $shotDir 'tv-map-field.png')
  Section '4b. live inputs, overlay geometry and paired Chrome cost'
  $null=Tower-Cdp 'Emulation.setDeviceMetricsOverride' @{width=1920;height=1080;deviceScaleFactor=1;mobile=$false}
  $null=Tower-Eval 'Tv.set(false)'
  Tower-Shot (Join-Path $shotDir 'tv-t04-before.png')
  $inputs = Tower-Eval "(()=>{Tv.inputs({Gear:4,Speed:58.9,Throttle:.897,Brake:.104,LapLastLapTime:79.95,PlayerCarIdx:4});return JSON.stringify({gear:document.querySelector('#tvGear').textContent,speed:document.querySelector('#tvSpeed').textContent,thr:parseFloat(document.querySelector('#tvThrottle').style.width),brk:parseFloat(document.querySelector('#tvBrake').style.width),last:document.querySelector('#tvLast').textContent})})()" | ConvertFrom-Json
  if ($inputs.gear -ne 'GEAR 4' -or $inputs.speed -ne '212 km/h' -or [math]::Abs([double]$inputs.thr-89.7) -ge 1 -or [math]::Abs([double]$inputs.brk-10.4) -ge 1 -or $inputs.last -ne 'LAST 1:20.0') { '  info  lower-third fixture: ' + ($inputs | ConvertTo-Json -Compress) }
  Check 'input lower third converts speed, gear and controls; last lap rounds within 0.1 s' ($inputs.gear -eq 'GEAR 4' -and $inputs.speed -eq '212 km/h' -and [math]::Abs([double]$inputs.thr-89.7) -lt 1 -and [math]::Abs([double]$inputs.brk-10.4) -lt 1 -and $inputs.last -eq 'LAST 1:20.0')
  $rec = Tower-Eval "fetch('/vault/recorder',{cache:'no-store'}).then(r=>r.json()).then(x=>JSON.stringify({running:x.running,enabled:x.enabled}))"
  $rec = $rec | ConvertFrom-Json
  Check 'REC source is the recorder status endpoint running boolean' ($null -ne $rec.running -and $rec.running -is [bool])
  $geom = Tower-Eval "(()=>{const es=[...document.querySelectorAll('main .panel')],snap=()=>es.map(e=>{const r=e.getBoundingClientRect();return [e.id,r.x,r.y,r.width,r.height]});const before=snap();Tv.set(true);const after=snap();Tv.set(false);let max=0;for(let i=0;i<before.length;i++)for(let j=1;j<5;j++)max=Math.max(max,Math.abs(before[i][j]-after[i][j]));return JSON.stringify({count:before.length,max,swap:['pMap','pTime'].every(id=>before.some(x=>x[0]===id))})})()" | ConvertFrom-Json
  Check 'TV swap preserves map and pace panel geometry and every other dashboard panel within one pixel' ($geom.swap -and $geom.count -ge 4 -and [double]$geom.max -le 1)
  $null=Tower-Eval 'Tv.set(true); Tv.running=true'
  Tower-Shot (Join-Path $shotDir 'tv-t04-after.png')
  $baseStart=Chrome-CpuSnapshot; $wall=[Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Seconds 60; $wall.Stop(); $baseEnd=Chrome-CpuSnapshot; $basePct=100*(Chrome-CpuDelta $baseStart $baseEnd)/$wall.Elapsed.TotalSeconds
  $null=Tower-Eval 'Tv.set(true); Tv.running=true'
  $tvStart=Chrome-CpuSnapshot; $wall=[Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Seconds 60; $wall.Stop(); $tvEnd=Chrome-CpuSnapshot; $tvPct=100*(Chrome-CpuDelta $tvStart $tvEnd)/$wall.Elapsed.TotalSeconds
  $added=[math]::Max(0,$tvPct-$basePct); "  info  Chrome CPU baseline $([math]::Round($basePct,2))%, TV $([math]::Round($tvPct,2))%, added $([math]::Round($added,2))% of one core"
  Check 'TV added Chrome CPU stays at or below 5% of one core in paired 60-second samples' ($added -le 5)
  $null=Tower-Eval 'Tv.set(false)'
  Stop-TowerBrowser
  Section '5. same-class battle timing and separation reset'
  $battle = [ordered]@{ SessionTime = 200.0; IsOnTrack = 1; CarIdxF2Time_1 = 0.0; CarIdxF2Time_2 = 0.3; CarIdxF2Time_3 = 4.0; CarIdxOnPitRoad_1 = 0; CarIdxOnPitRoad_2 = 0; CarIdxOnPitRoad_3 = 0 }
  $battle.SessionTime = 200.0; $null = Send-Frame-AtTick $battle 200.0
  for ($i = 1; $i -le 48; $i++) { $battle.SessionTime = 200.0 + $i * 0.1; Send-Frame $battle; Start-Sleep -Milliseconds 100 }
  $battle.SessionTime = 204.9; $d49 = Send-Frame-AtTick $battle 204.9; Check 'battle absent at observed 4.9 second snapshot' ($d49.battles.Count -eq 0)
  $battle.SessionTime = 205.0; $d50 = Send-Frame-AtTick $battle 205.0
  $battleOk = $d50.battles.Count -eq 1 -and [int]$d50.battles[0].a -eq 1 -and [int]$d50.battles[0].b -eq 2; if (-not $battleOk) { '  info  battle sample: ' + ($d50 | ConvertTo-Json -Depth 6 -Compress) }; Check 'battle present at observed 5.0 second snapshot for same-class pair' $battleOk
  Check 'director selects BATTLE on the player pair at the five-second threshold' ($d50.director -eq 'BATTLE')
  $yaml = $yaml -replace 'CarClassID: 10', 'CarClassID: 30' -replace 'CarClassID: 20', 'CarClassID: 30'
  [IO.File]::WriteAllText($yamlPath, $yaml, [Text.Encoding]::GetEncoding(28591))
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/fieldyaml?name=tv-test.yaml" -TimeoutSec 10
  $battle.SessionTime = 205.1; $null = Send-Frame-AtTick $battle 205.1
  Check 'class change resets prior battle timer' ((Read-TV).battles.Count -eq 0)
  for ($i = 1; $i -le 48; $i++) { $battle.SessionTime = 205.1 + $i * 0.1; Send-Frame $battle; Start-Sleep -Milliseconds 100 }
  $battle.SessionTime = 210.0; $dNew49 = Send-Frame-AtTick $battle 210.0; Check 'new class pair still below threshold at 4.9 seconds' ($dNew49.battles.Count -eq 0)
  $battle.SessionTime = 210.1; $dNew50 = Send-Frame-AtTick $battle 210.1; Check 'new class pair reaches threshold only after five seconds' ($dNew50.battles.Count -eq 1)
  $battle.SessionTime = 210.2; $battle.CarIdxF2Time_2 = 1.1; Send-Frame $battle; Start-Sleep -Milliseconds 250
  Check 'separation clears battle' ((Read-TV).battles.Count -eq 0)
  Check 'BATTLE label holds for at least eight seconds after separation' ((Read-TV).director -eq 'BATTLE')
  $battle.CarIdxF2Time_2 = 1.1; $battle.SessionTime = 218.0; $dChase = Send-Frame-AtTick $battle 218.0
  Check 'CHASE replaces BATTLE only after its eight-second hold and verified 1.1-second gap' ($dChase.director -eq 'CHASE')
  Section '6. missing arrays and disconnected state'
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 10; Start-Sleep -Milliseconds 300
  $dend = Read-TV
  Check 'disconnected session returns empty cars and battles' ($dend.cars.Count -eq 0 -and $dend.battles.Count -eq 0 -and $null -eq $dend.tick)
  Check 'no outgoing SDK command was recorded' (((Invoke-RestMethod -UseBasicParsing "$api/api/test/replaylog?clear=1" -TimeoutSec 10).msgs.Count) -eq 0)
  Section '7. absent arrays stay absent'
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 10; Start-Sleep -Milliseconds 250
  $null = Invoke-WebRequest -UseBasicParsing "$api/api/test/fieldyaml?name=tv-test.yaml" -TimeoutSec 10
  Send-Frame ([ordered]@{ SessionTime = 300.0; IsOnTrack = 1 }); Start-Sleep -Milliseconds 250
  $missing = Read-TV
  Check 'missing car arrays yield empty cars rather than fabricated values' ($missing.cars.Count -eq 0 -and [double]$missing.tick -eq 300.0)
  Check 'TRACK starts at the 60-second boundary even without inferred position data' ($missing.director -eq 'TRACK')
  Send-Frame ([ordered]@{ SessionTime = 310.0; IsOnTrack = 1 }); Start-Sleep -Milliseconds 250
  Check 'TRACK ends exactly ten seconds into the schedule' ((Read-TV).director -eq 'LEADER')
} finally {
  Stop-TowerBrowser
  try { Invoke-WebRequest -UseBasicParsing "$api/api/test/end" -TimeoutSec 5 | Out-Null } catch { }
  try { Invoke-WebRequest -UseBasicParsing "$api/api/test/field?on=0&pump=33&ms=0" -TimeoutSec 5 | Out-Null } catch { }
  if ($madeHook -and (Test-Path $hook)) { Remove-Item $hook -Force -ErrorAction SilentlyContinue }
  if (Test-Path $yamlPath) { Remove-Item $yamlPath -Force -ErrorAction SilentlyContinue }
  if ($started -and (Test-Path $testDir) -and -not (Get-ChildItem $testDir -Force | Select-Object -First 1)) { Remove-Item $testDir -Force -ErrorAction SilentlyContinue }
  Exit-TestLock
}
"$pass ok, $fail FAIL"
if ($fail -gt 0) { exit 1 }
