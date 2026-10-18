# Cosworth Pi Toolbox: add-in / automation findings (2026-10-18, read-only)

## Version and edition
- `Pi Toolbox.exe` file version 5.193.2752, product 14.0 (assemblies 14.0.2752.2). Cosworth Electronics Ltd.
- Edition: **Lite** (free, no licence key). Evidence: HKLM `Pi Research\Pi Toolbox\Controls\*` values `License=Lite/Plus`; no licence file; docs\cosworth.md. PiToolbox.txt:4187 says only Lite runs without a key.
- Pi Data Access Objects are also installed (`C:\Program Files\Pi Data Access Objects`: PiDataAccess.dll, DAE.dll).

## Add-in / automation support
- **Add-in Manager exists** (PiToolbox.txt:207-216): it ticks "Add-in modules" and puts their commands in the Tools menu. Modules found are in `Pi Toolbox\Tools` (AdvancedMath, ChannelMetrics, PopUpAlarms) plus `Export` and `Controls` folders: these are Cosworth's own .NET assemblies, loaded by the app.
- **Developer API exists but is a data-analysis library, not an automation interface.** `Pi.Research.DataAnalysis.txt` documents version 6.2 classes (Outing, DataSelection, DatumIndex, TimeRegionFinder, PlaybackController, ADM, LicensingStatus). It lets a .NET module read outings and channels inside Pi. Nothing in the help text describes a way to drive Pi from outside, or to push state out. Edition restriction for writing add-ins: not stated (unknown).
- **No COM/automation:** HKLM\SOFTWARE\Classes has no `Pi.*` or `Cosworth*` ProgIDs, only file types (`Pi.Dataset`, `PiToolbox.Workbook`, `PiToolbox.TrackLibrary`, etc.). The exe contains `AVCTbxAppCommandLineInfo` and `CreateNamedPipeW` only.
- A custom add-in would need a .NET assembly built against Pi's DLLs, registered through a mechanism the help does not document, and it would be loaded by Pi (changing Pi's install/Tools folder). Unknown whether Lite loads third-party modules. Not tested (rule: no changes to Pi).

## Command line
- One `.pwb` workbook, or a `.pds`/dataset to load into the "external load" task (PiToolbox.txt:1934-1954). External load rules: add or replace an outing in the nominated task; with several tasks it shows a dialog.
- No documented switch to set datum/reference or choose a lap. Datum is set via the outing's pop-up menu only (PiToolbox.txt:1795-1805).
- Pi's file-forwarding pipe is `\\.\pipe\TBX_INSTANCE_FILEOPEN_PIPE` (docs\cosworth.md). It is write-only input: no reply with state.

## Readable state for verification
- `HKCU\Software\Pi Research\Pi Toolbox\Recent File List`: **empty** now (Pi writes it, if at all, on exit/save). It would only list workbooks, never outings or datum.
- `cosworth\Paddock.pwb`: 2,557,440 bytes, last written 2026-10-06 11:29 (never changed by lap loads unless Peter saves). Binary OLE2, undocumented. Not a live signal.
- Window title: `Paddock - Pi Toolbox` and a trailing `*` when dirty. That is the current heuristic; it proves "a workbook is open and something changed", not which outing or whether the PB is the datum.
- `%LOCALAPPDATA%\Pi Toolbox` holds only Sentry crash data; `%APPDATA%\Cosworth` and `Local\Cosworth` hold licensing preferences/token cache. Nothing logs loaded outings. (Windows Recent has `Paddock.lnk`, 10-15 12:50, which only shows the workbook was opened.) A Sentry event at the same minute suggests Pi crashed or was killed then.

## Recommendation: (c), with a possible long-shot (a)
Pi Lite exposes **no readable record of the loaded outing or datum**, and no supported automation channel. No file or registry verification (b) exists. Keep the title heuristic and be honest with Peter: Paddock can confirm "Pi opened Paddock and accepted a file" (title change, and `*`), not "the right lap is the reference".

Practical hardening that needs no change to Pi: verify the outing was added by watching the title gain `*`; send the lap, then a UI-Automation read-only look at Pi's Outing list (window text tree) is a possible check, but not tested here and subject to Peter's click rules (read only, never while driving).

Option (a) is only worth trying if Peter wants it: write a small .NET add-in against `Pi.Research.DataAnalysis.dll`, which could report the current outings and datum to irdash. It needs a trial in a scratch copy of Pi first, because Lite may refuse third-party modules and the registration format is undocumented.
