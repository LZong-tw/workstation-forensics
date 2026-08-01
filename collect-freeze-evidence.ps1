param(
    [int]$SinceHours = 24,
    [string]$OutputRoot,
    [switch]$CopyLargeDumps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $scriptRoot "evidence"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$computer = [Environment]::MachineName
if ([string]::IsNullOrWhiteSpace($computer)) {
    try {
        $computer = (hostname).Trim()
    }
    catch {
        $computer = "WORKSTATION"
    }
}
$computer = $computer -replace "[^\w.-]", "_"
if ([string]::IsNullOrWhiteSpace($computer)) {
    $computer = "WORKSTATION"
}
$runRoot = Join-Path $OutputRoot "$stamp-$computer"
$dirs = @(
    $runRoot,
    (Join-Path $runRoot "events"),
    (Join-Path $runRoot "drivers"),
    (Join-Path $runRoot "power"),
    (Join-Path $runRoot "search-shell"),
    (Join-Path $runRoot "dumps"),
    (Join-Path $runRoot "wer")
)

foreach ($dir in $dirs) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

function Write-Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$InputObject
    )

    $InputObject | Out-String -Width 4096 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Capture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    try {
        $output = & $ScriptBlock 2>&1
        Write-Text -Path $Path -InputObject $output
    }
    catch {
        Write-Text -Path $Path -InputObject $_
    }
}

function Copy-IfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    try {
        if (Test-Path -LiteralPath $Source) {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return $true
        }
    }
    catch {
        $_ | Out-String | Add-Content -LiteralPath (Join-Path $runRoot "copy-errors.txt") -Encoding UTF8
    }

    return $false
}

$os = Get-CimInstance Win32_OperatingSystem
$bootTime = $os.LastBootUpTime
$since = $bootTime
$requestedSince = (Get-Date).AddHours(-1 * [Math]::Abs($SinceHours))
if ($requestedSince -lt $since) {
    $since = $requestedSince
}

$patterns = @(
    "0x0000014f",
    "PDC_WATCHDOG_TIMEOUT",
    "ModernExecServer",
    "Kernel-Power",
    "BugCheck",
    "LiveKernelEvent",
    "Netwaw16",
    "IntelWiFiLkd",
    "WLAN",
    "Wi-Fi",
    "SearchFilterHost",
    "SearchIndexer",
    "SearchHost",
    "StartMenuExperienceHost",
    "ShellExperienceHost",
    "dwm.exe",
    "Cloudflare WARP",
    "Wintun",
    "Hyper-V-VmSwitch"
)
$patternRegex = ($patterns | ForEach-Object { [regex]::Escape($_) }) -join "|"

$crashControlPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
$summary = [ordered]@{
    CollectedAt = Get-Date
    OutputRoot = $runRoot
    Since = $since
    BootTime = $bootTime
    ComputerName = $computer
    OSVersion = $os.Version
    OSBuild = $os.BuildNumber
    InstallDate = $os.InstallDate
    LastBootUpTime = $os.LastBootUpTime
}

$bios = Get-CimInstance Win32_BIOS
$system = Get-CimInstance Win32_ComputerSystem
$summary["SystemModel"] = $system.Model
$summary["Manufacturer"] = $system.Manufacturer
$summary["BIOSVersion"] = $bios.SMBIOSBIOSVersion
$summary["BIOSReleaseDate"] = $bios.ReleaseDate

try {
    $crashControl = Get-ItemProperty -Path $crashControlPath -ErrorAction Stop
    foreach ($name in "CrashDumpEnabled", "DumpFile", "MinidumpDir", "Overwrite", "AlwaysKeepMemoryDump") {
        $property = $crashControl.PSObject.Properties[$name]
        if ($null -ne $property) {
            $summary[$name] = $property.Value
        }
        else {
            $summary[$name] = $null
        }
    }
}
catch {
    $summary["CrashControlReadError"] = $_.Exception.Message
}

Write-Text -Path (Join-Path $runRoot "summary.txt") -InputObject ([pscustomobject]$summary)

Invoke-Capture -Path (Join-Path $runRoot "systeminfo.txt") -ScriptBlock { systeminfo }
Invoke-Capture -Path (Join-Path $runRoot "hotfixes.txt") -ScriptBlock { Get-HotFix | Sort-Object InstalledOn -Descending }

Invoke-Capture -Path (Join-Path $runRoot "drivers\key-drivers.txt") -ScriptBlock {
    $driverRegex = "Intel\(R\) Wi-Fi 7 BE200|Intel\(R\) Arc|Intel\(R\) Graphics Software|Intel\(R\) Wireless Bluetooth|Intel\(R\) Management Engine Interface|Intel\(R\) Ethernet Connection|Cloudflare WARP Interface Tunnel|Wintun Userspace Tunnel|Intel\(R\) Innovation Platform Framework"
    Get-CimInstance Win32_PnPSignedDriver |
        Where-Object { $_.DeviceName -match $driverRegex } |
        Select-Object DeviceName, DriverProviderName, DriverVersion, DriverDate, InfName, DeviceClass, DeviceID |
        Sort-Object DeviceName
}

Invoke-Capture -Path (Join-Path $runRoot "drivers\all-net-display-system-drivers.txt") -ScriptBlock {
    Get-CimInstance Win32_PnPSignedDriver |
        Where-Object { $_.DeviceClass -in @("NET", "DISPLAY", "BLUETOOTH", "SYSTEM") } |
        Select-Object DeviceName, DriverProviderName, DriverVersion, DriverDate, InfName, DeviceClass, DeviceID |
        Sort-Object DeviceClass, DeviceName
}

Invoke-Capture -Path (Join-Path $runRoot "drivers\wlan-drivers.txt") -ScriptBlock { netsh wlan show drivers }
Invoke-Capture -Path (Join-Path $runRoot "drivers\wlan-interfaces.txt") -ScriptBlock { netsh wlan show interfaces }
Invoke-Capture -Path (Join-Path $runRoot "drivers\network-adapters.txt") -ScriptBlock {
    Get-CimInstance Win32_NetworkAdapter |
        Where-Object { $_.PhysicalAdapter -or $_.Name -match "WARP|Wintun|Wi-Fi|Ethernet|Hyper-V" } |
        Select-Object Name, NetConnectionID, Manufacturer, AdapterType, MACAddress, NetEnabled, Speed, PNPDeviceID |
        Sort-Object Name
}

Invoke-Capture -Path (Join-Path $runRoot "search-shell\services.txt") -ScriptBlock {
    Get-Service WSearch, StateRepository, AppXSvc, ClipSVC, TokenBroker -ErrorAction SilentlyContinue |
        Select-Object Name, DisplayName, Status, StartType
}

Invoke-Capture -Path (Join-Path $runRoot "search-shell\processes.txt") -ScriptBlock {
    Get-Process StartMenuExperienceHost, SearchHost, SearchIndexer, SearchProtocolHost, SearchFilterHost, ShellExperienceHost, RuntimeBroker, dwm -ErrorAction SilentlyContinue |
        Select-Object ProcessName, Id, StartTime, CPU, Path |
        Sort-Object ProcessName, StartTime
}

Invoke-Capture -Path (Join-Path $runRoot "search-shell\start-menu-shortcuts.txt") -ScriptBlock {
    $programs = @(
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    )
    foreach ($path in $programs) {
        if (Test-Path -LiteralPath $path) {
            $links = Get-ChildItem -LiteralPath $path -Recurse -Filter *.lnk -ErrorAction SilentlyContinue
            $latest = $links | Sort-Object LastWriteTime -Descending | Select-Object -First 10
            [pscustomobject]@{
                Path = $path
                LnkCount = $links.Count
                KaliOrWslCount = ($links | Where-Object { $_.FullName -match "kali|wsl|linux" }).Count
                LatestLinks = ($latest | ForEach-Object { "$($_.LastWriteTime) $($_.FullName)" }) -join "`n"
            }
        }
    }
}

Invoke-Capture -Path (Join-Path $runRoot "search-shell\appx-shell-packages.txt") -ScriptBlock {
    Get-AppxPackage |
        Where-Object { $_.Name -match "Search|Start|Client\.CBS|WebExperience|ShellExperience|Cortana|WindowsStore|BingSearch|StartExperiences" } |
        Select-Object Name, PackageFullName, Version, Status, InstallLocation |
        Sort-Object Name
}

Invoke-Capture -Path (Join-Path $runRoot "power\powercfg-a.txt") -ScriptBlock { powercfg /a }
Invoke-Capture -Path (Join-Path $runRoot "power\powercfg-requests.txt") -ScriptBlock { powercfg /requests }
Invoke-Capture -Path (Join-Path $runRoot "power\sleepstudy-command.txt") -ScriptBlock {
    powercfg /sleepstudy /output (Join-Path $runRoot "power\sleepstudy.html")
}

Invoke-Capture -Path (Join-Path $runRoot "events\related-errors.txt") -ScriptBlock {
    $relatedEvents = foreach ($log in "System", "Application") {
        Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since; Level = 1, 2, 3 } -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -match $patternRegex -or $_.Message -match $patternRegex } |
            Select-Object @{ Name = "Log"; Expression = { $log } }, TimeCreated, Id, ProviderName, LevelDisplayName, Message
    }
    $relatedEvents | Sort-Object TimeCreated
}

try {
    Get-WinEvent -FilterHashtable @{ LogName = "System"; StartTime = $since; Level = 1, 2, 3 } -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
        Export-Csv -NoTypeInformation -Path (Join-Path $runRoot "events\system-errors.csv")
}
catch {
    Write-Text -Path (Join-Path $runRoot "events\system-errors.csv.error.txt") -InputObject $_
}

try {
    Get-WinEvent -FilterHashtable @{ LogName = "Application"; StartTime = $since; Level = 1, 2, 3 } -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
        Export-Csv -NoTypeInformation -Path (Join-Path $runRoot "events\application-errors.csv")
}
catch {
    Write-Text -Path (Join-Path $runRoot "events\application-errors.csv.error.txt") -InputObject $_
}

$eventLogs = @(
    "Microsoft-Windows-AppModel-Runtime/Admin",
    "Microsoft-Windows-StateRepository/Operational",
    "Microsoft-Windows-SearchUI/Operational",
    "Microsoft-Windows-Shell-Core/Operational",
    "Microsoft-Windows-ShellCommon-StartLayoutPopulation/Operational"
)

foreach ($eventLog in $eventLogs) {
    $fileName = ($eventLog -replace "[\\\/:]", "_") + ".txt"
    Invoke-Capture -Path (Join-Path $runRoot "events\$fileName") -ScriptBlock {
        Get-WinEvent -FilterHashtable @{ LogName = $eventLog; StartTime = $since } -ErrorAction SilentlyContinue |
            Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
            Sort-Object TimeCreated
    }
}

Invoke-Capture -Path (Join-Path $runRoot "events\reliability-records.txt") -ScriptBlock {
    Get-CimInstance Win32_ReliabilityRecords -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                [datetime]$_.TimeGenerated -ge $since
            }
            catch {
                $false
            }
        } |
        Where-Object {
            $_.ProductName -match $patternRegex -or
            $_.SourceName -match $patternRegex -or
            $_.Message -match $patternRegex
        } |
        Select-Object TimeGenerated, SourceName, ProductName, EventIdentifier, Message |
        Sort-Object TimeGenerated
}

Invoke-Capture -Path (Join-Path $runRoot "dumps\dump-inventory.txt") -ScriptBlock {
    $dumpRoots = @(
        "C:\Windows\Minidump",
        "C:\Windows\LiveKernelReports",
        "C:\Windows"
    )
    $dumpInventory = foreach ($root in $dumpRoots) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "\.dmp$" -or $_.Name -eq "MEMORY.DMP" } |
                Select-Object FullName, Length, LastWriteTime
        }
    }
    $dumpInventory | Sort-Object LastWriteTime -Descending
}

$minidumpDir = "C:\Windows\Minidump"
if (Test-Path -LiteralPath $minidumpDir) {
    $recentMiniDumps = Get-ChildItem -LiteralPath $minidumpDir -Filter *.dmp -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $since }
    foreach ($dump in $recentMiniDumps) {
        Copy-IfPresent -Source $dump.FullName -Destination (Join-Path $runRoot "dumps\$($dump.Name)") | Out-Null
    }
}

if ($CopyLargeDumps) {
    Copy-IfPresent -Source "C:\Windows\MEMORY.DMP" -Destination (Join-Path $runRoot "dumps\MEMORY.DMP") | Out-Null
}

$werRoots = @(
    "C:\ProgramData\Microsoft\Windows\WER\ReportArchive",
    "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"
)

foreach ($werRoot in $werRoots) {
    if (Test-Path -LiteralPath $werRoot) {
        $reports = Get-ChildItem -LiteralPath $werRoot -Recurse -Filter Report.wer -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $since }
        foreach ($report in $reports) {
            try {
                $hit = Select-String -LiteralPath $report.FullName -Pattern $patternRegex -CaseSensitive:$false -ErrorAction SilentlyContinue -List
                if ($hit) {
                    $safeName = ($report.Directory.Name -replace "[^\w.-]", "_") + ".wer"
                    Copy-IfPresent -Source $report.FullName -Destination (Join-Path $runRoot "wer\$safeName") | Out-Null
                }
            }
            catch {
                $_ | Out-String | Add-Content -LiteralPath (Join-Path $runRoot "copy-errors.txt") -Encoding UTF8
            }
        }
    }
}

Write-Host "Evidence collected:"
Write-Host $runRoot
