<#
.SYNOPSIS
    Probe and debug an ESP32 serial/COM connection (Windows, no dependencies).

.DESCRIPTION
    Enumerates serial ports, identifies the USB-to-UART bridge chip from its
    USB VID/PID, checks whether a port can be opened (i.e. isn't held by another
    program), and optionally resets the ESP32 and captures its boot log so you
    can confirm the data link actually works.

    Pure .NET (System.IO.Ports) + CIM — runs on stock Windows PowerShell 5.1.

.PARAMETER List
    Just enumerate and identify the available COM ports, then exit.

.PARAMETER Port
    The port to open, e.g. COM5. If omitted, the script lists ports and exits.

.PARAMETER Baud
    Baud rate. Default 115200 (the ESP32 ROM boot log + this sketch's Serial).

.PARAMETER Seconds
    How long to read for. Default 15. Use 0 to read until you press Ctrl+C.

.PARAMETER Reset
    Pulse RTS (the EN/reset line on the standard auto-program circuit) to reboot
    the ESP32 before reading, so you capture the boot banner from the start.

.EXAMPLE
    .\serial-probe.ps1 -List

.EXAMPLE
    .\serial-probe.ps1 -Port COM5 -Reset

.EXAMPLE
    .\serial-probe.ps1 -Port COM5 -Baud 115200 -Seconds 0
#>
[CmdletBinding()]
param(
    [string]$Port,
    [int]$Baud = 115200,
    [int]$Seconds = 15,
    [switch]$Reset,
    [switch]$List
)

$ErrorActionPreference = 'Stop'

# Known USB-to-UART bridge vendors/devices, by USB VID (and a few VID:PID).
$KnownVid = @{
    '10C4' = 'Silicon Labs CP210x  (driver: Silicon Labs CP210x VCP)'
    '1A86' = 'WCH CH340/CH9102     (driver: WCH CH340/CH9102 VCP)'
    '0403' = 'FTDI FT232           (driver: FTDI VCP)'
    '303A' = 'Espressif native USB (no bridge; use BOOT button for download)'
    '2341' = 'Arduino-branded USB serial'
}

function Get-PortInventory {
    # Map COM names -> PnP friendly name + VID/PID via CIM.
    $pnp = @{}
    try {
        Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.Name -match '\(COM\d+\)' } |
            ForEach-Object {
                if ($_.Name -match '\((COM\d+)\)') {
                    $com = $Matches[1]
                    # NB: $pid is a read-only automatic variable in PowerShell,
                    # so the product id is held in $prodId.
                    $vid = $null; $prodId = $null
                    if ($_.DeviceID -match 'VID_([0-9A-Fa-f]{4})') { $vid = $Matches[1].ToUpper() }
                    if ($_.DeviceID -match 'PID_([0-9A-Fa-f]{4})') { $prodId = $Matches[1].ToUpper() }
                    $pnp[$com] = [pscustomobject]@{
                        Name = $_.Name
                        Vid  = $vid
                        Pid  = $prodId
                    }
                }
            }
    } catch {
        Write-Warning "Could not query CIM for device details: $($_.Exception.Message)"
    }

    $names = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object -Unique
    if (-not $names) { return @() }

    foreach ($n in $names) {
        $info = $pnp[$n]
        $chip = 'Unknown (driver may be missing)'
        if ($info -and $info.Vid) {
            if     ($KnownVid.ContainsKey($info.Vid))           { $chip = $KnownVid[$info.Vid] }
            else                                                { $chip = "VID:$($info.Vid) PID:$($info.Pid)" }
        }
        [pscustomobject]@{
            Port  = $n
            Chip  = $chip
            Vid   = if ($info) { $info.Vid } else { $null }
            Pid   = if ($info) { $info.Pid } else { $null }
            Name  = if ($info) { $info.Name } else { '(no PnP match)' }
        }
    }
}

function Test-PortOpenable([string]$p) {
    # Returns $true if the port can be opened (then immediately closes it).
    $sp = New-Object System.IO.Ports.SerialPort $p, 115200
    try {
        $sp.Open()
        $sp.Close()
        return $true
    } catch {
        return $false
    } finally {
        if ($sp) { $sp.Dispose() }
    }
}

Write-Host ''
Write-Host '=== Serial port inventory ===' -ForegroundColor Cyan
$inv = Get-PortInventory
if (-not $inv) {
    Write-Host 'No COM ports found.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Likely causes:' -ForegroundColor Yellow
    Write-Host '  * USB-UART driver not installed (CP210x / CH340 / FTDI).'
    Write-Host '  * Charge-only USB cable (no data lines) -> try another cable.'
    Write-Host '  * Board not powered / not plugged in.'
    return
}
foreach ($row in $inv) {
    $open = Test-PortOpenable $row.Port
    $state = if ($open) { 'free' } else { 'IN USE / access denied' }
    $color = if ($open) { 'Green' } else { 'Red' }
    Write-Host ('  {0,-6}  {1}' -f $row.Port, $row.Chip)
    Write-Host ('          {0}   [{1}]' -f $row.Name, $state) -ForegroundColor $color
}
Write-Host ''

if ($List -or -not $Port) {
    if (-not $Port) {
        Write-Host 'Tip: re-run with  -Port <COMx>  to open and read, add -Reset to reboot first.' -ForegroundColor DarkGray
    }
    return
}

# --- Open the requested port and read ---
if ($Port -notin ($inv.Port)) {
    Write-Host "Port $Port is not in the list above. Check the name and try again." -ForegroundColor Red
    return
}

Write-Host "=== Opening $Port @ $Baud baud ===" -ForegroundColor Cyan
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout  = 500
$sp.NewLine      = "`n"
# Don't let opening the port auto-reset the board unless we explicitly ask.
$sp.DtrEnable    = $false
$sp.RtsEnable    = $false

try {
    $sp.Open()
} catch {
    Write-Host "FAILED to open $Port : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Close the Arduino Serial Monitor / any other terminal using the port, then retry.' -ForegroundColor Yellow
    return
}

try {
    if ($Reset) {
        Write-Host 'Pulsing RTS (EN) to reset the board...' -ForegroundColor DarkGray
        # esptool-style hard reset: assert EN low, then release (IO0 stays high
        # via DtrEnable=$false, so the chip boots into normal run mode).
        $sp.DtrEnable = $false
        $sp.RtsEnable = $true
        Start-Sleep -Milliseconds 120
        $sp.RtsEnable = $false
    }

    Write-Host ''
    if ($Seconds -le 0) {
        Write-Host '--- reading (Ctrl+C to stop) ---' -ForegroundColor Cyan
    } else {
        Write-Host "--- reading for $Seconds s (Ctrl+C to stop early) ---" -ForegroundColor Cyan
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $gotData = $false
    while ($Seconds -le 0 -or $sw.Elapsed.TotalSeconds -lt $Seconds) {
        $chunk = $sp.ReadExisting()
        if ($chunk) {
            $gotData = $true
            # Print as-is; ReadExisting already gives decoded text.
            [Console]::Out.Write($chunk)
        } else {
            Start-Sleep -Milliseconds 50
        }
    }
    $sw.Stop()

    Write-Host ''
    Write-Host ''
    Write-Host '=== Verdict ===' -ForegroundColor Cyan
    if ($gotData) {
        Write-Host '  Data received -> the USB<->UART<->ESP32 link works.' -ForegroundColor Green
        Write-Host '  If uploads still time out, it is bootloader-mode timing, not the link:'
        Write-Host '   - Hold BOOT (IO0) when esptool prints "Connecting....", tap EN, release BOOT.'
        Write-Host '   - Or lower the upload speed to 115200.'
    } else {
        Write-Host '  No data received.' -ForegroundColor Yellow
        Write-Host '  - If you did NOT use -Reset, re-run with -Reset to capture the boot banner.'
        Write-Host '  - Wrong baud? The ESP32 app log here is 115200; the ROM also prints'
        Write-Host '    bootloader text at 74880 (try -Baud 74880).'
        Write-Host '  - TX/RX may not be wired through (some charge-ish cables): try another cable.'
        Write-Host '  - Board may not be running / stuck in download mode: tap EN to reset.'
    }
} finally {
    if ($sp -and $sp.IsOpen) { $sp.Close() }
    if ($sp) { $sp.Dispose() }
}
