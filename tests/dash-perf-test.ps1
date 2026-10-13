$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
Enter-TestLock 'dash-perf-test'
$pass = 0; $fail = 0
function Check($name, $ok) { if ($ok) { $script:pass++; "  ok    $name" } else { $script:fail++; "  FAIL  $name" } }
function Section($name) { Assert-RigFree -Where $name; $name }
function Cdp($method, $params) {
  $c=$script:cdp; $c.id++
  $bytes=[Text.Encoding]::UTF8.GetBytes((@{id=$c.id;method=$method;params=$params}|ConvertTo-Json -Depth 8 -Compress))
  $null=$c.ws.SendAsync([ArraySegment[byte]]$bytes,'Text',$true,[Threading.CancellationToken]::None).Wait()
  while ($true) {
    $buf=New-Object byte[] 262144; $sb=New-Object Text.StringBuilder
    do { $seg=New-Object ArraySegment[byte] -ArgumentList @(,$buf); $r=$c.ws.ReceiveAsync($seg,[Threading.CancellationToken]::None); $null=$r.Wait(); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf,0,$r.Result.Count)) } while (-not $r.Result.EndOfMessage)
    $o=$sb.ToString()|ConvertFrom-Json; if ($o.id -eq $c.id) { return $o }
  }
}
function Eval($expr) { $r=Cdp 'Runtime.evaluate' @{expression=$expr;returnByValue=$true;awaitPromise=$true}; if($r.result.exceptionDetails){throw $r.result.exceptionDetails.exception.description}; return $r.result.result.value }
function MetricMap { $r=Cdp 'Performance.getMetrics' @{}; $h=@{}; foreach($m in $r.result.metrics){$h[$m.name]=[double]$m.value}; return $h }
function Stop-Browser {
  if($script:cdp){try{$script:cdp.ws.Dispose()}catch{}; try{$script:cdp.proc|Stop-Process -Force}catch{}; $script:cdp=$null}
  if($script:prof -and (Test-Path $script:prof)){Remove-Item -LiteralPath $script:prof -Recurse -Force -ErrorAction SilentlyContinue}
}
$chrome='C:\Program Files\Google\Chrome\Application\chrome.exe'; $api='http://localhost:8199'
$script:prof=Join-Path $env:TEMP ('dash-perf-'+[guid]::NewGuid().ToString('N')); $script:cdp=$null
try {
  Section '1. 21-car pretend race in headless Chrome'
  if(-not(Test-Path $chrome)){throw 'Chrome is not installed'}
  $null=Invoke-WebRequest -UseBasicParsing "$api/health" -TimeoutSec 5
  $port=9492
  $p=Start-Process -FilePath $chrome -ArgumentList @('--headless=new','--disable-gpu','--no-first-run',"--user-data-dir=$script:prof","--remote-debugging-port=$port",'--window-size=1920,1080','--hide-scrollbars','about:blank') -PassThru -WindowStyle Hidden
  try{$p.PriorityClass='BelowNormal'}catch{}
  $page=$null; for($i=0;$i -lt 60 -and -not $page;$i++){Start-Sleep -Milliseconds 200;try{$page=Invoke-RestMethod "http://127.0.0.1:$port/json"|Where-Object type -eq 'page'|Select-Object -First 1}catch{}}
  if(-not $page){throw 'headless Chrome did not start'}
  $ws=New-Object System.Net.WebSockets.ClientWebSocket; $null=$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl,[Threading.CancellationToken]::None).Wait()
  $script:cdp=@{ws=$ws;proc=$p;id=0}; $null=Cdp 'Page.enable' @{}; $null=Cdp 'Runtime.enable' @{}; $null=Cdp 'Performance.enable' @{}
  $null=Cdp 'Page.navigate' @{url="$api/v2/index.html?demo=1"}; Start-Sleep -Seconds 5
  Check 'dashboard demo has at least 20 running cars' ([int](Eval 'S.drivers.size') -ge 20)
  Section '2. positions remain correct before any car has a position'
  $order=Eval "(()=>{const p=L.v.CarIdxPosition,c=L.v.CarIdxClassPosition;for(let i=0;i<p.length;i++){p[i]=0;c[i]=0}const a=L.v.CarIdxLapCompleted,b=L.v.CarIdxLapDistPct;for(let i=0;i<a.length;i++){a[i]=0;b[i]=0}a[5]=2;b[5]=.2;a[6]=2;b[6]=.7;a[2]=1;b[2]=.95;const rows=computeStandings(false);return JSON.stringify(rows.slice(0,4).map(r=>({idx:r.d.idx,pos:r.pos,gap:r.gap,dist:r.dist})))})()" | ConvertFrom-Json
  Check 'derived order sorts completed laps, lap fraction, and gives Leader only to P1' ($order[0].pos -eq 1 -and $order[0].gap -eq 'Leader' -and @($order|Where-Object {$_.gap -eq 'Leader'}).Count -eq 1 -and $order[1].pos -eq 2)
  Section '3. 30-second CPU and rendering profile'
  $before=MetricMap; $cpuStart=@{}; Get-CimInstance Win32_Process -Filter "Name='chrome.exe'"|Where-Object {$_.CommandLine -like "*$script:prof*"}|ForEach-Object {try{$cpuStart[$_.ProcessId]=(Get-Process -Id $_.ProcessId).CPU}catch{}}
  $wall=[Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Seconds 30; $wall.Stop(); $after=MetricMap
  $cpu=0.0; Get-CimInstance Win32_Process -Filter "Name='chrome.exe'"|Where-Object {$_.CommandLine -like "*$script:prof*"}|ForEach-Object {try{$q=Get-Process -Id $_.ProcessId; if($cpuStart.ContainsKey($_.ProcessId)){$cpu += $q.CPU-$cpuStart[$_.ProcessId]}}catch{}}
  $pct=100*$cpu/$wall.Elapsed.TotalSeconds
  $scriptDelta=$after.ScriptDuration-$before.ScriptDuration; $layoutDelta=$after.LayoutDuration-$before.LayoutDuration; $paintDelta=$after.PaintCount-$before.PaintCount
  "  info  Chrome CPU $([math]::Round($pct,2))% of one core; scripting $([math]::Round($scriptDelta,2))s, layout $([math]::Round($layoutDelta,2))s, paints $([math]::Round($paintDelta,0)) / $([math]::Round($wall.Elapsed.TotalSeconds,1))s"
  Check 'headless dashboard CPU stays at or below 20% of one core' ($pct -le 20)
  Check 'browser render profile contains scripting, layout, and paint samples' ($scriptDelta -ge 0 -and $layoutDelta -ge 0 -and $paintDelta -gt 0)
  $shots=Join-Path $root 'tests\shots'; New-Item -ItemType Directory -Force $shots|Out-Null
  $shot=Cdp 'Page.captureScreenshot' @{format='png'}; [IO.File]::WriteAllBytes((Join-Path $shots 'dash-perf-pretend.png'),[Convert]::FromBase64String($shot.result.data))
} finally { Stop-Browser; Exit-TestLock }
"$pass ok, $fail FAIL"
if($fail -gt 0){exit 1}
