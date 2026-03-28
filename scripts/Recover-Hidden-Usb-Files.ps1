[CmdletBinding()]
param(
    [string]$DriveLetter = "",
    [string]$OutputRoot,
    [switch]$ListOnly,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "==== $Text ====" -ForegroundColor Cyan
}

function Wait-ForExit {
    if (-not $NoPause) {
        Write-Host ""
        Read-Host "Press Enter to exit" | Out-Null
    }
}

function Format-Bytes {
    param([UInt64]$Bytes)
    $units = @("B", "KB", "MB", "GB", "TB")
    $value = [double]$Bytes
    $idx = 0
    while ($value -ge 1024 -and $idx -lt ($units.Count - 1)) {
        $value /= 1024
        $idx++
    }
    "{0:N2} {1}" -f $value, $units[$idx]
}

function Get-UsbVolumes {
    $result = @()
    $volumes = Get-Volume | Where-Object { $_.DriveLetter }
    foreach ($volume in $volumes) {
        try {
            $partition = Get-Partition -DriveLetter $volume.DriveLetter -ErrorAction Stop
            $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
            if ($disk.BusType -eq "USB" -or $disk.FriendlyName -match "USB|Flash|Removable|UFD") {
                $result += [pscustomobject]@{
                    DriveLetter = $volume.DriveLetter
                    Label       = $volume.FileSystemLabel
                    FileSystem  = $volume.FileSystem
                    Size        = $volume.Size
                    Free        = $volume.SizeRemaining
                    DiskNumber  = $disk.Number
                    DiskName    = $disk.FriendlyName
                }
            }
        }
        catch {
        }
    }
    $result | Sort-Object DriveLetter
}

function Confirm-Yes {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultYes
    }

    return $answer -match "^(y|yes|1)$"
}

function Get-SuspiciousFiles {
    param([string]$RootPath)

    $extensions = @(".lnk", ".vbs", ".js", ".jse", ".wsf", ".wsh", ".hta", ".cmd", ".bat", ".pif", ".scr", ".com")
    Get-ChildItem -LiteralPath $RootPath -Force -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ieq "autorun.inf" -or
            $extensions -contains $_.Extension.ToLowerInvariant()
        }
}

if (-not $OutputRoot) {
    $OutputRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "repair-output"
}

Write-Section "USB hidden file / shortcut virus recovery"
Write-Host "This helper is for another common case:" -ForegroundColor Yellow
Write-Host "- Files are still on the USB drive, but suddenly become hidden" -ForegroundColor Yellow
Write-Host "- The drive looks empty" -ForegroundColor Yellow
Write-Host "- A lot of shortcuts or suspicious files appear" -ForegroundColor Yellow
Write-Host "- File names look garbled after unhide or after using infected machines" -ForegroundColor Yellow

$usbVolumes = Get-UsbVolumes
if (-not $usbVolumes) {
    Write-Host "No USB volumes were detected." -ForegroundColor Red
    Wait-ForExit
    exit 1
}

Write-Section "Detected USB volumes"
$usbVolumes |
    Select-Object DriveLetter, Label, FileSystem,
        @{ Name = "Size"; Expression = { Format-Bytes $_.Size } },
        @{ Name = "Free"; Expression = { Format-Bytes $_.Free } },
        DiskNumber, DiskName |
    Format-Table -AutoSize

if ($ListOnly) {
    Wait-ForExit
    exit 0
}

if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
    $DriveLetter = Read-Host "Enter the drive letter to process"
}

$DriveLetter = $DriveLetter.Trim().TrimEnd(":").ToUpperInvariant()
if ($DriveLetter.Length -ne 1) {
    throw "Invalid drive letter."
}

$target = $usbVolumes | Where-Object { $_.DriveLetter -eq $DriveLetter } | Select-Object -First 1
if (-not $target) {
    throw "The selected drive is not in the detected USB list."
}

$confirmLetter = Read-Host ("Type the drive letter {0} again to confirm" -f $DriveLetter)
if ($confirmLetter.Trim().TrimEnd(":").ToUpperInvariant() -ne $DriveLetter) {
    throw "Second confirmation failed."
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputDir = Join-Path $OutputRoot ("hidden-files-{0}-{1}" -f $DriveLetter, $timestamp)
New-Item -ItemType Directory -Force $outputDir | Out-Null

Start-Transcript -Path (Join-Path $outputDir "recover.log") -Force | Out-Null
try {
    $rootPath = "{0}:\" -f $DriveLetter

    Write-Section "Target volume"
    $target | Select-Object DriveLetter, Label, FileSystem,
        @{ Name = "Size"; Expression = { Format-Bytes $_.Size } },
        @{ Name = "Free"; Expression = { Format-Bytes $_.Free } },
        DiskNumber, DiskName | Format-List

    $before = Get-ChildItem -LiteralPath $rootPath -Force -ErrorAction SilentlyContinue
    $before | Select-Object FullName, Attributes, Length, LastWriteTime |
        Export-Csv -Path (Join-Path $outputDir "root-before.csv") -NoTypeInformation -Encoding UTF8

    $hiddenOrSystem = Get-ChildItem -LiteralPath $rootPath -Force -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Attributes.ToString().Contains("Hidden") -or
            $_.Attributes.ToString().Contains("System")
        }

    $hiddenOrSystem |
        Select-Object FullName, Attributes, Length, LastWriteTime |
        Export-Csv -Path (Join-Path $outputDir "hidden-or-system-before.csv") -NoTypeInformation -Encoding UTF8

    $suspicious = Get-SuspiciousFiles -RootPath $rootPath
    $suspicious |
        Select-Object FullName, Attributes, Length, LastWriteTime |
        Export-Csv -Path (Join-Path $outputDir "suspicious-root-files-before.csv") -NoTypeInformation -Encoding UTF8

    Write-Host ("Hidden/system items found: {0}" -f @($hiddenOrSystem).Count) -ForegroundColor Yellow
    Write-Host ("Suspicious root files found: {0}" -f @($suspicious).Count) -ForegroundColor Yellow

    Write-Section "Restore file attributes"
    Write-Host "Running: attrib -h -r -s /s /d ..." -ForegroundColor Green
    cmd /c ("attrib -h -r -s /s /d {0}\*.*" -f $rootPath)

    if (@($suspicious).Count -gt 0 -and (Confirm-Yes -Prompt "Move suspicious root files into quarantine?" -DefaultYes $true)) {
        $quarantine = Join-Path $outputDir "quarantine"
        New-Item -ItemType Directory -Force $quarantine | Out-Null
        foreach ($item in $suspicious) {
            $dest = Join-Path $quarantine $item.Name
            Move-Item -LiteralPath $item.FullName -Destination $dest -Force
        }
        Write-Host ("Moved suspicious files to: {0}" -f $quarantine) -ForegroundColor Green
    }

    $after = Get-ChildItem -LiteralPath $rootPath -Force -ErrorAction SilentlyContinue
    $after | Select-Object FullName, Attributes, Length, LastWriteTime |
        Export-Csv -Path (Join-Path $outputDir "root-after.csv") -NoTypeInformation -Encoding UTF8

    Write-Section "Notes about garbled file names"
    Write-Host "If files reappear but names look garbled:" -ForegroundColor Yellow
    Write-Host "- Sometimes the data is fine but the name encoding/display is wrong." -ForegroundColor Yellow
    Write-Host "- Sometimes the directory entry itself was damaged by malware or unsafe removal." -ForegroundColor Yellow
    Write-Host "- Copy visible files to your hard drive first, then rename them there." -ForegroundColor Yellow
    Write-Host "- If file contents open correctly, the damage is often limited to names." -ForegroundColor Yellow
    Write-Host "- If names and contents are both broken, switch to file recovery tools." -ForegroundColor Yellow

    @(
        "DriveLetter=$DriveLetter"
        "OutputDir=$outputDir"
        "HiddenOrSystemBefore=$(@($hiddenOrSystem).Count)"
        "SuspiciousFilesBefore=$(@($suspicious).Count)"
        "Status=Completed"
    ) | Set-Content -Path (Join-Path $outputDir "summary.txt") -Encoding UTF8

    Write-Section "Completed"
    Write-Host ("Reports saved to: {0}" -f $outputDir) -ForegroundColor Green
}
finally {
    Stop-Transcript | Out-Null
    Wait-ForExit
}
