# Pretend irdash answers for the deck tests (tests\deck-speed-test.ps1, tests\mydrive-test.ps1). Shapes are the real /mydrive JSON.

function New-MyDriveCombo($id, $car, $carShort, $track, $trackShort, $layout, $chosen = $false, $ago = 'today') {
  $c = [ordered]@{ id = $id; car = $car; carShort = $carShort; track = $track; trackShort = $trackShort }
  if ($layout) { $c['layout'] = $layout }   # recent drives carry no layout (irdash does not know it); favourites do
  $c['chosen'] = $chosen; $c['ago'] = $ago
  $c
}

# the same with a count of drives (the "all" list of /mydrive: USUAL, SAME CAR, SAME TRACK, SURPRISE read it)
function New-MyDriveCounted($id, $car, $carShort, $track, $trackShort, $n, $chosen = $false, $ago = 'today') {
  $c = New-MyDriveCombo $id $car $carShort $track $trackShort $null $chosen $ago
  $c['n'] = $n
  $c
}

# /mydrive as it looks out of the car with a few recent drives and two favourites
function New-MyDriveFixture {
  [ordered]@{
    ready = $true; open = $true; session = $false; driving = $false; busy = ''; phase = ''; msg = ''
    choice = [ordered]@{ has = $true; car = 'Chevrolet Corvette Z06 GT3.R'; carShort = 'CORVETTE GT3'; track = 'Road Atlanta'; trackShort = 'ROAD ATLANTA'; layout = ''; damage = 'on'; fav = $false }
    recent = @(
      (New-MyDriveCombo 'r00000001' 'Chevrolet Corvette Z06 GT3.R' 'CORVETTE GT3' 'Road Atlanta' 'ROAD ATLANTA' $null $true),
      (New-MyDriveCombo 'r00000002' 'Ferrari 296 Challenge' '296 Challenge' 'Sebring International Raceway' 'Sebring' $null $false 'yesterday'),
      (New-MyDriveCombo 'r00000003' 'Porsche 911 Cup (992.2)' '911 CUP' 'Sebring International Raceway' 'Sebring' $null $false 'yesterday'),
      (New-MyDriveCombo 'r00000004' 'Toyota GR86' 'GR86' 'Lime Rock Park' 'LIME ROCK' $null $false 'Monday'),
      (New-MyDriveCombo 'r00000005' 'Ford Mustang GT3' 'Mustang GT3' 'Sebring International Raceway' 'Sebring' $null $false 'Monday'),
      (New-MyDriveCombo 'r00000006' 'BMW M2 Racing (G87)' 'BMW M2' 'Tsukuba Circuit 2k Full' 'Tsukuba Circuit 2k Full' $null $false '5 days ago')
    )
    favs = @(
      (New-MyDriveCombo 'f00000001' 'Chevrolet Corvette Z06 GT3.R' 'CORVETTE GT3' 'Road Atlanta' 'ROAD ATLANTA' 'Full Course' $true),
      (New-MyDriveCombo 'f00000002' 'Toyota GR86' 'GR86' 'Lime Rock Park' 'LIME ROCK' 'Grand Prix' $false)
    )
    all = @(
      (New-MyDriveCounted 'r00000001' 'Chevrolet Corvette Z06 GT3.R' 'CORVETTE GT3' 'Road Atlanta' 'ROAD ATLANTA' 14 $true),
      (New-MyDriveCounted 'r00000002' 'Ferrari 296 Challenge' '296 Challenge' 'Sebring International Raceway' 'Sebring' 9 $false 'yesterday'),
      (New-MyDriveCounted 'r00000003' 'Porsche 911 Cup (992.2)' '911 CUP' 'Sebring International Raceway' 'Sebring' 7 $false 'yesterday'),
      (New-MyDriveCounted 'r00000004' 'Toyota GR86' 'GR86' 'Lime Rock Park' 'LIME ROCK' 6 $false 'Monday'),
      (New-MyDriveCounted 'r00000005' 'Ford Mustang GT3' 'Mustang GT3' 'Sebring International Raceway' 'Sebring' 3 $false 'Monday'),
      (New-MyDriveCounted 'r00000006' 'BMW M2 Racing (G87)' 'BMW M2' 'Tsukuba Circuit 2k Full' 'Tsukuba Circuit 2k Full' 2 $false '5 days ago'),
      (New-MyDriveCounted 'r00000007' 'Chevrolet Corvette Z06 GT3.R' 'CORVETTE GT3' 'Sebring International Raceway' 'Sebring' 4 $false '6 days ago'),
      (New-MyDriveCounted 'r00000008' 'Ford Mustang GT3' 'Mustang GT3' 'Road Atlanta' 'ROAD ATLANTA' 1 $false '8 days ago')
    )
    favCount = 2; current = $null; results = $null; draft = $null
    last = [ordered]@{ secs = 41; seq = 1; age = 300; car = 'Chevrolet Corvette Z06 GT3.R'; track = 'Road Atlanta' }
    speedtest = [ordered]@{ seq = 0; which = '' }
  }
}

# a finished search for the deck's results view
function New-MyDriveResults($kind, $q, $names, $ok = $true, $msg = '') {
  $items = @(); $i = 0
  foreach ($n in $names) { $i++; $items += [ordered]@{ id = ('s{0:x8}' -f $i); name = $n; short = $n } }
  [ordered]@{ kind = $kind; q = $q; at = '63926762789000' + $i; ok = $ok; msg = $msg; items = $items }
}

# /workbench/state as irdash sends it while the workbench shows lap 7 (dash\src\deckfeed.cs)
function New-AnalysisFixture {
  [ordered]@{ open = $true; age = 0; driving = $false; page = 'driver'; pages = @('driver', 'grip'); playing = $false; speed = 1; tile = $false; axis = 'dist'; mapColour = 'gap'
    offsetMode = $false; offset = 0; zoomed = $false; id = 'l20261010-041318-7'; lap = 7; ref = 'pb'; laps = 8; events = 5; corners = 12; lapTime = 79.549; refTime = 79.575; refLap = 3
    car = 'Chevrolet Corvette Z06 GT3.R'; track = 'Road Atlanta' }
}

# /sound as irdash sends it (what irdeck sound status wrote, dash\src\sound.cs adds ready / age / busy)
function New-SoundFixture {
  [ordered]@{ ok = $true; ready = $true; age = 1; busy = $false; pretend = $true
    items = @(
      [ordered]@{ id = 'sim'; name = 'GAME'; kind = 'app'; live = $true; vol = 70; mute = $false; device = 'Speakers (Realtek USB2.0 Audio)' },
      [ordered]@{ id = 'spotter'; name = 'SPOTTER'; kind = 'app'; live = $true; vol = 90; mute = $false; device = 'Speakers (Realtek USB2.0 Audio)' },
      [ordered]@{ id = 'music'; name = 'MUSIC'; kind = 'app'; live = $true; vol = 40; mute = $false; device = 'Speakers (ButtKicker PRO)' },
      [ordered]@{ id = 'speakers'; name = 'SPEAKERS'; kind = 'device'; live = $true; vol = 50; mute = $false; device = 'Speakers (Realtek USB2.0 Audio)' },
      [ordered]@{ id = 'buttkicker'; name = 'BUTTKICKER'; kind = 'device'; live = $true; vol = 30; mute = $false; device = 'Speakers (ButtKicker PRO)' } )
    default = 'Speakers (ButtKicker PRO)'; using = 'Speakers (Realtek USB2.0 Audio)'; preset = ''; devices = 3 }
}