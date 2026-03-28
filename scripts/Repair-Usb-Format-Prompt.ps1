[CmdletBinding()]
param(
    [int]$DiskNumber = -1,
    [string]$OutputRoot,
    [switch]$SkipFullImage,
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
        Read-Host "按 Enter 键退出" | Out-Null
    }
}

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (Test-IsAdmin) {
        return
    }

    if (-not $PSCommandPath) {
        throw "当前会话无法自动提权，请用管理员身份重新运行脚本。"
    }

    $argList = @(
        "-NoLogo",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $PSCommandPath)
    )

    if ($DiskNumber -ge 0) { $argList += @("-DiskNumber", $DiskNumber) }
    if ($OutputRoot) { $argList += @("-OutputRoot", ('"{0}"' -f $OutputRoot)) }
    if ($SkipFullImage) { $argList += "-SkipFullImage" }
    if ($ListOnly) { $argList += "-ListOnly" }
    if ($NoPause) { $argList += "-NoPause" }

    Write-Host "正在请求管理员权限..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList ($argList -join " ")
    exit
}

function Get-UsbDisks {
    Get-Disk |
        Where-Object {
            $_.BusType -eq "USB" -or
            $_.FriendlyName -match "USB|Flash|Removable|UFD"
        } |
        Sort-Object Number
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

function Read-ExactBytes {
    param(
        [Parameter(Mandatory)] [System.IO.FileStream]$Stream,
        [Parameter(Mandatory)] [Int64]$Offset,
        [Parameter(Mandatory)] [int]$Count
    )

    $buffer = New-Object byte[] $Count
    $Stream.Seek($Offset, [System.IO.SeekOrigin]::Begin) > $null

    $readTotal = 0
    while ($readTotal -lt $Count) {
        $read = $Stream.Read($buffer, $readTotal, $Count - $readTotal)
        if ($read -le 0) {
            throw "在偏移 $Offset 读取磁盘时失败。"
        }
        $readTotal += $read
    }

    return $buffer
}

function Backup-Range {
    param(
        [int]$DiskNumber,
        [string]$OutputPath,
        [int]$BytesToCopy
    )

    $device = "\\.\PhysicalDrive$DiskNumber"
    $stream = [System.IO.File]::Open($device, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $buffer = Read-ExactBytes -Stream $stream -Offset 0 -Count $BytesToCopy
        [System.IO.File]::WriteAllBytes($OutputPath, $buffer)
    }
    finally {
        $stream.Close()
    }
}

function Get-MbrState {
    param([byte[]]$Sector0)

    $signatureOk = ($Sector0[510] -eq 0x55 -and $Sector0[511] -eq 0xAA)
    $entryBytes = $Sector0[446..509]
    $allZero = ($entryBytes | Where-Object { $_ -ne 0x00 }).Count -eq 0
    $allFF = ($entryBytes | Where-Object { $_ -ne 0xFF }).Count -eq 0
    $hasLikelyPartition = ($Sector0[450] -ne 0x00 -and $Sector0[450] -ne 0xFF)

    [pscustomobject]@{
        SignatureOk        = $signatureOk
        EntryBytesAllZero  = $allZero
        EntryBytesAllFF    = $allFF
        HasLikelyPartition = $hasLikelyPartition
        IsMissingOrBroken  = (-not $signatureOk) -or $allZero -or $allFF -or (-not $hasLikelyPartition)
    }
}

function Test-Fat32BootSector {
    param(
        [byte[]]$Sector,
        [UInt32]$Lba
    )

    if ($Sector.Length -lt 512) { return $null }

    $jumpOk = (($Sector[0] -eq 0xEB -and $Sector[2] -eq 0x90) -or $Sector[0] -eq 0xE9)
    $signatureOk = ($Sector[510] -eq 0x55 -and $Sector[511] -eq 0xAA)
    $fsName = [System.Text.Encoding]::ASCII.GetString($Sector[82..89]).Trim()
    $oem = [System.Text.Encoding]::ASCII.GetString($Sector[3..10]).Trim()
    $bytesPerSector = [BitConverter]::ToUInt16($Sector, 11)
    $sectorsPerCluster = $Sector[13]
    $reservedSectors = [BitConverter]::ToUInt16($Sector, 14)
    $numberOfFats = $Sector[16]
    $hiddenSectors = [BitConverter]::ToUInt32($Sector, 28)
    $totalSectors = [BitConverter]::ToUInt32($Sector, 32)
    $fatSize = [BitConverter]::ToUInt32($Sector, 36)
    $rootCluster = [BitConverter]::ToUInt32($Sector, 44)
    $fsInfoSector = [BitConverter]::ToUInt16($Sector, 48)
    $backupBootSector = [BitConverter]::ToUInt16($Sector, 50)

    if (-not $jumpOk) { return $null }
    if (-not $signatureOk) { return $null }
    if ($fsName -ne "FAT32") { return $null }
    if ($bytesPerSector -notin 512, 1024, 2048, 4096) { return $null }
    if ($sectorsPerCluster -notin 1, 2, 4, 8, 16, 32, 64, 128) { return $null }
    if ($reservedSectors -lt 32) { return $null }
    if ($numberOfFats -lt 1 -or $numberOfFats -gt 2) { return $null }
    if ($totalSectors -le 0) { return $null }
    if ($fatSize -le 0) { return $null }
    if ($rootCluster -lt 2) { return $null }
    if ($hiddenSectors -ne $Lba) { return $null }

    [pscustomobject]@{
        Lba                = $Lba
        Oem                = $oem
        BytesPerSector     = $bytesPerSector
        SectorsPerCluster  = $sectorsPerCluster
        ReservedSectors    = $reservedSectors
        NumberOfFats       = $numberOfFats
        HiddenSectors      = $hiddenSectors
        TotalSectors       = $totalSectors
        FatSize            = $fatSize
        RootCluster        = $rootCluster
        FsInfoSector       = $fsInfoSector
        BackupBootSector   = $backupBootSector
        PartitionType      = 0x0C
    }
}

function Find-Fat32Candidate {
    param(
        [int]$DiskNumber,
        [int]$MaxLbaToScan = 2048
    )

    $device = "\\.\PhysicalDrive$DiskNumber"
    $stream = [System.IO.File]::Open($device, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $candidates = @()
        for ($lba = 1; $lba -le $MaxLbaToScan; $lba++) {
            $sector = Read-ExactBytes -Stream $stream -Offset ([Int64]$lba * 512) -Count 512
            $candidate = Test-Fat32BootSector -Sector $sector -Lba $lba
            if ($null -ne $candidate) {
                $backupLba = $candidate.Lba + $candidate.BackupBootSector
                if ($backupLba -le $MaxLbaToScan) {
                    $backupSector = Read-ExactBytes -Stream $stream -Offset ([Int64]$backupLba * 512) -Count 512
                    $backupLooksValid = (
                        $backupSector[510] -eq 0x55 -and
                        $backupSector[511] -eq 0xAA -and
                        [System.Text.Encoding]::ASCII.GetString($backupSector[82..89]).Trim() -eq "FAT32"
                    )
                    if (-not $backupLooksValid) {
                        continue
                    }
                }
                $candidates += $candidate
            }
        }
        return $candidates
    }
    finally {
        $stream.Close()
    }
}

function New-MbrSector {
    param(
        [UInt32]$StartLba,
        [UInt32]$SectorCount,
        [byte]$PartitionType
    )

    $mbr = New-Object byte[] 512
    [byte[]]$diskSignature = 0x55, 0x53, 0x42, 0x52
    [Array]::Copy($diskSignature, 0, $mbr, 440, 4)
    $mbr[446] = 0x00
    $mbr[447] = 0x00
    $mbr[448] = 0x02
    $mbr[449] = 0x00
    $mbr[450] = $PartitionType
    $mbr[451] = 0xFE
    $mbr[452] = 0xFF
    $mbr[453] = 0xFF
    [BitConverter]::GetBytes($StartLba).CopyTo($mbr, 454)
    [BitConverter]::GetBytes($SectorCount).CopyTo($mbr, 458)
    $mbr[510] = 0x55
    $mbr[511] = 0xAA
    return $mbr
}

function Write-Sector0 {
    param(
        [int]$DiskNumber,
        [byte[]]$SectorBytes
    )

    $device = "\\.\PhysicalDrive$DiskNumber"
    $stream = [System.IO.File]::Open($device, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
    try {
        $stream.Seek(0, [System.IO.SeekOrigin]::Begin) > $null
        $stream.Write($SectorBytes, 0, $SectorBytes.Length)
        $stream.Flush()
    }
    finally {
        $stream.Close()
    }
}

function Start-FullImageBackup {
    param(
        [int]$DiskNumber,
        [UInt64]$DiskSize,
        [string]$ImagePath
    )

    $device = "\\.\PhysicalDrive$DiskNumber"
    $inputStream = [System.IO.File]::Open($device, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $outputStream = [System.IO.File]::Open($ImagePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

    $bufferSize = 4MB
    $buffer = New-Object byte[] $bufferSize
    [UInt64]$copied = 0

    try {
        while ($true) {
            $read = $inputStream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $outputStream.Write($buffer, 0, $read)
            $copied += [UInt64]$read

            if ($DiskSize -gt 0) {
                $percent = [Math]::Min(100, [int](($copied * 100) / $DiskSize))
                Write-Progress -Activity "正在创建整盘镜像" -Status ("{0} / {1}" -f (Format-Bytes $copied), (Format-Bytes $DiskSize)) -PercentComplete $percent
            }
        }
    }
    finally {
        Write-Progress -Activity "正在创建整盘镜像" -Completed
        $inputStream.Close()
        $outputStream.Close()
    }
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

    return $answer -match "^(y|yes|1|是)$"
}

Ensure-Admin

$scriptDir = Split-Path -Parent $PSCommandPath
if (-not $OutputRoot) {
    $OutputRoot = Join-Path (Split-Path -Parent $scriptDir) "repair-output"
}

Write-Section "USB RAW/FAT32 最小修复向导"
Write-Host "这个脚本只自动修复一种情况：" -ForegroundColor Yellow
Write-Host "MBR 丢失，但 FAT32 文件系统仍然存在。" -ForegroundColor Yellow
Write-Host "如果脚本无法确认这一点，它会停止，不会自动写盘。" -ForegroundColor Yellow

$usbDisks = Get-UsbDisks
if (-not $usbDisks) {
    Write-Host "没有找到可疑的 USB 磁盘。" -ForegroundColor Red
    Wait-ForExit
    exit 1
}

Write-Section "检测到的 USB 磁盘"
$usbDisks | Select-Object Number, FriendlyName, BusType, PartitionStyle, HealthStatus,
    @{ Name = "Size"; Expression = { Format-Bytes $_.Size } } |
    Format-Table -AutoSize

if ($ListOnly) {
    Wait-ForExit
    exit 0
}

if ($DiskNumber -lt 0) {
    $rawInput = Read-Host "请输入要处理的 Disk Number"
    if (-not [int]::TryParse($rawInput, [ref]$DiskNumber)) {
        throw "Disk Number 输入无效。"
    }
}

$disk = Get-Disk -Number $DiskNumber
$confirmDisk = Read-Host ("再次输入 Disk Number {0} 以确认" -f $DiskNumber)
if ($confirmDisk -ne [string]$DiskNumber) {
    throw "二次确认失败，已停止。"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputDir = Join-Path $OutputRoot ("usb-repair-disk{0}-{1}" -f $DiskNumber, $timestamp)
New-Item -ItemType Directory -Force $outputDir | Out-Null

Start-Transcript -Path (Join-Path $outputDir "repair.log") -Force | Out-Null

try {
    Write-Section "目标磁盘信息"
    $disk | Select-Object Number, FriendlyName, BusType, PartitionStyle, HealthStatus, OperationalStatus,
        @{ Name = "Size"; Expression = { Format-Bytes $_.Size } } |
        Format-List

    $currentPartitions = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue
    if ($currentPartitions) {
        Write-Host "当前分区情况：" -ForegroundColor Yellow
        $currentPartitions | Select-Object PartitionNumber, DriveLetter, Offset,
            @{ Name = "Size"; Expression = { Format-Bytes $_.Size } }, Type | Format-Table -AutoSize
    }
    else {
        Write-Host "当前没有可用分区信息。" -ForegroundColor Yellow
    }

    Write-Section "保护原盘"
    Set-Disk -Number $DiskNumber -IsReadOnly $true
    Write-Host "已将磁盘设为只读。"

    $sectorBackup = Join-Path $outputDir "first-1MiB-before-repair.bin"
    Backup-Range -DiskNumber $DiskNumber -OutputPath $sectorBackup -BytesToCopy 1MB
    Write-Host ("已备份前 1 MiB 到: {0}" -f $sectorBackup)

    $doImage = $false
    if (-not $SkipFullImage) {
        $doImage = Confirm-Yes -Prompt ("是否创建整盘镜像备份？推荐。需要至少 {0} 可用空间。" -f (Format-Bytes $disk.Size)) -DefaultYes $true
    }

    if ($doImage) {
        $rootDriveName = ([System.IO.Path]::GetPathRoot($outputDir)).TrimEnd('\').TrimEnd(':')
        $rootDrive = Get-PSDrive -Name $rootDriveName
        if ($rootDrive.Free -lt $disk.Size) {
            Write-Host "可用空间不足，已跳过整盘镜像。" -ForegroundColor Yellow
        }
        else {
            $imagePath = Join-Path $outputDir ("disk{0}-{1}.img" -f $DiskNumber, $timestamp)
            Start-FullImageBackup -DiskNumber $DiskNumber -DiskSize $disk.Size -ImagePath $imagePath
            Write-Host ("整盘镜像已保存到: {0}" -f $imagePath) -ForegroundColor Green
        }
    }

    Write-Section "分析盘头"
    $device = "\\.\PhysicalDrive$DiskNumber"
    $stream = [System.IO.File]::Open($device, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sector0 = Read-ExactBytes -Stream $stream -Offset 0 -Count 512
    }
    finally {
        $stream.Close()
    }

    $mbrState = Get-MbrState -Sector0 $sector0
    if (-not $mbrState.IsMissingOrBroken) {
        throw "当前磁盘的 MBR 看起来并未丢失，这不是这个脚本的适用情况。"
    }

    $candidates = Find-Fat32Candidate -DiskNumber $DiskNumber -MaxLbaToScan 2048
    if (-not $candidates) {
        throw "没有在前 1 MiB 内找到可安全自动修复的 FAT32 启动扇区。请改用人工分析或镜像恢复。"
    }

    if ($candidates.Count -gt 1) {
        throw "发现了多个候选 FAT32 分区，自动修复风险较高，脚本已停止。"
    }

    $candidate = $candidates[0]

    Write-Host "找到可修复的 FAT32 候选分区：" -ForegroundColor Green
    $candidate | Select-Object Lba, BytesPerSector, SectorsPerCluster, ReservedSectors,
        NumberOfFats, TotalSectors, FatSize, HiddenSectors, RootCluster, BackupBootSector |
        Format-List

    $mbrPath = Join-Path $outputDir "rebuilt-mbr-sector0.bin"
    $newMbr = New-MbrSector -StartLba $candidate.Lba -SectorCount $candidate.TotalSectors -PartitionType ([byte]$candidate.PartitionType)
    [System.IO.File]::WriteAllBytes($mbrPath, $newMbr)
    Write-Host ("已生成新的 MBR 文件: {0}" -f $mbrPath)

    if (-not (Confirm-Yes -Prompt "是否将这个最小 MBR 写回原始 U 盘？" -DefaultYes $true)) {
        Write-Host "用户取消了写盘操作。"
        return
    }

    Write-Section "写回最小 MBR"
    Set-Disk -Number $DiskNumber -IsReadOnly $false
    Write-Sector0 -DiskNumber $DiskNumber -SectorBytes $newMbr
    Update-HostStorageCache
    Start-Sleep -Seconds 3

    $newPartitions = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue
    if (-not $newPartitions) {
        throw "写回完成，但系统仍未识别出分区。"
    }

    $newPartitions | Select-Object PartitionNumber, DriveLetter, Offset,
        @{ Name = "Size"; Expression = { Format-Bytes $_.Size } }, Type | Format-Table -AutoSize

    $driveLetter = ($newPartitions | Where-Object DriveLetter | Select-Object -First 1 -ExpandProperty DriveLetter)
    if ($driveLetter) {
        $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
        if ($volume) {
            Write-Host ""
            Write-Host "卷信息：" -ForegroundColor Green
            $volume | Select-Object DriveLetter, FileSystem, FileSystemLabel,
                @{ Name = "Size"; Expression = { Format-Bytes $_.Size } },
                @{ Name = "Free"; Expression = { Format-Bytes $_.SizeRemaining } },
                HealthStatus | Format-List
        }

        Write-Host "正在尝试列出根目录前 10 项..." -ForegroundColor Green
        Get-ChildItem ("{0}:\\" -f $driveLetter) -Force -ErrorAction Stop |
            Select-Object -First 10 Name, Length, LastWriteTime |
            Format-Table -AutoSize
    }
    else {
        Write-Host "系统识别出了分区，但暂时没有分配盘符。可以在磁盘管理中手动分配。" -ForegroundColor Yellow
    }

    $summaryPath = Join-Path $outputDir "summary.txt"
    @(
        "DiskNumber=$DiskNumber"
        "FriendlyName=$($disk.FriendlyName)"
        "CandidateLba=$($candidate.Lba)"
        "CandidateTotalSectors=$($candidate.TotalSectors)"
        "OutputDir=$outputDir"
        "DriveLetter=$driveLetter"
        "Status=Success"
    ) | Set-Content -Path $summaryPath -Encoding UTF8

    Write-Section "完成"
    Write-Host "如果你已经能看到盘符和文件，说明这次最小修复成功了。" -ForegroundColor Green
    Write-Host ("所有备份和日志都保存在: {0}" -f $outputDir)
}
finally {
    Stop-Transcript | Out-Null
    Wait-ForExit
}
