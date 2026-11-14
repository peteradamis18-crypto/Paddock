# review-more-fixtures.ps1 - makes the fixtures REVIEW > MORE DATA's test serves from a pretend irdash (W4-5): a made-up lap in irdash's own binary
# reply (PWB1: JSON header + Float32 arrays on a 1 m grid), its reference lap, and the small JSON answers the kept tabs read
# (/analysis/deep for BRAKING, /analysis/session for SPLITS, /analysis/race for RACE, /vault and /vault/tools for the links).
# Dot-source it, then:  New-MoreFixtures -Dir <folder> [-Pi $true] [-Delta $false] [-Race $true]
function New-MoreFixtures([string]$Dir, [bool]$Pi = $true, [bool]$Delta = $false, [bool]$Race = $true, [bool]$NoLaps = $false) {
  New-Item -ItemType Directory -Force $Dir | Out-Null
  $inv = [Globalization.CultureInfo]::InvariantCulture
  $metres = 1000; $n = $metres + 1; $L = 4000.0; $step = $L / $metres
  $apex = @(0.10, 0.30, 0.50, 0.70, 0.90)
  $keys = @('Speed', 'Throttle', 'Brake', 'BrakeABSactive', 'SteeringWheelAngle', 'SteeringWheelPctTorque', 'Gear', 'RPM', 'LatAccel', 'LongAccel',
    'VelocityX', 'VelocityY', 'YawRate', 'Lat', 'Lon', 'LFspeed', 'RFspeed', 'LRspeed', 'RRspeed', 'dcBrakeBias')
  function Make-Lap([double]$faster, [double]$later) {
    $c = @{}; foreach ($k in $keys) { $c[$k] = New-Object 'single[]' $n }
    $v = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) {
      $f = ($i - $later / $step) / $metres; $s = 62.0 + $faster
      foreach ($a in $apex) { $s -= 36.0 * [math]::Exp(-[math]::Pow(($f - $a) / 0.03, 2)) }
      $v[$i] = $s
    }
    $t = New-Object 'single[]' $n; $acc = 0.0
    for ($i = 0; $i -lt $n; $i++) {
      if ($i -gt 0) { $acc += $step / (($v[$i] + $v[$i - 1]) / 2) }
      $t[$i] = [single]$acc
      $dv = if ($i -gt 0) { $v[$i] - $v[$i - 1] } else { 0 }
      $br = [math]::Min(1.0, [math]::Max(0.0, -$dv * 1.6)); $th = [math]::Min(1.0, [math]::Max(0.0, 1.0 - $br * 3 + $dv * 0.5))
      $ph = 0.0; for ($q = 0; $q -lt $apex.Count; $q++) { $ph += [math]::Exp(-[math]::Pow(($i / $metres - $apex[$q]) / 0.03, 2)) * $(if ($q % 2) { -1 } else { 1 }) }
      $c['Speed'][$i] = [single]$v[$i]; $c['Brake'][$i] = [single]$br; $c['Throttle'][$i] = [single]$th
      $c['BrakeABSactive'][$i] = [single]$(if ($br -gt 0.55) { 1 } else { 0 })
      $c['SteeringWheelAngle'][$i] = [single](1.2 * $ph); $c['SteeringWheelPctTorque'][$i] = [single](0.2 + 0.5 * [math]::Abs($ph))
      $c['Gear'][$i] = [single][math]::Min(5, [math]::Max(2, [math]::Floor($v[$i] / 12))); $c['RPM'][$i] = [single](3000 + $v[$i] * 70)
      $c['LatAccel'][$i] = [single](18 * $ph); $c['LongAccel'][$i] = [single](($v[$i] - $(if ($i) { $v[$i - 1] } else { $v[$i] })) * 20)
      $c['VelocityX'][$i] = [single]$v[$i]; $c['VelocityY'][$i] = [single](0.8 * $ph); $c['YawRate'][$i] = [single](0.4 * $ph)
      $ang = 2 * [math]::PI * $i / $metres
      $c['Lat'][$i] = [single](34.14 + 0.012 * [math]::Sin($ang) * (1 + 0.25 * [math]::Cos(3 * $ang))); $c['Lon'][$i] = [single](-83.81 + 0.016 * [math]::Cos($ang))
      foreach ($w in 'LFspeed', 'RFspeed', 'LRspeed', 'RRspeed') { $c[$w][$i] = [single]($v[$i] * $(if ($br -gt 0.6 -and $w -eq 'LFspeed') { 0.85 } else { 1 })) }
      $c['dcBrakeBias'][$i] = [single]54.5
    }
    return @{ t = $t; c = $c }
  }
  $A = Make-Lap 0.0 0.0; $R = Make-Lap 1.2 -8.0
  $chan = ($keys | ForEach-Object { '{"key":"' + $_ + '","name":"' + $_ + '","unit":"","desc":"","ok":true}' }) -join ','
  $arrays = @('"lap.t"') + ($keys | ForEach-Object { '"lap.' + $_ + '"' }) + @('"ref.t"') + ($keys | ForEach-Object { '"ref.' + $_ + '"' })
  $corners = for ($q = 0; $q -lt 5; $q++) {
    '{"n":' + ($q + 1) + ',"label":"T' + ($q + 1) + '","name":"Turn ' + ($q + 1) + '","official":"' + ($q + 1) + '","p0":' + ($apex[$q] - 0.045).ToString('0.00000', $inv) + ',"pa":' + $apex[$q].ToString('0.00000', $inv) + ',"p1":' + ($apex[$q] + 0.045).ToString('0.00000', $inv) + '}'
  }
  $lapRows = (1..6 | ForEach-Object { '{"n":' + $_ + ',"time":' + (95.1 + $_ * 0.4).ToString('0.000', $inv) + ',"official":null,"clean":' + $(if ($_ -eq 3) { 'false' } else { 'true' }) + ',"skip":"' + $(if ($_ -eq 3) { 'off' } else { '' }) + '"}' }) -join ','
  $head = '{"v":1,"n":' + $n + ',"metres":' + $metres + ',"lengthM":' + $L.ToString('0.0', $inv) + ',"step":' + $step.ToString('0.00000', $inv) +
    ',"track":"Road Atlanta","config":"Full Course","car":"Toyota GR86","lap":{"file":"fixture-lap.ibt","lap":4,"time":' + ($A.t[$n - 1]).ToString('0.000', $inv) + ',"official":null,"date":"2026-11-13T16:27:02","car":"Toyota GR86","kind":"lap"},"partial":null,"conditions":{"airC":18,"trackC":31,"windMs":2.5,"windDirDeg":200,"skies":1,"wetness":1},' +
    '"ref":{"file":"fixture-lap.ibt","lap":8,"time":' + ($R.t[$n - 1]).ToString('0.000', $inv) + ',"official":null,"date":"2026-11-13T16:27:02","car":"Toyota GR86","kind":"session"},"channels":[' + $chan + '],"multi":[],"arrays":[' + ($arrays -join ',') + '],"laps":[' + $lapRows + '],"corners":[' + ($corners -join ',') + '],"credit":"","sectorAt":[0.333333,0.666667,1.0]}'
  $hb = [Text.Encoding]::UTF8.GetBytes($head); $pad = (4 - $hb.Length % 4) % 4
  $ms = New-Object IO.MemoryStream
  $ms.Write([Text.Encoding]::ASCII.GetBytes('PWB1'), 0, 4); $ms.Write([BitConverter]::GetBytes([int]($hb.Length + $pad)), 0, 4); $ms.Write($hb, 0, $hb.Length)
  for ($i = 0; $i -lt $pad; $i++) { $ms.WriteByte(32) }
  foreach ($lap in $A, $R) {
    $b = New-Object 'byte[]' ($n * 4); [Buffer]::BlockCopy($lap.t, 0, $b, 0, $n * 4); $ms.Write($b, 0, $b.Length)
    foreach ($k in $keys) { [Buffer]::BlockCopy($lap.c[$k], 0, $b, 0, $n * 4); $ms.Write($b, 0, $b.Length) }
  }
  [IO.File]::WriteAllBytes((Join-Path $Dir 'analysis_channels.bin'), $ms.ToArray())

  $utf8 = New-Object Text.UTF8Encoding($false)
  function W($name, $text) { [IO.File]::WriteAllText((Join-Path $Dir $name), $text, $utf8) }
  function Brk($start, $peak, $lock) { '{"brake":{"startM":' + $start + ',"peakPct":' + $peak + ',"toPeakS":0.31,"releaseS":0.62,"trailS":0.4,"coastS":0.12},"abs":{"share":0.22,"peakCutPct":18},"lock":{"n":' + $lock + ',"wheel":"LF"}}' }
  $dc = for ($q = 0; $q -lt 5; $q++) { $m = [int](4000 * ($apex[$q] - 0.075)); '{"n":' + ($q + 1) + ',"me":' + (Brk $m 92 $(if ($q -eq 1) { 1 } else { 0 })) + ',"ref":' + (Brk ($m + 8) 95 0) + '}' }
  W 'analysis_deep.json' ('{"corners":[' + ($dc -join ',') + '],"stints":[],"settings":[]}')
  $sl = (1..6 | ForEach-Object {
    $ok = $_ -ne 3; $tm = 95.1 + $_ * 0.4
    '{"n":' + $_ + ',"time":' + $tm.ToString('0.000', $inv) + ',"timed":true,"valid":' + $ok.ToString().ToLower() + ',"flag":"' + $(if ($ok) { '' } else { 'OFF' }) + '","offTrack":' + (-not $ok).ToString().ToLower() +
    ',"sectors":[31.' + (100 + $_) + ',32.' + (200 + $_) + ',31.' + (300 + $_) + '],"cornerT":[4.1,5.2,3.9,6.0,4.4],"mini":[' + ((1..24 | ForEach-Object { '3.97' }) -join ',') + ']}'
  }) -join ','
  W 'analysis_session.json' ('{"laps":[' + $sl + '],"sectorAt":[0.333333,0.666667,1.0],"turns":[' + ((1..5 | ForEach-Object { '{"n":' + $_ + ',"official":"' + $_ + '","name":"Turn ' + $_ + '"}' }) -join ',') + '],"optimal":94.9,"bestSectors":[31.101,32.201,31.301],"consistency":{"n":5,"avg":96.1,"sd":0.4},"prev":null,"ever":null}')
  # /analysis/race: the smallest answer the RACE tab draws (a 4-car field, 6 laps)
  $cars = 0..3 | ForEach-Object { '{"i":' + $_ + ',"num":"' + (10 + $_) + '","name":"Driver ' + $_ + '","car":"Toyota GR86","path":"toyotagr86","col":"#d8d4ca","cls":"c1","clsName":"GR86"}' }
  $tower = 0..3 | ForEach-Object { '{"i":' + $_ + ',"pos":' + ($_ + 1) + ',"cpos":' + ($_ + 1) + ',"simPos":' + ($_ + 1) + ',"laps":6,"total":' + (570 + $_ * 2.5).ToString('0.000', $inv) + ',"gap":' + ($_ * 2.5).ToString('0.000', $inv) + ',"gapLaps":0,"ahead":2.5,"aheadLaps":0,"best":' + (95.2 + $_ * 0.2).ToString('0.000', $inv) + ',"bestLap":4,"bestSrc":"log","fastest":' + $(if ($_ -eq 0) { 'true' } else { 'false' }) + ',"pits":0,"pitLane":0.0,"stall":0.0,"inc":' + $_ + ',"out":false,"reason":"","off":0}' }
  $trace = foreach ($ci in 0..3) { '{"i":' + $ci + ',"g":[' + ((1..6 | ForEach-Object { ($ci * 2.5 + $_ * 0.1).ToString('0.000', $inv) }) -join ',') + '],"p":[' + ((1..6 | ForEach-Object { $ci + 1 }) -join ',') + '],"pit":[]}' }
  $sum = '{"race":true,"focus":"c1","maxLap":6,"prec":{"hz":10,"cornerS":0.05,"lapS":0.02,"gapS":0.02,"pitS":0.1},"ahead":1,"behind":3,"leader":0,"classes":[{"id":"c1","name":"GR86","col":"#d8d4ca","cars":4}],"tower":[' + ($tower -join ',') + '],"posMismatch":0,"trace":[' + ($trace -join ',') + '],"cm":[],"passes":[],"pits":[]}'
  W 'analysis_race.json' $(if ($Race) { '{"ok":true,"complete":true,"me":2,"cars":[' + ($cars -join ',') + '],"corners":[],"summary":' + $sum + '}' } else { '{"error":"no field log for this session"}' })
  W 'vault.json' ('{"enabled":true,"cosworth":{"installed":' + $Pi.ToString().ToLower() + ',"exe":"C:\\Pi\\toolbox.exe"}}')
  W 'vault_tools.json' ('{"pi":{"installed":' + $Pi.ToString().ToLower() + '},"delta":{"installed":' + $Delta.ToString().ToLower() + '}}')
  # the review engine's answer the module reads when MORE DATA arrives with a session and no lap (session.id = the telemetry file name)
  $rv = '{"session":{"id":"fixture-lap.ibt","best":{"lap":4,"time":82.567}},"laps":[{"n":3,"counted":false},{"n":4,"counted":true}]}'
  if ($NoLaps) { $rv = '{"session":{"id":"fixture-lap.ibt","best":null},"laps":[]}' }
  W 'api_review.json' $rv
  W 'workbench_state.json' '{"open":false}'
  W 'analysis_pro_export.txt' "distance,speed`n0,60`n"
  W 'vault_open.json' '{"ok":true,"action":"cosworth","dry":false}'
  W 'health.json' '{"ok":true}'
}
