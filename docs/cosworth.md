# Cosworth Pi Toolbox - install, open method and limits

Paddock's **OPEN IN COSWORTH** button opens a lap's telemetry in Cosworth Pi Toolbox. Everything here was checked on Peter's PC
on 2026-10-12 (card W-18); the free **Lite** edition is installed and reads iRacing `.ibt` files. Nothing in this file writes
to iRacing's files or to Pi's install folder.

## The install on this PC

| What | Value |
|---|---|
| Product | Cosworth Pi Toolbox, version **14.0.2752.2** |
| Install folder | `C:\Program Files\Pi Toolbox` |
| Executable | `C:\Program Files\Pi Toolbox\Pi Toolbox.exe` |
| Process name | `Pi Toolbox` |
| Main window title | `Untitled - Pi Toolbox` (no workbook) or `<workbook name> - Pi Toolbox` (a workbook is open) |
| iRacing workbook template | `C:\Program Files\Pi Toolbox\Templates\Sim\iRacing Lite Workbook - v1.2.pwb` (read-only source) |
| Paddock workbook | `C:\Users\peter\iRacingDeck\cosworth\Paddock.pwb` (created from the template if missing) |
| Pi user folder (workbooks) | `C:\Users\peter\OneDrive\Documents\`, registered as **My Documents** in `HKCU\Software\Pi Research\Pi Toolbox\Document Locations\Place 2` |
| Workbook extension | `.pwb` (Pi's own workbook format) |
| User data folder | `C:\Users\peter\AppData\Local\Pi Toolbox` (crash reports only; workbooks are not stored there yet) |
| Settings | `HKCU\Software\Pi Research\Pi Toolbox` |

`Pi Toolbox.exe` is also the program registered for the `.ibt` file type (`HKEY_CLASSES_ROOT\iRacing.Dataset\shell\open\command`
= `"...Pi Toolbox.exe" "%1"`), so the same command line is used whether Paddock starts the exe itself or asks Explorer to open
the file.

## The verified open method

Pi Toolbox accepts **one workbook (`.pwb`) on its command line**. A data file (`.ibt` / `.pds`) is *not* a document: a cold
launch with only a data file just shows Pi's **New Workbook** dialog and the path is dropped. The data file is only taken when
**Pi is already running with a workbook open**: a second launch forwards the path over Pi's own instance pipe
(`\\.\pipe\TBX_INSTANCE_FILEOPEN_PIPE`) and Pi imports it as an outing under the current task.

The lead proved this sequence live on 2026-10-12:

1. Never pass the Program Files template to Pi: it treats a template as a request for its New Workbook dialog. If `cosworth\Paddock.pwb` is missing, copy the template there and clear the copy's read-only flag. Never modify the template.
2. Start `Pi Toolbox.exe` directly (`UseShellExecute=false`), never through Explorer, with the writable `Paddock.pwb` path. This opens `Paddock - Pi Toolbox`.
3. When Pi is cold or its title starts with `Untitled`, launch the workbook and poll the title every 250 ms for up to 30 seconds. Forward the lap only after the title starts with `Paddock - Pi Toolbox`.
4. When Pi already shows any workbook title, forward the lap directly. A second direct Pi launch with the `.ibt` path imports it as an outing. The successful import marks the workbook dirty: the title ends in `*` (or was already marked `*`).

Each step is logged in `dash\irdash.log` with the executable, argument and resulting title. The route checks driving state before the workbook launch and lap forward; it refuses while driving.

Live evidence: the copied workbook opened as `Paddock - Pi Toolbox`; forwarding a lap added its outing under the iRacing task and changed the title to `Paddock - Pi Toolbox*`.

Do **not** pass the template or pass a lap while Pi is cold: Pi shows the New Workbook chooser and drops the path. Pi titles the window with the workbook, not the `.ibt` file name.

## Paddock's ready workbook (W-19)

W-19 wanted Paddock's own workbook (speed, throttle, brake, steering, gear, delta and the PB as the datum outing) to be the one
opened in step 2, so Pi comes up already set up instead of on the stock iRacing Lite template. **It stops here: the workbook
format is binary and undocumented.**

- Pi writes workbooks as `.pwb`. The installed iRacing Lite workbook
  `C:\Program Files\Pi Toolbox\Templates\Sim\iRacing Lite Workbook - v1.2.pwb` (read-only) is a **binary OLE2 / Compound File
  Binary** (`d0 cf 11 e0 a1 b1 1a e1`), not text, not XML and not a ZIP of readable XML. Its two and a half megabytes hold a
  serialised object graph (display names, channel equations, maths registers) with no plain-text or XML form, and Cosworth does
  not document the layout. Editing it means re-serialising a binary object graph Paddock does not know.
- So `tools\cosworth-workbook.ps1` reports **`NOT SUPPORTED`** and writes nothing for OLE2, text, XML, ZIP, and unknown
  formats. A format is unsupported until Paddock can edit and verify the actual display structure and PB datum. The script
  exits with status 3 for this documented stop. `-Check` prints the format decision and the path it would use,
  `C:\Users\peter\OneDrive\Documents\Paddock.pwb` (Pi's user folder), without changing anything. It refuses destinations
  under `Documents\iRacing` or an iRacing install folder.
- Paddock still opens the lap exactly as W-18 did: `cosworth\Paddock.pwb` (the W-18 copy of the template) opens in Pi and the
  lap is forwarded as an outing. The user-folder workbook is not selected as ready because its worksheet configuration has
  not been verified. The six displays and PB datum remain unavailable until a format-specific editor and structural checks exist.

### Fallback

If Pi is not installed (`installed:false` in `/vault` and `/vault/item`), the button is hidden and `/vault/open` opens
Explorer with the telemetry file selected. `/vault/open?how=cosworth` is refused with **HTTP 409** while Peter is driving.

## Video sync

**Pi Toolbox Lite has no video sync.** Importing a clip and syncing it to the data (Media display, offset mode with the `O`
key, or distance mode) is a **Plus and above** feature. Paddock does not attempt video sync in Pi; its own recorder and
workbench do that (`docs\vault.md`).

## Editions

Lite (free, no licence key; the edition installed here) is limited to two tasks and five worksheets, so a Paddock workbook must
stay inside that. Plus, Pro and Ultra add the Split report, histograms, X/Y fits, more worksheets and video sync.
