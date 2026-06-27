<#
.SYNOPSIS
    Safe C:\ drive cleanup utility with a simple GUI.

.DESCRIPTION
    Frees disk space on the C: drive ONLY by clearing well-known caches,
    temp folders, logs, dumps, duplicate user files, and (optionally) the
    hibernation file / oversized pagefile.

    Just run the script - it self-elevates to Administrator and opens a
    window where you pick options and press "Run Cleanup":

        powershell -ExecutionPolicy Bypass -File .\cleanup.ps1

    Every path is validated to live under C:\ before anything is touched.
    Nothing outside C:\ is ever read or written.
#>

# ===========================================================================
#  DEFAULTS  -  these are the initial values shown in the UI
# ===========================================================================
$Script:DryRun                    = $false
$Script:SkipDuplicates            = $false
$Script:EnableLog                 = $true
$Script:LogDirectory              = 'C:\CleanupLogs'    # must be on C:\
$Script:RunCategories             = @('all')
$Script:DisableHibernation        = 'ask'              # $true / $false / 'ask'
$Script:ManagePagefile            = 'ask'              # $true / $false / 'ask'
$Script:DuplicateMinSizeBytes     = 1MB
$Script:DuplicatePartialHashBytes = 65536
$Script:UseGui                    = $true              # $false = console mode

# Master list of categories (key + friendly name), drives both the UI and
# the Should-Run gate.
$Script:CategoryDefs = @(
    [PSCustomObject]@{ Key='temp';         Name='Windows Temp folders' }
    [PSCustomObject]@{ Key='wupdate';      Name='Windows Update cache' }
    [PSCustomObject]@{ Key='wer';          Name='Windows Error Reporting dumps' }
    [PSCustomObject]@{ Key='prefetch';     Name='Prefetch' }
    [PSCustomObject]@{ Key='thumbnails';   Name='Thumbnail cache' }
    [PSCustomObject]@{ Key='windowsold';   Name='Old Windows install (Windows.old)' }
    [PSCustomObject]@{ Key='recyclebin';   Name='Recycle Bin (C:)' }
    [PSCustomObject]@{ Key='browsercache'; Name='Browser caches (Chrome/Edge/Firefox)' }
    [PSCustomObject]@{ Key='oldlogs';      Name='Old logs >30 days' }
    [PSCustomObject]@{ Key='cbslog';       Name='CBS log' }
    [PSCustomObject]@{ Key='memorydump';   Name='Memory dump files' }
    [PSCustomObject]@{ Key='deliveryopt';  Name='Delivery Optimization cache' }
    [PSCustomObject]@{ Key='cleanmgr';     Name='Disk Cleanup (cleanmgr)' }
    [PSCustomObject]@{ Key='duplicates';   Name='Duplicate files in C:\Users' }
    [PSCustomObject]@{ Key='hibernation';  Name='Hibernation file (hiberfil.sys)' }
    [PSCustomObject]@{ Key='pagefile';     Name='Pagefile sizing' }
)

$ErrorActionPreference = 'Continue'

# Runtime state (set later).
$Script:GuiMode    = $false
$Script:OutputBox  = $null
$Script:LogWriter  = $null

# ---------------------------------------------------------------------------
# 0. Self-elevation: relaunch as Administrator if we are not already elevated.
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo 'powershell.exe'
    # -WindowStyle Hidden so the console hides behind the GUI window.
    $psi.Arguments = @('-NoProfile', '-WindowStyle', 'Hidden',
                       '-ExecutionPolicy', 'Bypass',
                       '-File', "`"$PSCommandPath`"") -join ' '
    $psi.Verb = 'runas'
    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            'Administrator rights are required and were not granted. Exiting.',
            'C:\ Cleanup') | Out-Null
    }
    exit
}

# ===========================================================================
#  SAFETY GUARDS
# ===========================================================================
$Script:AllowedDrive = 'C:\'

function Assert-OnCDrive {
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    try { $full = [System.IO.Path]::GetFullPath($expanded) }
    catch {
        Write-Log "FATAL: could not resolve path '$Path'. Aborting." 'Red'
        throw "Path resolution failed: $Path"
    }
    $qualifier = [System.IO.Path]::GetPathRoot($full)
    if ($qualifier -ne $Script:AllowedDrive) {
        Write-Log "FATAL: path '$full' is NOT on $Script:AllowedDrive (root='$qualifier'). Aborting." 'Red'
        throw "Path escaped C:\ : $full"
    }
    return $full
}

function Test-OnCDrive {
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    try   { $full = [System.IO.Path]::GetFullPath($expanded) }
    catch { return $false }
    return ([System.IO.Path]::GetPathRoot($full) -eq $Script:AllowedDrive)
}

function Should-Run {
    param([Parameter(Mandatory)][string]$Key)
    if ($Script:RunCategories -contains 'all') { return $true }
    return ($Script:RunCategories -contains $Key)
}

$Script:ProtectedDirs = @(
    'C:\Program Files',
    'C:\Program Files (x86)',
    'C:\Windows\System32'
) | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }

$Script:ProtectedExtensions = @('.exe', '.dll', '.sys', '.inf', '.msi')

function Test-IsProtected {
    param([Parameter(Mandatory)][string]$FullPath)
    $lower = $FullPath.ToLowerInvariant()
    foreach ($p in $Script:ProtectedDirs) {
        if ($lower -eq $p -or $lower.StartsWith($p + '\')) { return $true }
    }
    if ($Script:ProtectedExtensions -contains [System.IO.Path]::GetExtension($lower)) { return $true }
    return $false
}

# ===========================================================================
#  OUTPUT / LOGGING
# ===========================================================================
function Write-Log {
    param([string]$Message = '', [string]$Color = 'Gray')

    if ($Script:GuiMode -and $Script:OutputBox) {
        $rtb = $Script:OutputBox
        $rtb.SelectionStart  = $rtb.TextLength
        $rtb.SelectionLength = 0
        try   { $rtb.SelectionColor = [System.Drawing.Color]::FromName($Color) }
        catch { $rtb.SelectionColor = $rtb.ForeColor }
        $rtb.AppendText($Message + "`r`n")
        $rtb.SelectionColor = $rtb.ForeColor
        $rtb.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    } elseif (-not $Script:GuiMode) {
        try { Write-Host $Message -ForegroundColor $Color } catch { Write-Host $Message }
    }
    if ($Script:LogWriter) { try { $Script:LogWriter.WriteLine($Message) } catch { } }
}

function Open-Log {
    if (-not $Script:EnableLog) { return }
    if (-not (Test-OnCDrive $Script:LogDirectory)) {
        Write-Log "LogDirectory '$($Script:LogDirectory)' is not on C:\ - logging disabled." 'Yellow'
        return
    }
    $dir = Assert-OnCDrive $Script:LogDirectory
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $logFile = Join-Path $dir ("cleanup_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        $Script:LogWriter = New-Object System.IO.StreamWriter($logFile, $false)
        $Script:LogWriter.AutoFlush = $true
        Write-Log "Logging this run to: $logFile" 'DarkGray'
    } catch {
        Write-Log "Could not open log file: $($_.Exception.Message)" 'Yellow'
    }
}

function Close-Log {
    if ($Script:LogWriter) {
        try { $Script:LogWriter.Flush(); $Script:LogWriter.Dispose() } catch { }
        $Script:LogWriter = $null
    }
}

function Confirm-YesNo {
    param([Parameter(Mandatory)][string]$Question)
    if ($Script:GuiMode) {
        return ([System.Windows.Forms.MessageBox]::Show(
            $Question, 'C:\ Cleanup',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question) -eq
            [System.Windows.Forms.DialogResult]::Yes)
    }
    $a = Read-Host "$Question (y/n)"
    return ($a -match '^(y|yes)$')
}

# ===========================================================================
#  SIZING / HASH HELPERS
# ===========================================================================
function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

$Script:GrandTotalFreed = 0

function Get-Contents {
    param([string]$Dir)
    $safe = Assert-OnCDrive $Dir
    if (-not (Test-Path -LiteralPath $safe)) { return @() }
    Get-ChildItem -LiteralPath $safe -Force -ErrorAction SilentlyContinue
}

function Get-PartialHash {
    param([string]$Path, [int]$Bytes = 65536)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $len = [int][Math]::Min([long]$Bytes, $fs.Length)
            $buf = New-Object byte[] $len
            $off = 0
            while ($off -lt $len) {
                $r = $fs.Read($buf, $off, $len - $off)
                if ($r -le 0) { break }
                $off += $r
            }
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { return [System.BitConverter]::ToString($sha.ComputeHash($buf, 0, $off)) }
            finally { $sha.Dispose() }
        } finally { $fs.Dispose() }
    } catch { return $null }
}

function Get-FullHash {
    param([string]$Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fs  = [System.IO.File]::OpenRead($Path)
        try   { return [System.BitConverter]::ToString($sha.ComputeHash($fs)) }
        finally { $fs.Dispose(); $sha.Dispose() }
    } catch { return $null }
}

function Invoke-CleanCategory {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Enumerate
    )
    if (-not (Should-Run $Key)) { return }

    Write-Log ""
    Write-Log "=== $Name ===" 'Cyan'

    $items = @(& $Enumerate)
    if (-not $items -or $items.Count -eq 0) { Write-Log "  Nothing to clean."; return }

    $before = ($items | Where-Object { -not $_.PSIsContainer } |
               Measure-Object -Property Length -Sum).Sum
    if (-not $before) { $before = 0 }
    Write-Log ("  Size before: {0}" -f (Format-Size $before))

    $freed = 0; $skipped = 0
    foreach ($item in $items) {
        $full = $item.FullName
        if (-not (Test-OnCDrive $full)) {
            Write-Log "  FATAL: '$full' escaped C:\ - aborting." 'Red'
            throw "Path escaped C:\ : $full"
        }
        if (Test-IsProtected $full) { $skipped++; continue }
        $sz = if ($item.PSIsContainer) { 0 } else { $item.Length }
        if ($Script:DryRun) {
            Write-Log "  [DRYRUN] would delete: $full"
            $freed += $sz
        } else {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $full)) { $freed += $sz } else { $skipped++ }
        }
    }

    Write-Log ("  Size after:  {0}" -f (Format-Size ($before - $freed)))
    Write-Log ("  Freed:       {0}{1}" -f (Format-Size $freed),
               $(if ($Script:DryRun) { ' (dry run)' } else { '' })) 'Green'
    if ($skipped -gt 0) { Write-Log "  Skipped (locked/protected): $skipped" }
    $Script:GrandTotalFreed += $freed
}

# ===========================================================================
#  THE CLEANUP RUN  (driven entirely by the $Script:* settings above)
# ===========================================================================
function Invoke-Cleanup {
    $Script:GrandTotalFreed = 0
    Open-Log

    Write-Log "============================================================"
    Write-Log " Windows C:\ Cleanup" 'White'
    Write-Log (" Mode: {0}" -f $(if ($Script:DryRun) { 'DRY RUN (no changes)' } else { 'LIVE' }))
    Write-Log (" Categories: {0}" -f ($Script:RunCategories -join ', '))
    Write-Log "============================================================"

    $cBefore = (Get-PSDrive C).Free
    Write-Log ("C:\ free space at start: {0}" -f (Format-Size $cBefore))

    # 1. Windows Temp folders
    Invoke-CleanCategory -Key 'temp' -Name "Windows Temp folders" -Enumerate {
        $r = @()
        $r += Get-Contents 'C:\Windows\Temp'
        $r += Get-Contents 'C:\Temp'
        $local = $env:LOCALAPPDATA
        if ($local -and (Test-OnCDrive $local)) { $r += Get-Contents (Join-Path $local 'Temp') }
        else { Write-Log "  (LOCALAPPDATA not on C:\ - skipping user temp)" }
        $r
    }

    # 2. Windows Update cache
    Invoke-CleanCategory -Key 'wupdate' -Name "Windows Update cache" -Enumerate {
        Get-Contents 'C:\Windows\SoftwareDistribution\Download'
    }

    # 3. Windows Error Reporting
    Invoke-CleanCategory -Key 'wer' -Name "Windows Error Reporting (WER)" -Enumerate {
        Get-Contents 'C:\ProgramData\Microsoft\Windows\WER'
    }

    # 4. Prefetch
    Invoke-CleanCategory -Key 'prefetch' -Name "Prefetch" -Enumerate {
        Get-Contents 'C:\Windows\Prefetch'
    }

    # 5. Thumbnail cache
    Invoke-CleanCategory -Key 'thumbnails' -Name "Thumbnail cache" -Enumerate {
        $local = $env:LOCALAPPDATA
        if ($local -and (Test-OnCDrive $local)) {
            $dir = Assert-OnCDrive (Join-Path $local 'Microsoft\Windows\Explorer')
            if (Test-Path -LiteralPath $dir) {
                Get-ChildItem -LiteralPath $dir -Filter 'thumbcache_*.db' -Force -ErrorAction SilentlyContinue
            }
        } else { Write-Log "  (LOCALAPPDATA not on C:\ - skipping)"; @() }
    }

    # 6. Windows.old
    Invoke-CleanCategory -Key 'windowsold' -Name "Old Windows installation (Windows.old)" -Enumerate {
        if (Test-Path -LiteralPath 'C:\Windows.old') { Get-Contents 'C:\Windows.old' }
        else { Write-Log "  (C:\Windows.old not present)"; @() }
    }

    # 7. Recycle Bin (C: only)
    Invoke-CleanCategory -Key 'recyclebin' -Name "Recycle Bin (C: only)" -Enumerate {
        $rb = Assert-OnCDrive 'C:\$Recycle.Bin'
        if (-not (Test-Path -LiteralPath $rb)) { return @() }
        Get-ChildItem -LiteralPath $rb -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer }
    }

    # 8. Browser caches
    Invoke-CleanCategory -Key 'browsercache' -Name "Browser caches (Chrome/Edge/Firefox)" -Enumerate {
        $local = $env:LOCALAPPDATA
        if (-not ($local -and (Test-OnCDrive $local))) { Write-Log "  (LOCALAPPDATA not on C:\ - skipping)"; return @() }
        $cachePaths = @(
            'Google\Chrome\User Data\Default\Cache',
            'Google\Chrome\User Data\Default\Code Cache',
            'Microsoft\Edge\User Data\Default\Cache',
            'Microsoft\Edge\User Data\Default\Code Cache',
            'Mozilla\Firefox\Profiles'
        )
        $r = @()
        foreach ($rel in $cachePaths) {
            $p = Join-Path $local $rel
            if (-not (Test-OnCDrive $p)) { continue }
            if (-not (Test-Path -LiteralPath $p)) { continue }
            if ($rel -like '*Firefox\Profiles') {
                Get-ChildItem -LiteralPath $p -Directory -Force -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $c2 = Join-Path $_.FullName 'cache2'
                        if (Test-Path -LiteralPath $c2) { $r += Get-Contents $c2 }
                    }
            } else { $r += Get-Contents $p }
        }
        $r
    }

    # 9. Old logs >30 days
    Invoke-CleanCategory -Key 'oldlogs' -Name "Old logs (>30 days) in C:\Windows\Logs" -Enumerate {
        $dir = Assert-OnCDrive 'C:\Windows\Logs'
        if (-not (Test-Path -LiteralPath $dir)) { return @() }
        $cutoff = (Get-Date).AddDays(-30)
        Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff }
    }

    # 10. CBS log
    Invoke-CleanCategory -Key 'cbslog' -Name "CBS log" -Enumerate {
        $cbs = Assert-OnCDrive 'C:\Windows\Logs\CBS\CBS.log'
        if (Test-Path -LiteralPath $cbs) { Get-Item -LiteralPath $cbs -Force -ErrorAction SilentlyContinue } else { @() }
    }

    # 11. Memory dumps
    Invoke-CleanCategory -Key 'memorydump' -Name "Memory dump files" -Enumerate {
        $r = @()
        $memdmp = Assert-OnCDrive 'C:\Windows\MEMORY.DMP'
        if (Test-Path -LiteralPath $memdmp) { $r += Get-Item -LiteralPath $memdmp -Force -ErrorAction SilentlyContinue }
        $r += Get-Contents 'C:\Windows\Minidump'
        $r
    }

    # 12. Delivery Optimization cache
    Invoke-CleanCategory -Key 'deliveryopt' -Name "Delivery Optimization cache" -Enumerate {
        Get-Contents 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
    }

    # 13. cleanmgr
    if (Should-Run 'cleanmgr') {
        Write-Log ""
        Write-Log "=== Disk Cleanup (cleanmgr /sagerun:1) ===" 'Cyan'
        if ($Script:DryRun) {
            Write-Log "  [DRYRUN] would configure a safe sageset:1 profile and run cleanmgr /sagerun:1"
        } else {
            $vcKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
            $safeHandlers = @(
                'Temporary Files','Temporary Setup Files','Setup Log Files',
                'Windows Error Reporting Files','Windows Error Reporting System Queue Files',
                'System error memory dump files','System error minidump files',
                'Delivery Optimization Files','Update Cleanup','Thumbnail Cache',
                'Old ChkDsk Files','Windows Upgrade Log Files','D3D Shader Cache','Internet Cache Files'
            )
            if (Test-Path -LiteralPath $vcKey) {
                foreach ($h in (Get-ChildItem -LiteralPath $vcKey -ErrorAction SilentlyContinue)) {
                    $flag = if ($safeHandlers -contains $h.PSChildName) { 2 } else { 0 }
                    New-ItemProperty -LiteralPath $h.PSPath -Name 'StateFlags0001' `
                        -Value $flag -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
                }
                Write-Log "  Configured safe sageset:1 profile ($($safeHandlers.Count) handlers enabled)."
                Write-Log "  Running cleanmgr /sagerun:1 ..."
                try {
                    Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:1' -Wait -ErrorAction Stop
                    Write-Log "  cleanmgr finished." 'Green'
                } catch { Write-Log "  cleanmgr could not be run: $($_.Exception.Message)" }
            } else { Write-Log "  VolumeCaches registry key not found - skipping cleanmgr." }
        }
    }

    # 14. Duplicate files (fast 3-stage scan)
    if ((Should-Run 'duplicates') -and -not $Script:SkipDuplicates) {
        Write-Log ""
        Write-Log "=== Duplicate files in C:\Users (keep newest) ===" 'Cyan'
        $usersRoot = Assert-OnCDrive 'C:\Users'
        $swDup = [System.Diagnostics.Stopwatch]::StartNew()

        $excludeDirLike = @('*\AppData\Roaming', '*\AppData\Local\Microsoft')
        $protectedExt = $Script:ProtectedExtensions

        Write-Log ("  Scanning files >= {0} (pruning excluded dirs)..." -f (Format-Size $Script:DuplicateMinSizeBytes))
        $candidates = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($usersRoot)
        $walkCount = 0
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            if ($Script:GuiMode -and ((++$walkCount % 200) -eq 0)) { [System.Windows.Forms.Application]::DoEvents() }
            try { $subs = [System.IO.Directory]::EnumerateDirectories($dir) } catch { $subs = @() }
            foreach ($sd in $subs) {
                $skip = $false
                foreach ($pat in $excludeDirLike) { if ($sd -like $pat) { $skip = $true; break } }
                if (-not $skip) { $stack.Push($sd) }
            }
            try { $fps = [System.IO.Directory]::EnumerateFiles($dir) } catch { $fps = @() }
            foreach ($fp in $fps) {
                $ext = [System.IO.Path]::GetExtension($fp).ToLowerInvariant()
                if ($protectedExt -contains $ext) { continue }
                try {
                    $fi = New-Object System.IO.FileInfo $fp
                    if ($fi.Length -ge $Script:DuplicateMinSizeBytes) { $candidates.Add($fi) }
                } catch { }
            }
        }
        Write-Log ("  Candidate files: {0}" -f $candidates.Count)

        $bySize = $candidates | Group-Object -Property Length | Where-Object { $_.Count -gt 1 }
        $finalGroups = New-Object 'System.Collections.Generic.List[object]'
        foreach ($sizeGroup in $bySize) {
            $partial = foreach ($f in $sizeGroup.Group) {
                $ph = Get-PartialHash -Path $f.FullName -Bytes $Script:DuplicatePartialHashBytes
                if ($ph) { [PSCustomObject]@{ File = $f; PHash = $ph } }
            }
            foreach ($pg in ($partial | Group-Object -Property PHash | Where-Object { $_.Count -gt 1 })) {
                if ([long]$sizeGroup.Name -le $Script:DuplicatePartialHashBytes) {
                    $finalGroups.Add($pg.Group.File) | Out-Null
                } else {
                    $full = foreach ($x in $pg.Group) {
                        $fh = Get-FullHash -Path $x.File.FullName
                        if ($fh) { [PSCustomObject]@{ File = $x.File; FHash = $fh } }
                    }
                    foreach ($fg in ($full | Group-Object -Property FHash | Where-Object { $_.Count -gt 1 })) {
                        $finalGroups.Add($fg.Group.File) | Out-Null
                    }
                }
            }
        }

        $dupFreed = 0; $dupCount = 0
        foreach ($group in $finalGroups) {
            $ordered = @($group) | Sort-Object LastWriteTime -Descending
            $remove  = $ordered | Select-Object -Skip 1
            foreach ($d in $remove) {
                $fp = $d.FullName
                if (-not (Test-OnCDrive $fp)) { Write-Log "  FATAL: '$fp' escaped C:\ - aborting." 'Red'; throw "Path escaped C:\ : $fp" }
                if (Test-IsProtected $fp) { continue }
                if ($Script:DryRun) {
                    Write-Log ("  [DRYRUN] would delete: {0} ({1})" -f $fp, (Format-Size $d.Length))
                    $dupFreed += $d.Length; $dupCount++
                } else {
                    Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue
                    if (-not (Test-Path -LiteralPath $fp)) { $dupFreed += $d.Length; $dupCount++ }
                }
            }
        }
        $swDup.Stop()
        Write-Log ("  Duplicate files removed: {0}" -f $dupCount)
        Write-Log ("  Freed: {0}{1}" -f (Format-Size $dupFreed), $(if ($Script:DryRun) { ' (dry run)' } else { '' })) 'Green'
        Write-Log ("  Duplicate scan time: {0:N1}s" -f $swDup.Elapsed.TotalSeconds) 'DarkGray'
        $Script:GrandTotalFreed += $dupFreed
    } elseif (Should-Run 'duplicates' -and $Script:SkipDuplicates) {
        Write-Log ""
        Write-Log "=== Duplicate files in C:\Users ===" 'Cyan'
        Write-Log "  Skipped (duplicate scan disabled)."
    }

    # 15. Hibernation
    if (Should-Run 'hibernation') {
        Write-Log ""
        Write-Log "=== Hibernation file (hiberfil.sys) ===" 'Cyan'
        $hiberVal = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' `
                        -Name 'HibernateEnabled' -ErrorAction SilentlyContinue).HibernateEnabled
        if ($hiberVal -eq 1) {
            $hsize = 0
            if (Test-Path -LiteralPath 'C:\hiberfil.sys') {
                $hsize = (Get-Item -LiteralPath 'C:\hiberfil.sys' -Force -ErrorAction SilentlyContinue).Length
            }
            Write-Log ("  Hibernation is ENABLED. hiberfil.sys is currently {0}." -f (Format-Size $hsize))
            $doDisable = $false
            if ($Script:DryRun) {
                Write-Log "  [DRYRUN] would (per setting '$($Script:DisableHibernation)') consider disabling hibernation."
            } elseif ($Script:DisableHibernation -eq $true) { $doDisable = $true }
            elseif ($Script:DisableHibernation -eq $false) { Write-Log "  Setting says leave hibernation enabled." }
            else { $doDisable = Confirm-YesNo "Disable hibernation and reclaim hiberfil.sys (~$(Format-Size $hsize))?" }

            if ($doDisable -and -not $Script:DryRun) {
                powercfg /h off
                Write-Log "  Hibernation disabled. ~$(Format-Size $hsize) reclaimed." 'Green'
                $Script:GrandTotalFreed += $hsize
            } elseif (-not $Script:DryRun -and $Script:DisableHibernation -ne $false) {
                Write-Log "  Left hibernation enabled."
            }
        } else { Write-Log "  Hibernation is already disabled - nothing to do." }
    }

    # 16. Pagefile
    if (Should-Run 'pagefile') {
        Write-Log ""
        Write-Log "=== Pagefile (C:\pagefile.sys) ===" 'Cyan'
        $ramBytes = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory
        $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -like 'C:*' } | Select-Object -First 1
        if ($ramBytes -and $pf) {
            $pfBytes    = [double]$pf.AllocatedBaseSize * 1MB
            $thresholdB = 1.5 * [double]$ramBytes
            Write-Log ("  Installed RAM:   {0}" -f (Format-Size $ramBytes))
            Write-Log ("  Pagefile on C:\: {0}" -f (Format-Size $pfBytes))
            Write-Log ("  1.5x RAM:        {0}" -f (Format-Size $thresholdB))
            if ($pfBytes -gt $thresholdB) {
                Write-Log "  Pagefile exceeds 1.5x RAM." 'Yellow'
                $doManage = $false
                if ($Script:DryRun) {
                    Write-Log "  [DRYRUN] would (per setting '$($Script:ManagePagefile)') consider System-managed size."
                } elseif ($Script:ManagePagefile -eq $true) { $doManage = $true }
                elseif ($Script:ManagePagefile -eq $false) { Write-Log "  Setting says leave pagefile unchanged." }
                else { $doManage = Confirm-YesNo "Let Windows manage the C:\ pagefile size automatically?" }

                if ($doManage -and -not $Script:DryRun) {
                    try {
                        $cs = Get-CimInstance Win32_ComputerSystem
                        if (-not $cs.AutomaticManagedPagefile) {
                            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
                        }
                        Write-Log "  Pagefile set to System-managed. A reboot is required to take effect." 'Green'
                    } catch { Write-Log "  Could not change pagefile setting: $($_.Exception.Message)" }
                }
            } else { Write-Log "  Pagefile size is within the expected range - nothing to do." }
        } else { Write-Log "  Could not read pagefile/RAM info - skipping." }
    }

    # Summary
    $cAfter = (Get-PSDrive C).Free
    Write-Log ""
    Write-Log "============================================================"
    Write-Log " CLEANUP SUMMARY" 'White'
    Write-Log "============================================================"
    Write-Log (" Tracked space freed by categories: {0}{1}" -f (Format-Size $Script:GrandTotalFreed),
               $(if ($Script:DryRun) { ' (dry run - nothing deleted)' } else { '' })) 'Green'
    if (-not $Script:DryRun) {
        Write-Log (" C:\ free before: {0}" -f (Format-Size $cBefore))
        Write-Log (" C:\ free after:  {0}" -f (Format-Size $cAfter))
    }
    Write-Log "============================================================"

    Close-Log
    return [PSCustomObject]@{ Freed = $Script:GrandTotalFreed; FreeBefore = $cBefore; FreeAfter = $cAfter }
}

# ===========================================================================
#  GUI
# ===========================================================================
function Show-CleanupGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = 'C:\ Cleanup'
    $form.ClientSize    = New-Object System.Drawing.Size(740, 700)
    $form.StartPosition = 'CenterScreen'
    $form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.MinimumSize   = New-Object System.Drawing.Size(700, 600)

    # --- options row ---
    $chkDryRun = New-Object System.Windows.Forms.CheckBox
    $chkDryRun.Text = 'Dry run (preview only)'
    $chkDryRun.Location = New-Object System.Drawing.Point(15, 12)
    $chkDryRun.AutoSize = $true
    $chkDryRun.Checked = $Script:DryRun
    $form.Controls.Add($chkDryRun)

    $chkSkipDup = New-Object System.Windows.Forms.CheckBox
    $chkSkipDup.Text = 'Skip duplicate scan'
    $chkSkipDup.Location = New-Object System.Drawing.Point(200, 12)
    $chkSkipDup.AutoSize = $true
    $chkSkipDup.Checked = $Script:SkipDuplicates
    $form.Controls.Add($chkSkipDup)

    $lblMin = New-Object System.Windows.Forms.Label
    $lblMin.Text = 'Min dup size (MB):'
    $lblMin.Location = New-Object System.Drawing.Point(370, 14)
    $lblMin.AutoSize = $true
    $form.Controls.Add($lblMin)

    $numMin = New-Object System.Windows.Forms.NumericUpDown
    $numMin.Location = New-Object System.Drawing.Point(490, 11)
    $numMin.Size = New-Object System.Drawing.Size(70, 24)
    $numMin.Minimum = 0
    $numMin.Maximum = 1000000
    $numMin.Value = [decimal]($Script:DuplicateMinSizeBytes / 1MB)
    $form.Controls.Add($numMin)

    # --- categories ---
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = 'Categories to clean'
    $grp.Location = New-Object System.Drawing.Point(15, 45)
    $grp.Size = New-Object System.Drawing.Size(360, 380)
    $grp.Anchor = 'Top,Left'
    $form.Controls.Add($grp)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = New-Object System.Drawing.Point(12, 22)
    $clb.Size = New-Object System.Drawing.Size(336, 348)
    $clb.CheckOnClick = $true
    $clb.DisplayMember = 'Name'
    foreach ($c in $Script:CategoryDefs) { [void]$clb.Items.Add($c, $true) }
    $grp.Controls.Add($clb)

    # --- right column ---
    $lblHib = New-Object System.Windows.Forms.Label
    $lblHib.Text = 'Hibernation:'
    $lblHib.Location = New-Object System.Drawing.Point(395, 52)
    $lblHib.AutoSize = $true
    $form.Controls.Add($lblHib)

    $cboHib = New-Object System.Windows.Forms.ComboBox
    $cboHib.DropDownStyle = 'DropDownList'
    $cboHib.Location = New-Object System.Drawing.Point(500, 49)
    $cboHib.Size = New-Object System.Drawing.Size(120, 24)
    [void]$cboHib.Items.AddRange(@('Ask', 'Yes', 'No'))
    $cboHib.SelectedIndex = 0
    $form.Controls.Add($cboHib)

    $lblPf = New-Object System.Windows.Forms.Label
    $lblPf.Text = 'Pagefile:'
    $lblPf.Location = New-Object System.Drawing.Point(395, 86)
    $lblPf.AutoSize = $true
    $form.Controls.Add($lblPf)

    $cboPf = New-Object System.Windows.Forms.ComboBox
    $cboPf.DropDownStyle = 'DropDownList'
    $cboPf.Location = New-Object System.Drawing.Point(500, 83)
    $cboPf.Size = New-Object System.Drawing.Size(120, 24)
    [void]$cboPf.Items.AddRange(@('Ask', 'Yes', 'No'))
    $cboPf.SelectedIndex = 0
    $form.Controls.Add($cboPf)

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = 'Select all'
    $btnAll.Location = New-Object System.Drawing.Point(395, 120)
    $btnAll.Size = New-Object System.Drawing.Size(105, 28)
    $btnAll.Add_Click({ for ($i=0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $true) } })
    $form.Controls.Add($btnAll)

    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = 'Clear all'
    $btnNone.Location = New-Object System.Drawing.Point(510, 120)
    $btnNone.Size = New-Object System.Drawing.Size(105, 28)
    $btnNone.Add_Click({ for ($i=0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $false) } })
    $form.Controls.Add($btnNone)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = 'Run Cleanup'
    $btnRun.Location = New-Object System.Drawing.Point(395, 165)
    $btnRun.Size = New-Object System.Drawing.Size(220, 48)
    $btnRun.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnRun.ForeColor = [System.Drawing.Color]::White
    $btnRun.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnRun)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(395, 225)
    $lblStatus.Size = New-Object System.Drawing.Size(330, 195)
    $lblStatus.Text = ("C:\ free space: {0}" -f (Format-Size (Get-PSDrive C).Free))
    $form.Controls.Add($lblStatus)

    # --- output log ---
    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Location = New-Object System.Drawing.Point(15, 435)
    $rtb.Size = New-Object System.Drawing.Size(710, 250)
    $rtb.ReadOnly = $true
    $rtb.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $rtb.ForeColor = [System.Drawing.Color]::Gainsboro
    $rtb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $rtb.Anchor = 'Top,Bottom,Left,Right'
    $form.Controls.Add($rtb)
    $Script:OutputBox = $rtb

    # --- run handler ---
    $btnRun.Add_Click({
        $checked = @()
        foreach ($it in $clb.CheckedItems) { $checked += $it.Key }
        if ($checked.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Select at least one category.', 'C:\ Cleanup') | Out-Null
            return
        }

        # Push UI choices into settings.
        $Script:DryRun                = $chkDryRun.Checked
        $Script:SkipDuplicates        = $chkSkipDup.Checked
        $Script:RunCategories         = $checked
        $Script:DuplicateMinSizeBytes = [long]([double]$numMin.Value * 1MB)
        $Script:DisableHibernation    = switch ($cboHib.SelectedItem) { 'Yes' { $true } 'No' { $false } default { 'ask' } }
        $Script:ManagePagefile        = switch ($cboPf.SelectedItem)  { 'Yes' { $true } 'No' { $false } default { 'ask' } }

        $rtb.Clear()
        $btnRun.Enabled = $false
        $btnRun.Text = 'Running...'
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $res = Invoke-Cleanup
            $lblStatus.Text = ("Freed this run: {0}`r`nC:\ free now: {1}" -f `
                (Format-Size $res.Freed), (Format-Size $res.FreeAfter))
        } catch {
            Write-Log "ERROR: $($_.Exception.Message)" 'Red'
            Close-Log
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnRun.Enabled = $true
            $btnRun.Text = 'Run Cleanup'
        }
    })

    $form.Add_FormClosed({ $Script:OutputBox = $null; Close-Log })
    [void]$form.ShowDialog()
}

# ===========================================================================
#  ENTRY POINT
# ===========================================================================
if ($Script:UseGui) {
    try {
        $Script:GuiMode = $true
        Show-CleanupGui
    } catch {
        $Script:GuiMode = $false
        Write-Host "GUI failed to start ($($_.Exception.Message)). Running in console mode." -ForegroundColor Yellow
        Invoke-Cleanup | Out-Null
        Read-Host "Press Enter to close"
    }
} else {
    $Script:GuiMode = $false
    Invoke-Cleanup | Out-Null
    Read-Host "Press Enter to close"
}
