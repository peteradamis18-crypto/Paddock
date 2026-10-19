# Paddock — operations

Build, deploy, test and recover. Run every command from PowerShell on this PC. The repo is `C:\Users\peter\iRacingDeck`. Nothing here needs a download, an install, or a password.

Agents do not run `deck-intro\install.ps1` or `build-deck.ps1`. Those are in section 10 for the lead. Peter clicks Install himself.

## 1. Is the rig free?

```
& 'C:\Users\peter\iRacingDeck\irdeck-cli.exe' state
```

Read the last line.

| Last line contains | Meaning | Deploy, restart, or a test that touches an app |
|---|---|---|
| `telemetry=on` or `onTrack=True` | He is in a session. | No. |
| `sim=True` | The sim process is up (loading counts). | No. |
| `sim=False` and `telemetry=off` | The sim is not running. | Yes, unless a START key was pressed in the last 10 minutes (below). |

`ui=True` only means the iRacing app is open. That is normal when he is out of the car.

Also look at `dash\start-mark.txt`. A test or irdash writes it when a session starts. If the stamp is under 10 minutes old and the second field is not `TEST`, treat the rig as busy. `dash\build.ps1` and `tests\guard.ps1` both do this (`Get-RigBusy`). `build-irdeck.ps1` does not: it only refuses when the state line contains `telemetry=on`. Wait until `sim=False` anyway. Replacing `keys\*.exe` while the sim process is up is the wrong time.

Compiling with `-NoDeploy` does not restart anything. That is allowed while he is in the car. Section 4.

## 2. Build and deploy irdeck

New C# for irdeck goes in `src\` and onto the `$src` line in `build-irdeck.ps1`. The compiler is Windows' own `csc` (C# 5). No SDK, no NuGet.

Compile only, output in `%TEMP%\ird`:

```
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\build-irdeck.ps1 -NoDeploy
```

Exit 0 and the line `built in ... (not deployed)` means both exes compiled. Exit 1 and `build failed (irdeck.exe)` or `build failed (irdeck-cli.exe)` means the compiler printed an error above that line. Nothing was copied.

Deploy (rig free, section 1):

```
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\build-irdeck.ps1
```

What it does:

1. Compiles `irdeck.exe` and `irdeck-cli.exe` into `%TEMP%\ird`.
2. Runs `irdeck-cli.exe state`. If that line contains `telemetry=on`, it prints `iRacing is in a session - deploy when you are out of the car.` and exits 1. The new exes stay in `%TEMP%\ird`. Run the same command again when section 1 is clear. Do not copy them by hand.
3. Copies both exes into `C:\Users\peter\iRacingDeck\`.
4. Copies the new `irdeck.exe` over every `keys\*.exe` whose hash matched the old `irdeck.exe`.

Success is the line `deployed irdeck.exe and irdeck-cli.exe; updated N of M key copies`. A warning `key <name> is in use` means that one file was locked (Stream Deck had it open). It keeps the old exe. Run the deploy once more when the rig is free; the next run updates keys that still match the previous hash.

## 3. Build and deploy irdash

This is the only way to put a new `irdash.exe` on the rig. New C# goes on the `$src` line in `dash\build.ps1`. `dash\src\probe.cs` is a separate program; the script already compiles it.

Compile only, output in `%TEMP%\irdash-build-<pid>`:

```
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\dash\build.ps1 -NoDeploy
```

Exit 0 and `built in ... (not deployed)`. Exit 1 and `build failed (irdash.exe)` or `build failed (probe.exe)` is a compiler error. Nothing was stopped or copied.

Deploy (rig free, section 1):

```
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\dash\build.ps1
```

What it does, in order:

1. Compiles `irdash.exe` and `probe.exe` into `%TEMP%\irdash-build-<pid>`.
2. Dot-sources `tests\guard.ps1`. If `Get-RigBusy` returns a reason, it prints `not deployed: <reason>` and exits **2**. The new build stays in that temp folder.
3. If `dash\deploy.lock` exists and is under 15 minutes old, it prints `not deployed: a test holds the deploy lock (...)` and exits **2**.
4. Waits up to 120 seconds on the mutex `Local\paddock-irdash-deploy`. If it cannot take it, it prints `not deployed: another deploy is in progress` and exits **2**.
5. Checks `Get-RigBusy` again.
6. If irdash was running, stops it, copies both exes into `dash\`, and starts `dash\irdash.exe` through Explorer. If it was not running, it copies the files and does not start it.
7. If the copy throws, it prints `deploy FAILED: ...`, starts the old irdash again through Explorer when it had been running, and exits 1.

Success is `built C:\Users\peter\iRacingDeck\dash\irdash.exe and probe.exe`. Exit 2 means try the same command later. Do not copy the temp exe over `dash\irdash.exe` yourself, and do not kill irdash, irdashies, CrewChief or Stream Deck to force it.

`www` files need no compile. The dashboard reads them from `dash\www`. It reloads when `/version` changes, and it waits until he is off track.

## 4. Compile while he is in the car

Allowed: edit source and `dash\www`, and the two `-NoDeploy` commands above. Also allowed later: an offline test that only reads old `.ibt` files.

Not allowed until section 1 is clear: either deploy, `install.ps1`, `build-deck.ps1`, starting or stopping an app, a test that uses the test hook, opening windows on his screens.

## 5. Run the tests (run-all)

One command. It waits until the rig is free. It does not deploy.

```
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\tests\run-all.ps1
```

Optional:

```
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\tests\run-all.ps1 -Only corners,perf
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\tests\run-all.ps1 -WaitMinutes 90
```

`-WaitMinutes` defaults to 90. `-Only` takes the short names below, separated by commas.

What it does:

1. Sets its own priority to BelowNormal.
2. Takes mutex `Local\paddock-run-all`. If another run-all (or `run-replay-live.ps1`) holds it, it prints `run-all is already running.` and exits 0. That exit code is not a test result. Wait for the other run. Its summary is still `tests\run-all.last.txt` from that other run.
3. For each test, waits until `Get-RigBusy` is clear, `dash\deploy.lock` is absent or older than 15 minutes, and `dash\test-hook.on` is absent. It polls every 30 seconds, up to `-WaitMinutes`.
4. Runs that test in a child PowerShell. Writes the transcript to `tests\last\<name>.txt`.
5. Writes every summary line to `tests\run-all.last.txt` and prints the same lines.

The process exit code is not the result. Read `tests\run-all.last.txt`.

| Line | Meaning |
|---|---|
| `corners      75 ok,  0 FAIL  (exit 0, 40 s)` | That test passed. The counts are lines matching `ok` and `FAIL`. |
| `data          3 ok,  3 FAIL  (exit 1, 90 s)` followed by indented `FAIL` lines | Those checks failed. The indented lines are the reasons. |
| `friends-live SKIPPED: Peter used the PC less than 10 minutes ago` | The wait ended and this test never started. |
| `friends-live SKIPPED: the iRacing sim is running` | Same, for a busy rig. |
| `(no ok/FAIL lines: ...)` | The script produced no checks. Read `tests\last\<name>.txt`. |

A clean run is every line at `0 FAIL`, no `SKIPPED`, and no `(no ok/FAIL lines)`.

Tests, in order:

| Name | Script | Extra argument | Waits until he has not touched the PC for 10 minutes |
|---|---|---|---|
| corners | `corners-test.ps1` | | no |
| perf | `perf-test.ps1` | | no |
| pbdelta | `pbdelta-test.ps1` | | no |
| bench | `bench-test.ps1` | | no |
| data | `data-test.ps1` | | no |
| overlays | `overlays-test.ps1` | | no |
| dialog | `dialog-links-test.ps1` | | no |
| friends | `friends-test.ps1` | | no |
| friends-live | `friends-live-test.ps1` | | yes |
| replay | `replay-test.ps1` | | no |
| mydrive | `mydrive-test.ps1` | `-DeckOnly` | no |
| deckspeed | `deck-speed-test.ps1` | | no |
| gallery | `gallery-test.ps1` | `-PeterIsAway` | yes |

`friends-live` and `gallery` will not start until keyboard and mouse have been idle for 10 minutes. run-all applies that to the whole script, so their offline checks also wait. If he uses the PC during the 90 minutes, those two lines say `SKIPPED` and the others still run. To include them, start run-all when he is away, or run them on their own after 10 quiet minutes (section 6).

Screenshots land in `tests\shots\`.

## 6. Tests that run-all does not start

These start the real sim or click in the iRacing app. Run them only when section 1 is clear and he has been away from the keyboard and mouse for 10 minutes. Each script calls `Assert-RigFree -NeedAway` before that part.

Live replay. It waits up to 180 minutes for a free rig and 10 quiet minutes, then runs `replay-test.ps1 -Live`. Output: `tests\last\replay-live.txt`. Same mutex as run-all, so it waits if run-all is in progress.

```
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\tests\run-replay-live.ps1
```

Friends live section, on its own. The offline section runs whenever the sim is stopped. The Test Drive runs only after 10 quiet minutes; otherwise the script prints `PENDING live:` and the exact command to repeat.

```
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\tests\friends-live-test.ps1
```

Action keys (real sim). Flags `-NoFriends` and `-NoTestDrive` exist; omit them for the full test.

```
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\tests\actions-test.ps1
```

My Drive including the real START (run-all already ran the deck-only part):

```
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\tests\mydrive-test.ps1
```

Gallery window part, when run-all skipped it. Without `-PeterIsAway` the script runs the file checks and skips the windows if he is not away (exit 4, pending line in the output).

```
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\tests\gallery-test.ps1
```

Not in run-all, and not required to call the suite green: `vault-test.ps1`, `official-test.ps1`, `tv-test.ps1`, `doctor-test.ps1`. Vault and official stay switched off in `irdash.ini`.

## 7. Guard, lock, mutex

**Guard.** Every test starts with:

```
. (Join-Path $PSScriptRoot 'guard.ps1')
Assert-RigFree
```

and calls `Section 'n. ...'` before each part (that calls `Assert-RigFree -Where` and throws, so the test's `finally` puts things back). `Assert-RigFree -NeedAway` also requires 10 minutes with no keyboard or mouse input.

`Get-RigBusy` returns a reason when `iRacingSim64DX11` is running, or when `dash\start-mark.txt` shows a non-TEST start under 10 minutes old. A test that started the sim itself sets `$env:RIG_TEST_OWNS_SIM=1` so its own sim does not trip the guard.

If the guard stops a test at the door, the output is `NOT SAFE TO TEST: ...` and the exit code is 3. Nothing was changed.

**Test hook.** irdash answers pretend-session routes only when the file `dash\test-hook.on` exists and `Sdk.RealBusy()` is null. RealBusy is the same idea as the guard: sim process, SDK connected, or a START key in the last 10 minutes. A refused hook is HTTP 409 and a line `test hook refused:` in `dash\irdash.log`. Tests create the file and delete it in `finally`.

**Deploy lock.** A test that needs the running irdash writes `dash\deploy.lock` (the text is the test name and the time) and deletes it in `finally`. `dash\build.ps1` and run-all treat a lock under 15 minutes old as held. An older lock is ignored.

**Mutexes.**

| Name | Who | If it is taken |
|---|---|---|
| `Local\paddock-irdash-deploy` | `dash\build.ps1` | the other deploy waits up to 120 seconds, then exits 2 |
| `Local\paddock-run-all` | `tests\run-all.ps1`, `tests\run-replay-live.ps1` | run-all exits 0 with `run-all is already running.`; the live replay runner waits |
| `Local\IRDashSingleInstance` | `irdash.exe` | the second process asks the first to open the dashboard and exits |
| `Local\irdeck-key-<name>` | a MAIN key exe | a repeat press within 0.7 seconds is ignored |
| `Local\irdeck-ovl` | overlay edits | one edit at a time |
| `Local\irdeck-mydrive-ui` | My Drive, and the official-racing draft, when they click in the iRacing app | one of those passes at a time |

## 8. Logs

| File | What a line looks like | When it is useful |
|---|---|---|
| `irdeck.log` | `yyyy-MM-dd HH:mm:ss.fff  <message>`. Deleted when it grows past 200000 bytes. | Every key command. `rigon:` lines are the boot sequence. `state:` is the rig check. |
| `dash\irdash.log` | irdash's own lines (`irdash starting on port 8199`, `watchdog:`, `test hook refused:`, `deploy` is not here) | Dashboard, doctor, delta bar, gallery, a refused test hook |
| `dash\timings.tsv` | boot, START, in-car, sim exit | Rig Doctor and the idle screen |
| `dash\probe.txt` | what `probe.exe` could see | Doctor thought an app was missing and it was only a private AppData |
| `tests\run-all.last.txt` | one line per test | The result of the last run-all |
| `tests\last\<name>.txt` | the full transcript | The FAIL lines and anything before them |
| `%APPDATA%\Elgato\StreamDeck\logs\StreamDeck.log` | Elgato's log | Watchdog reads the tail for USB disconnects |

`irdeck-cli.exe` also prints its log line to the console. `irdeck.exe` only writes the file.

## 9. Recover

Do these only when section 1 says the rig is free, unless the row says the watchdog already did it.

**irdash deploy exited 2.** Read the `not deployed:` line. Wait until that reason is gone (sim closed, START older than 10 minutes, lock older than 15 minutes, or the other deploy finished) and run `dash\build.ps1` again. The compiled files are in the `%TEMP%\irdash-build-<pid>` folder named in the message. They are not installed.

**irdash deploy printed `deploy FAILED`.** The copy could not replace the exe. If irdash had been running, the script started the old exe through Explorer. Close whatever is locking `dash\irdash.exe` (a second build, a test still running) and run `dash\build.ps1` again.

**irdash is not running and the top screen is blank.** Start it through Explorer so it is not tied to the window that launched it:

```
Start-Process explorer.exe -ArgumentList '"C:\Users\peter\iRacingDeck\dash\irdash.exe"'
```

A second start while one is already running is harmless: mutex `Local\IRDashSingleInstance`, then `GET /api/open`.

**A message says irdash could not use port 8199.** Do not change `port=` in `irdash.ini`. The add-on and the tests call 8199. When the rig is free, run `dash\build.ps1`. That stops a stuck irdash and starts a fresh one. If the message comes back, something else is listening. Find it with `netstat -ano -p tcp | findstr :8199` and stop that process only if it is not the sim and section 1 is clear.

**A key still runs old code after an irdeck deploy.** The deploy warned that the exe was in use. Run `build-irdeck.ps1` again when the rig is free.

**`deploy.lock` or `test-hook.on` left behind.** A test deletes both in `finally`. If a test was killed, the lock blocks deploy for 15 minutes and the hook can answer pretend-session routes. Confirm no `powershell` is running a script under `tests\`, then delete `dash\deploy.lock` and `dash\test-hook.on`. A lock older than 15 minutes does not block deploy.

**run-all says it is already running.** Another run holds `Local\paddock-run-all`. Leave it. Read `tests\run-all.last.txt` when `run-all finished` appears at the bottom. Do not start a second one.

**Stream Deck keys are dead, sim is not running.** irdash's watchdog restarts Stream Deck after 10 seconds away, or after a USB blip if the device is still plugged in. If the keys are still dead after a minute, look for `watchdog:` in `dash\irdash.log`. When section 1 is clear, the RIG ON key (or `irdeck.exe rigon`) starts Stream Deck and the rest. Give boot a minute: at logon, Stream Deck is given the machine first.

**Sim stuck on a black launch, and he is not in a session.** The watchdog ends `start_protected_game` and a frozen `iRacingSim64DX11` and starts the iRacing UI again. It will not do that while the SDK is connected, and it stops after three tries in an hour. The line is `watchdog: cleared a stuck launch`. He starts the session again from the UI. If the watchdog has given up, quit the iRacing UI from its own window when section 1 is clear and press RIG ON.

**Dashboard shows yesterday's layout during a race.** It is waiting on purpose. It reloads after he leaves the track.

**Boot starts everything at once and the deck is slow.** Delete `boot-stagger.off` if that file is in the repo root. The next logon then waits for Stream Deck before the other apps. The log line is `rigon: Stream Deck is ready after N s`.

**Bring the whole rig up.** Press RIG ON, or run:

```
& 'C:\Users\peter\iRacingDeck\irdeck.exe' rigon
```

Logon already runs `irdeck.exe rigon --boot` via the task "iRacing Rig". Do not create a second task.

## 10. Stream Deck add-on and MAIN page (lead only)

Agents never run these. One batch, then Peter clicks Install once.

Add-on, after `deck-intro\plugin.html` changes. Bump `$ver` in `deck-intro\install.ps1` first (the file says why: Stream Deck treats a higher version as an update). The source is at 1.6.1.0. The script refuses when `telemetry=on`.

```
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\deck-intro\install.ps1
```

It opens the `.streamDeckPlugin` through Explorer. Stream Deck asks once. Peter clicks Install. Do not copy the plugin folder into `%APPDATA%\Elgato` by hand. A hand-copied folder never gets the bundled profiles.

**Order matters (2026-10-18):** when the add-on version changed, click Install FIRST, then run the MAIN page steps below. Stream Deck's install rewrote the MAIN profile and its key pictures went missing (112 'custom image missing' lines, blank keys) after a build-deck done before the install. Run build-deck again after the install and the deck is whole.

**Use `powershell -ExecutionPolicy Bypass -File tools\deck-refresh.ps1`** for the MAIN page: it closes Stream Deck, runs build-deck, starts it, and CHECKS that both pages kept their pictures (Stream Deck sometimes drops the MAIN page at start; it retries up to 4 times). The manual steps below are what it does.

MAIN page, after `build-deck.ps1` or `keys\keys.map` changes. Stream Deck must be closed or the script throws `Close Stream Deck first`. When section 1 is clear:

```
Get-Process StreamDeck -ErrorAction SilentlyContinue | Stop-Process
powershell -ExecutionPolicy Bypass -File C:\Users\peter\iRacingDeck\build-deck.ps1
Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '"C:\Program Files\Elgato\StreamDeck\StreamDeck.exe" --runinbk' }
```

The CIM start keeps Stream Deck out of a packaged app's private AppData. Success is a line that starts with `built: MAIN`. Preview without touching the profile: `build-deck.ps1 -Preview` (writes `C:\Temp\preview\`).

`-Preview` is the only deck command that is safe while he is in the car. The real build is not.

## 11. Do not

- Do not write `Documents\iRacing\`, `controls.cfg`, or anything under `C:\Program Files (x86)\iRacing\`. Graphics changes go through `gfx-set.ps1`, which backs up and refuses while the sim runs. It is not part of a normal build.
- Do not change port 8199, the exe names, the add-on UUID, or the logon task command.
- Do not deploy irdash except with `dash\build.ps1`.
- Do not kill irdash, irdashies, CrewChief or Stream Deck by hand during a session. Section 9 is the recover path when the rig is free.
- Do not run a test that fails `Assert-RigFree`. Exit 3 means stop.
- Do not enter passwords, download tools, or change Windows security settings from a task. Peter already approved ffmpeg; it is in `vault\bin\`.
