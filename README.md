# Windows C:\ Cleanup

A safe, GUI-driven PowerShell utility that frees disk space on the **C: drive only**.
It clears well-known Windows caches, temp folders, logs, dumps, and duplicate user
files, and can optionally reclaim the hibernation file and right-size the pagefile —
all with hard safety guards so nothing outside `C:\` is ever touched.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)

---

## Features

- **Simple GUI** — checkboxes for every cleanup category, a live colored log, and a
  status panel showing space freed. Falls back to console mode automatically if
  Windows Forms can't load.
- **Self-elevating** — prompts for Administrator rights (UAC) automatically.
- **Dry-run mode** — preview exactly what would be deleted without changing anything.
- **C:-only by design** — every path is resolved and validated to live under `C:\`
  before it is read or deleted. Anything that resolves elsewhere aborts the run.
- **Protected items** — never deletes from `C:\Program Files`, `C:\Program Files (x86)`,
  or `C:\Windows\System32`, and never deletes `.exe`, `.dll`, `.sys`, `.inf`, or `.msi`
  files.
- **Fast, safe duplicate finder** — groups by size, then a 64 KB partial hash, then
  full SHA-256 only on the remaining collisions. Keeps the newest copy of each
  duplicate. **Allow-list only:** it scans nothing but your content folders
  (Downloads, Documents, Desktop, Pictures, Music, Videos), so it can never enter — let
  alone delete from — an application's install directory.
- **Locked files are skipped**, not fatal.
- **Full transcript log** of every run saved to `C:\CleanupLogs\`.

---

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- Administrator rights (the script elevates itself)

---

## Usage

> **Important:** double-clicking a `.ps1` file opens it in Notepad — it does not run it.
> Launch it through PowerShell.

### From PowerShell / Git Bash

```powershell
powershell -ExecutionPolicy Bypass -File .\cleanup.ps1
```

### Or right-click

Right-click `cleanup.ps1` → **Run with PowerShell**.

A UAC prompt appears (the script self-elevates) — click **Yes**. The cleanup window
then opens. Pick your categories and options and press **Run Cleanup**.

### Recommended first run

Tick **Dry run (preview only)**, press **Run Cleanup**, and review the log. When you're
happy with what it would remove, untick Dry run and run it for real.

---

## The window

| Control | What it does |
| --- | --- |
| **Dry run (preview only)** | Shows what would be deleted; deletes nothing. |
| **Skip duplicate scan** | Skips the (slower) duplicate-file scan under `C:\Users`. |
| **Min dup size (MB)** | Ignore duplicate files smaller than this. Larger value = faster scan. |
| **Categories** | Tick the cleanup categories to run; **Select all** / **Clear all** helpers. |
| **Hibernation** | `Ask` / `Yes` / `No` — whether to disable hibernation and reclaim `hiberfil.sys`. |
| **Pagefile** | `Ask` / `Yes` / `No` — whether to switch an oversized pagefile to System-managed. |
| **Run Cleanup** | Starts the run; live output streams into the log panel. |

---

## What it cleans

| Category | Target |
| --- | --- |
| Windows Temp folders | `C:\Windows\Temp`, `C:\Temp`, `%LOCALAPPDATA%\Temp` (only if on C:) |
| Windows Update cache | `C:\Windows\SoftwareDistribution\Download` |
| Windows Error Reporting | `C:\ProgramData\Microsoft\Windows\WER` |
| Prefetch | `C:\Windows\Prefetch` |
| Thumbnail cache | `%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db` |
| Old Windows install | `C:\Windows.old` (if present) |
| Recycle Bin (C:) | `C:\$Recycle.Bin` |
| Browser caches | Chrome, Edge, Firefox caches under `%LOCALAPPDATA%` (only if on C:) |
| Old logs | Files older than 30 days in `C:\Windows\Logs` |
| CBS log | `C:\Windows\Logs\CBS\CBS.log` |
| Memory dumps | `C:\Windows\MEMORY.DMP`, `C:\Windows\Minidump` |
| Delivery Optimization | `...\NetworkService\...\DeliveryOptimization\Cache` |
| Disk Cleanup | Runs `cleanmgr /sagerun:1` with a pre-seeded safe profile |
| Duplicate files | Duplicates **only** inside user-content folders (Downloads, Documents, Desktop, Pictures, Music, Videos, incl. OneDrive copies). App/install directories are never scanned. |
| Hibernation file | Disables hibernation via `powercfg /h off` (optional) |
| Pagefile | Offers System-managed size if pagefile > 1.5× RAM (optional) |

---

## Configuration

The defaults shown in the UI come from the `DEFAULTS` block at the top of
`cleanup.ps1`. Edit them to change the initial state, or to run headless:

```powershell
$Script:DryRun                = $false   # $true = preview only
$Script:SkipDuplicates        = $false
$Script:EnableLog             = $true
$Script:LogDirectory          = 'C:\CleanupLogs'
$Script:DisableHibernation    = 'ask'    # $true / $false / 'ask'
$Script:ManagePagefile        = 'ask'    # $true / $false / 'ask'
$Script:DuplicateMinSizeBytes = 1MB
$Script:UseGui                = $true     # $false = console mode, no window

# The duplicate scan ONLY enters these content folders (per user profile and
# any OneDrive copies). Application directories are never scanned.
$Script:DuplicateScanFolders  = @('Downloads','Documents','Desktop','Pictures','Music','Videos')
```

Set `$Script:UseGui = $false` to run entirely in the console (useful for
scheduled/automated runs).

---

## Safety design

- **Drive guard.** `Assert-OnCDrive` resolves every path (expanding environment
  variables) and aborts the run if the resolved root is not `C:\`. A second check runs
  again at delete time on each item, so even a symlink that points off-drive is caught.
- **Protected paths and extensions** are excluded from all categories and the duplicate
  scan.
- **No other drive** (D:, etc.) is ever enumerated or modified.
- **Registry** is only read (hibernation/pagefile state) and, for `cleanmgr`, written
  with a conservative `sageset:1` profile — no keys are deleted.

> Use at your own risk. Review the dry-run output before running live. The author is
> not responsible for data loss.

---

## Logs

Every run writes a timestamped transcript to `C:\CleanupLogs\cleanup_YYYYMMDD_HHmmss.log`.
This is preserved even if the window closes, so you can always review what happened.

---

## Troubleshooting

- **`bash: cleanup.ps1: command not found`** — you're in Git Bash; run it via
  `powershell -ExecutionPolicy Bypass -File cleanup.ps1`.
- **"running scripts is disabled on this system"** — include `-ExecutionPolicy Bypass`
  as shown above.
- **The window closed instantly** — that was the old console version; the GUI version
  stays open. The full output is in `C:\CleanupLogs\` regardless.
- **Duplicate scan feels slow** — raise **Min dup size (MB)** (e.g. to 10) so it only
  chases large duplicates.

---

## License

MIT — see [LICENSE](LICENSE).
