# esp32-wiimmfi

Turn an ESP32 into a Wi-Fi bridge that lets an original **Nintendo DS / DS Lite**
get back online through **Wiimmfi** (via a WFC-revival DNS redirect).

The ESP32 runs in **AP+STA** mode:

- **STA** — joins your home Wi-Fi for the internet uplink.
- **AP** — hosts an **open** (unencrypted) network the DS connects to. NAPT
  routes the DS's traffic out through the STA uplink.

A small DNS server runs on UDP port 53. Any A-record lookup for
`nintendowifi.net` (or a subdomain like `dls1.nintendowifi.net`) is answered
with a configurable WFC-revival IP so Nintendo WFC traffic is redirected. Every
other query is forwarded to a real upstream resolver (default `1.1.1.1`) and
relayed back.

> **Why is the AP open?** The ESP32 Wi-Fi driver cannot host WEP in SoftAP
> mode, and the original DS WFC only supported open/WEP networks. The DS
> connects to open networks fine, so an open AP is the simplest thing that
> works. Treat this AP as untrusted — anyone nearby can join it.

Uses **only** the Arduino core's `WiFi.h` and `WiFiUdp.h`. No external libraries.

---

## Hardware

- Any ESP32 dev board (ESP32, ESP32-S2/S3, etc.) with Wi-Fi.
- A USB cable for flashing and serial logging.

## Software

- [Arduino IDE](https://www.arduino.cc/en/software) (1.8.x or 2.x), **or**
  `arduino-cli`.
- **Arduino-ESP32 core 3.x** (recommended) — provides
  `WiFi.AP.enableNAPT(true)`.
  - On an older 2.x core, `WiFi.AP.enableNAPT()` does not exist. Use the
    commented fallback in the sketch instead:
    ```cpp
    #include "lwip/lwip_napt.h"
    ip_napt_enable(htonl(AP_IP), 1);
    ```

### Install the ESP32 core (Arduino IDE)

1. **File → Preferences → Additional boards manager URLs**, add:
   ```
   https://espressif.github.io/arduino-esp32/package_esp32_index.json
   ```
2. **Tools → Board → Boards Manager**, search **esp32**, install
   **esp32 by Espressif Systems** (3.x).

### Install the ESP32 core (arduino-cli)

```bash
arduino-cli config init
arduino-cli config add board_manager.additional_urls \
  https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core update-index
arduino-cli core install esp32:esp32
```

---

## Configure

Open `esp32-wiimmfi.ino` and edit the config constants near the top:

| Constant          | What to set                                                            |
|-------------------|------------------------------------------------------------------------|
| `STA_SSID`        | Your home Wi-Fi SSID (the internet uplink).                            |
| `STA_PASSWORD`    | Your home Wi-Fi password.                                              |
| `AP_SSID`         | Name of the open network the DS joins. Default `"DS-WIIMMFI"`.         |
| `WFC_REDIRECT_IP` | WFC-revival target. Default `167.235.229.36` (WiiLink/RiiConnect24).   |
| `UPSTREAM_DNS`    | Resolver for non-redirected lookups. Default `1.1.1.1`.                |
| `AP_IP`/`AP_MASK` | AP network. Defaults `192.168.4.1` / `255.255.255.0`.                  |

> ⚠️ **Do not commit your real Wi-Fi credentials to this public repo.** Keep
> `STA_SSID`/`STA_PASSWORD` local, or load them another way.

### WFC redirect target

- Default `167.235.229.36` — **WiiLink / RiiConnect24**, which routes WFC to
  Wiimmfi.
- Alternative `178.62.43.212` — **Kaeru WFC**.

> These community-run IPs **drift over time**. Verify the current address
> against the revival service's published list before trusting it. If
> redirection "works" but the game can't connect, a stale IP is the first
> thing to check.

---

## Build & flash

### Arduino IDE

1. Open `esp32-wiimmfi.ino`.
2. **Tools → Board** → your ESP32 board.
3. **Tools → Port** → the board's serial port.
4. Click **Upload**.
5. Open **Tools → Serial Monitor** at **115200 baud**.

### arduino-cli

```bash
# Compile (replace the FQBN with your board, e.g. esp32:esp32:esp32s3)
arduino-cli compile --fqbn esp32:esp32:esp32 esp32-wiimmfi.ino

# Flash (replace the port)
arduino-cli upload --fqbn esp32:esp32:esp32 -p /dev/ttyUSB0 esp32-wiimmfi.ino

# Watch the logs
arduino-cli monitor -p /dev/ttyUSB0 -c baudrate=115200
```

---

## Connect the DS

1. Power the ESP32. The serial log should show the AP coming up, the STA
   connecting, and NAPT enabling.
2. On the DS, open a WFC-enabled game's **Nintendo Wi-Fi Connection Setup**.
3. **Search for an Access Point** and pick **`DS-WIIMMFI`** (or your `AP_SSID`).
   No WEP key is needed — it's an open network.
4. Save and run the connection test. The DS gets `192.168.4.1` as both gateway
   and DNS via DHCP, so its WFC lookups hit this bridge.

## Verify

Watch the Serial Monitor (115200 baud). Every lookup is logged, e.g.:

```
[dns] conntest.nintendowifi.net -> REDIRECTED to 167.235.229.36
[dns] dls1.nintendowifi.net -> REDIRECTED to 167.235.229.36
[dns] example.com -> forwarded
```

`dls1.nintendowifi.net` is the Mystery Gift / download server — seeing it
redirected confirms the game's download traffic is going through the bridge.

---

## Troubleshooting

- **DS can't see the AP** — make sure the ESP32 booted; check `[ap] ... up` in
  the log. The DS only supports 2.4 GHz, which the ESP32 AP uses anyway.
- **DS connects but the test fails** — the STA must be connected and NAPT
  enabled (check the log). Confirm your `WFC_REDIRECT_IP` is current.
- **`WiFi.AP.enableNAPT` won't compile** — you're on a 2.x core. Switch to the
  `ip_napt_enable()` fallback shown above, or upgrade to core 3.x.
- **No DNS logs at all** — verify the DS is actually using `192.168.4.1` for
  DNS (it should via DHCP) and that nothing else occupies UDP 53.

## Legal

For use with hardware and game copies you own. Wiimmfi and the WFC-revival
services listed here are independent community projects and are not affiliated
with Nintendo.
