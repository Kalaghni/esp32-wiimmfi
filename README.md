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
| `AP_SSID`         | Name of the network the DS joins. Default `"DS-WIIMMFI"`.              |
| `AP_USE_WPA2`     | `false` = open AP (required for Gen IV). `true` = WPA2 (Gen V/DSi/3DS).|
| `AP_PASSWORD`     | WPA2 passphrase (8–63 chars), used only when `AP_USE_WPA2` is `true`.  |
| `WFC_REDIRECT_IP` | WFC-revival target. Default `167.235.229.36` (WiiLink/RiiConnect24).   |
| `UPSTREAM_DNS`    | Resolver for non-redirected lookups. Default `1.1.1.1`.                |
| `AP_IP`/`AP_MASK` | AP network. Defaults `192.168.4.1` / `255.255.255.0`.                  |

> ⚠️ **Do not commit your real Wi-Fi credentials to this public repo.** Keep
> `STA_SSID`/`STA_PASSWORD` local, or load them another way.

### AP security (open vs. WPA2)

The AP defaults to **open** because the original DS's Gen IV Pokémon games
(Diamond/Pearl/Platinum/HeartGold/SoulSilver) only support open or WEP, and the
ESP32 can't host WEP in SoftAP mode — so open is the only mode a Gen IV DS can
join.

If **every** client you use supports WPA2 — **Gen V** (Black/White/Black2/White2),
DSi, or 3DS — you can secure the AP instead:

```cpp
static const bool  AP_USE_WPA2 = true;          // turn on WPA2-PSK
static const char* AP_PASSWORD = "your-passphrase";  // 8–63 characters
```

A Gen IV DS Lite will **not** be able to join while WPA2 is enabled. If the
passphrase is shorter than 8 characters the sketch logs a warning and falls back
to open so the AP still comes up.

### WFC redirect target

- Default `167.235.229.36` — **WiiLink / RiiConnect24**, which routes WFC to
  Wiimmfi.
- Alternative `178.62.43.212` — **Kaeru WFC**.

> These community-run IPs **drift over time**. Verify the current address
> against the revival service's published list before trusting it. If
> redirection "works" but the game can't connect, a stale IP is the first
> thing to check.

Or skip the community services entirely and **run your own server** — see
[Self-hosted server](#self-hosted-server) below; set `WFC_REDIRECT_IP` to your
server box's LAN IP.

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
   On the default open AP no key is needed. If you enabled `AP_USE_WPA2`, enter
   your `AP_PASSWORD` (Gen V / DSi / 3DS only).
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

## Self-hosted server

Instead of pointing the bridge at a community revival IP, you can run the WFC
backend yourself on a LAN machine (a Raspberry Pi or any always-on Linux box).
This repo vendors [WiiLink24/wfc-server](https://github.com/WiiLink24/wfc-server)
— an open-source (AGPL-3.0) reimplementation of the GameSpy + NAS services Nintendo
WFC ran on — under `server/`, with Docker tooling to bring it up.

The ESP32 already handles DNS, so the server needs **no DNS of its own**: the DS
resolves every `*.nintendowifi.net` name to your server box, and the server
host-routes all those vhosts on one IP.

### Requirements

- A Linux host on your LAN with **Docker** + **Docker Compose**.
- That host's **LAN IP** (`hostname -I` or `ip route get 1.1.1.1`).

### Bring it up

```bash
cp .env.example .env        # set DB_USER, DB_PASSWORD, API_SECRET
docker compose up -d --build
docker compose logs -f wwfc # watch each service report "Listening"
```

The Postgres schema (`server/schema.sql`) is imported automatically on first
run. The two containers talk over a private `wfcnet` bridge network, and **only**
the WFC ports the DS/Wii need are published to the host:

| Proto | Port(s)                     | Service                                   |
|-------|-----------------------------|-------------------------------------------|
| TCP   | 80                          | NAS auth + Pokémon HTTP (GTS, Mystery Gift) |
| TCP   | 28910 / 29900 / 29901 / 29920 | serverbrowser / gpcm / gpsp / gamestats |
| UDP   | 27900 / 27901               | qr2 (heartbeats) / natneg (matchmaking)   |

Postgres has **no published ports** — it's reachable only by `wwfc` over the
bridge (as host `db`). The internal RPC channels (`29997`–`29999`) stay inside
the container. So nothing but the table above is exposed to the LAN.

> Trade-off: on a bridge network Docker SNATs inbound UDP, so the server sees
> the docker gateway rather than the real client IP/port. Login, conntest, and
> most play are unaffected; only peer-to-peer **matchmaking (NatNeg)** can
> suffer. If matchmaking misbehaves, give `wwfc` its own LAN IP via a **macvlan**
> network, or switch it back to `network_mode: host`.

### Point the bridge at it

In `esp32-wiimmfi.ino` set `WFC_REDIRECT_IP` to the server box's LAN IP and
re-flash:

```cpp
static const IPAddress WFC_REDIRECT_IP(192, 168, 1, 50); // your server box
```

### Verify

```bash
# From another LAN host (replace <IP>):
curl -v http://<IP>/                                    # NAS responds
curl -s -H 'Host: conntest.nintendowifi.net' http://<IP>/   # conntest 200
nc -vz <IP> 28910 29900 29901 29920                     # TCP services up
```

Fastest game-side test is an emulator (melonDS / Dolphin) with its DNS set to
`<IP>`, bypassing the ESP32 to isolate the server. Then test real hardware
through the bridge: the ESP32 serial log should show
`... -> REDIRECTED to <IP>`, and `docker compose logs -f wwfc` should show the
sequence **NAS auth → GPCM login → serverbrowser/QR2 → NatNeg**.

### Caveats

- **Updating the server:** it's vendored via `git subtree`. Pull upstream with
  `git subtree pull --prefix=server https://github.com/WiiLink24/wfc-server.git main --squash`,
  then rebuild and re-verify.
- **Unmodified game discs/carts** may need patching with the
  [WiiLink wfc-patcher](https://github.com/WiiLink24/wfc-patcher-wii); the SBCM
  auto-patch payloads are **not** bundled here. Gen IV DS Pokémon still need the
  open AP (see [AP security](#ap-security-open-vs-wpa2)).
- **License:** `server/` is **AGPL-3.0** (see `NOTICE`). Running a *modified*
  server that others connect to triggers the AGPL source-offer obligation.

## Legal

For use with hardware and game copies you own. Wiimmfi, WiiLink, and the other
WFC-revival projects referenced here are independent community efforts and are
not affiliated with Nintendo.
