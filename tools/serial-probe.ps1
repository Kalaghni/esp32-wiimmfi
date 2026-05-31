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

.PARAMETER Watch
    Snapshot current ports, then watch for ~30s for a NEW port to appear as you
    plug the board in. The fastest way to find which COM port is the ESP32 (and
    to prove it enumerates at all).

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
    [switch]$List,
    [switch]$Watch
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
        $name = if ($info) { $info.Name } else { '(no PnP match)' }
        # Bluetooth virtual ports are never an ESP32 - flag them so they aren't
        # mistaken for the board (a very common cause of "Write timeout").
        $isBt = $name -match 'Bluetooth'
        $chip = if ($isBt) { 'Bluetooth virtual port  (NOT your ESP32)' }
                else        { 'Unknown (driver may be missing)' }
        if (-not $isBt -and $info -and $info.Vid) {
            if     ($KnownVid.ContainsKey($info.Vid)) { $chip = $KnownVid[$info.Vid] }
            else                                      { $chip = "VID:$($info.Vid) PID:$($info.Pid)" }
        }
        [pscustomobject]@{
            Port        = $n
            Chip        = $chip
            Vid         = if ($info) { $info.Vid } else { $null }
            Pid         = if ($info) { $info.Pid } else { $null }
            Name        = $name
            IsBluetooth = [bool]$isBt
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
    $chipColor = if ($row.IsBluetooth) { 'DarkGray' } else { 'White' }
    $color = if ($open) { 'Green' } else { 'Red' }
    Write-Host ('  {0,-6}  {1}' -f $row.Port, $row.Chip) -ForegroundColor $chipColor
    Write-Host ('          {0}   [{1}]' -f $row.Name, $state) -ForegroundColor $color
}
Write-Host ''

# Is there anything that could actually be an ESP32 (i.e. not Bluetooth)?
$candidates = @($inv | Where-Object { -not $_.IsBluetooth })
if ($candidates.Count -eq 0) {
    Write-Host 'No USB-UART port detected - every port above is a Bluetooth virtual port.' -ForegroundColor Red
    Write-Host 'Your ESP32 is NOT enumerating. This is the real problem (uploading to a' -ForegroundColor Yellow
    Write-Host 'Bluetooth COM port is what produced the "Write timeout").' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Fix, in order:' -ForegroundColor Yellow
    Write-Host '  1. Re-run with -Watch, then plug the board in, to catch the new port.'
    Write-Host '  2. Install the USB-UART driver for your board''s chip:'
    Write-Host '       CP2102/CP210x -> Silicon Labs CP210x VCP driver'
    Write-Host '       CH340/CH9102  -> WCH CH340 VCP driver'
    Write-Host '     (Open Device Manager; a yellow-! device appears when you plug in.)'
    Write-Host '  3. Use a DATA USB cable (many are charge-only) and a rear/direct USB port.'
    Write-Host '  4. ESP32-S2/S3 native-USB boards: hold BOOT while plugging in to enumerate.'
    Write-Host ''
}

# --- Watch mode: detect a port appearing when you plug the board in ---
if ($Watch) {
    $before = [System.IO.Ports.SerialPort]::GetPortNames()
    Write-Host '=== Watch mode ===' -ForegroundColor Cyan
    Write-Host ('Baseline ports: {0}' -f ($before -join ', '))
    Write-Host 'Now (re)plug the ESP32 USB cable. Watching 30s for a new port...' -ForegroundColor Yellow
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $found = $false
    while ($sw.Elapsed.TotalSeconds -lt 30) {
        Start-Sleep -Milliseconds 500
        $now = [System.IO.Ports.SerialPort]::GetPortNames()
        $new = @($now | Where-Object { $_ -notin $before })
        if ($new.Count -gt 0) {
            $found = $true
            foreach ($p in $new) {
                $row = Get-PortInventory | Where-Object { $_.Port -eq $p }
                Write-Host ''
                Write-Host ("NEW PORT: {0}  ->  {1}" -f $p, ($row.Chip)) -ForegroundColor Green
                Write-Host ("That is almost certainly your ESP32. Flash with -p {0}." -f $p) -ForegroundColor Green
            }
            break
        }
    }
    if (-not $found) {
        Write-Host ''
        Write-Host 'No new port appeared in 30s. The board is not enumerating:' -ForegroundColor Red
        Write-Host '  -> driver missing, charge-only cable, dead USB port, or board not powered.' -ForegroundColor Yellow
    }
    return
}

if ($List -or -not $Port) {
    if (-not $Port) {
        Write-Host 'Tip: -Watch (plug in to find the port), or -Port <COMx> -Reset to read it.' -ForegroundColor DarkGray
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
