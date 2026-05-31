/*
 * esp32-wiimmfi.ino
 *
 * A self-contained Nintendo DS Lite -> Wiimmfi bridge for the ESP32.
 *
 * The ESP32 runs in AP+STA mode:
 *   - As a station (STA) it joins your home Wi-Fi for the internet uplink.
 *   - As an access point (AP) it hosts a network the DS connects to, and
 *     NAPT routes the DS's traffic out through the STA uplink.
 *
 * A tiny DNS server runs on UDP port 53. Any A-record lookup for
 * nintendowifi.net (or a subdomain of it) is answered with a configurable
 * WFC-revival IP so Nintendo WFC traffic is redirected to Wiimmfi. Every
 * other query is forwarded to a real upstream resolver and relayed back.
 *
 * Only the Arduino core's WiFi.h and WiFiUdp.h are used -- no extra libraries.
 *
 * NOTE ON AP SECURITY: the AP defaults to an OPEN (unencrypted) network.
 * The ESP32 Wi-Fi driver cannot host WEP in SoftAP mode, and the original DS
 * WFC only supported open/WEP networks -- Gen IV Pokemon games (D/P/Pt/HG/SS)
 * can ONLY join open here, so open is the safe default. Newer clients that
 * support WPA2 (Gen V Pokemon B/W/B2/W2, DSi, 3DS) can instead use a secured
 * AP by setting AP_USE_WPA2 = true and AP_PASSWORD below.
 */

#include <WiFi.h>
#include <WiFiUdp.h>

// ======================== Config constants ========================

// --- Your home Wi-Fi (STA / internet uplink) ---
static const char* STA_SSID     = "YOUR_HOME_SSID";
static const char* STA_PASSWORD = "YOUR_HOME_PASSWORD";

// --- AP the DS connects to ---
static const char* AP_SSID = "DS-WIIMMFI";

// AP security mode.
//   false -> OPEN network (no encryption). Required for original DS WFC Gen IV
//            Pokemon games (Diamond/Pearl/Platinum/HeartGold/SoulSilver), which
//            only support open or WEP and CANNOT connect to a WPA/WPA2 AP.
//   true  -> WPA2-PSK. Only works for consoles/games that support WPA2, e.g.
//            Gen V Pokemon (Black/White/Black2/White2) and the DSi/3DS. A DS
//            Lite running a Gen IV title will not see/join this AP.
// Leave this false unless every client you care about supports WPA2.
static const bool AP_USE_WPA2 = false;

// WPA2 passphrase for the AP, used only when AP_USE_WPA2 is true.
// Must be 8-63 characters (WPA2-PSK requirement); ignored in open mode.
static const char* AP_PASSWORD = "changeme123";

// --- WFC redirect target ---
// Default: 167.235.229.36 = WiiLink / RiiConnect24, which routes WFC to Wiimmfi.
// Alternative: Kaeru WFC at 178.62.43.212.
// NOTE: these community-run IPs drift over time. Verify against the current
// published lists for whichever revival service you intend to use before
// trusting this value.
static const IPAddress WFC_REDIRECT_IP(167, 235, 229, 36);

// --- Upstream resolver used for everything we don't redirect ---
static const IPAddress UPSTREAM_DNS(1, 1, 1, 1);

// --- AP network settings ---
static const IPAddress AP_IP(192, 168, 4, 1);
static const IPAddress AP_GATEWAY(192, 168, 4, 1);
static const IPAddress AP_MASK(255, 255, 255, 0);

// The domain we hijack. Matched case-insensitively as a suffix, so this also
// covers any subdomain such as dls1.nintendowifi.net, conntest.nintendowifi.net, etc.
static const char* REDIRECT_DOMAIN = "nintendowifi.net";

// DNS works on port 53. ~600-byte buffers are plenty for DS WFC traffic.
static const uint16_t DNS_PORT      = 53;
static const size_t   DNS_BUF_SIZE  = 600;
static const uint32_t UPSTREAM_TIMEOUT_MS = 1500;  // ~1.5s upstream round-trip cap

// ======================== Globals ========================

WiFiUDP dnsServer;    // listens on port 53 for the DS
WiFiUDP dnsUpstream;  // talks to UPSTREAM_DNS for forwarded queries

// ======================== Setup ========================

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println();
  Serial.println(F("[boot] esp32-wiimmfi DNS bridge starting"));

  // AP + STA so we can host the DS and reach the internet at the same time.
  WiFi.mode(WIFI_AP_STA);

  // ---- Configure the SoftAP ----
  // softAPConfig(localIP, gateway, subnet) sets the AP's address and, on the
  // ESP32 core, hands that same address out as the gateway *and* the DNS server
  // over DHCP. So the DS gets 192.168.4.1 as both gateway and DNS, which means
  // its WFC DNS queries land on our server above.
  WiFi.softAPConfig(AP_IP, AP_GATEWAY, AP_MASK);

  // Bring up the AP. In open mode we pass no password, which leaves the AP
  // unencrypted (the only thing Gen IV DS games can join). In WPA2 mode we
  // pass AP_PASSWORD; the ESP32 core defaults SoftAP encryption to WPA2-PSK
  // when a valid (8-63 char) passphrase is supplied. (WEP is intentionally not
  // offered: the ESP32 Wi-Fi driver cannot host WEP in SoftAP mode.)
  bool apOk;
  const char* apMode;
  if (AP_USE_WPA2 && strlen(AP_PASSWORD) >= 8) {
    apOk = WiFi.softAP(AP_SSID, AP_PASSWORD);
    apMode = "WPA2";
  } else {
    if (AP_USE_WPA2) {
      // Asked for WPA2 but the passphrase is too short to be valid -- fall back
      // to open rather than silently failing to start the AP.
      Serial.println(F("[ap] WARNING: AP_PASSWORD too short for WPA2 (need 8+ "
                       "chars); falling back to OPEN"));
    }
    apOk = WiFi.softAP(AP_SSID);
    apMode = "open";
  }
  Serial.printf("[ap] SSID \"%s\" (%s) %s, IP %s\n",
                AP_SSID, apMode, apOk ? "up" : "FAILED",
                WiFi.softAPIP().toString().c_str());

  // ---- Join home Wi-Fi (uplink) ----
  Serial.printf("[sta] connecting to \"%s\"", STA_SSID);
  WiFi.begin(STA_SSID, STA_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print('.');
  }
  Serial.println();
  Serial.printf("[sta] connected, IP %s\n", WiFi.localIP().toString().c_str());

  // ---- Enable NAPT so AP clients route out through the STA uplink ----
  // Arduino-ESP32 3.x exposes this directly:
  if (WiFi.AP.enableNAPT(true)) {
    Serial.println(F("[napt] enabled via WiFi.AP.enableNAPT(true)"));
  } else {
    Serial.println(F("[napt] WiFi.AP.enableNAPT(true) failed"));
  }
  // Fallback for older cores (pre-3.x) -- include lwip/napt and use:
  //   #include "lwip/lwip_napt.h"
  //   ip_napt_enable(htonl(AP_IP), 1);

  // ---- Start the DNS sockets ----
  dnsServer.begin(DNS_PORT);
  // Bind the upstream socket to an ephemeral local port for replies.
  dnsUpstream.begin(0);

  Serial.printf("[dns] listening on %s:%u, redirecting *.%s -> %s, upstream %s\n",
                AP_IP.toString().c_str(), DNS_PORT, REDIRECT_DOMAIN,
                WFC_REDIRECT_IP.toString().c_str(),
                UPSTREAM_DNS.toString().c_str());
}

// ======================== DNS helpers ========================

// Parse the QNAME (and the type/class that follow it) out of a DNS query.
//
// `packet`/`len` is the raw query. On success returns true and fills:
//   outName   - the dotted question name, lowercased (e.g. "dls1.nintendowifi.net")
//   outQType  - the QTYPE  (1 = A record)
//   outQClass - the QCLASS (1 = IN)
//   outQEnd   - byte offset just past the question (start of the answer area)
//
// Only the first question is parsed (DS WFC only ever asks one at a time).
static bool parseQuestion(const uint8_t* packet, size_t len,
                          char* outName, size_t outNameCap,
                          uint16_t& outQType, uint16_t& outQClass,
                          size_t& outQEnd) {
  // Need at least the 12-byte header.
  if (len < 12) return false;

  // QDCOUNT lives at bytes 4-5; we expect at least one question.
  uint16_t qdcount = (packet[4] << 8) | packet[5];
  if (qdcount < 1) return false;

  size_t pos = 12;       // questions start right after the header
  size_t nameLen = 0;
  outName[0] = '\0';

  // Walk the label sequence: each label is [len][bytes...], terminated by a
  // zero-length label. We don't follow compression pointers in the question
  // (queries don't use them) and bail if we see one.
  while (true) {
    if (pos >= len) return false;
    uint8_t labelLen = packet[pos++];

    if (labelLen == 0) break;                 // end of name
    if ((labelLen & 0xC0) != 0) return false; // compression pointer -- unexpected here
    if (pos + labelLen > len) return false;   // label runs off the end

    // Append a dot between labels.
    if (nameLen > 0) {
      if (nameLen + 1 >= outNameCap) return false;
      outName[nameLen++] = '.';
    }
    for (uint8_t i = 0; i < labelLen; i++) {
      if (nameLen + 1 >= outNameCap) return false;
      char c = (char)packet[pos++];
      // Lowercase as we go so suffix matching is case-insensitive.
      if (c >= 'A' && c <= 'Z') c = c - 'A' + 'a';
      outName[nameLen++] = c;
    }
  }
  outName[nameLen] = '\0';

  // After the name come QTYPE (2 bytes) and QCLASS (2 bytes).
  if (pos + 4 > len) return false;
  outQType  = (packet[pos] << 8) | packet[pos + 1];
  outQClass = (packet[pos + 2] << 8) | packet[pos + 3];
  pos += 4;

  outQEnd = pos;  // start of the answer section in a reply
  return true;
}

// Case-insensitive check: does `name` equal `suffix` or end in ".suffix"?
// `name` is already lowercased by parseQuestion; `suffix` is lowercased here.
static bool nameMatchesSuffix(const char* name, const char* suffix) {
  size_t nLen = strlen(name);
  size_t sLen = strlen(suffix);
  if (sLen == 0 || nLen < sLen) return false;

  // Compare the trailing sLen characters, case-insensitively.
  const char* tail = name + (nLen - sLen);
  for (size_t i = 0; i < sLen; i++) {
    char a = tail[i];
    char b = suffix[i];
    if (a >= 'A' && a <= 'Z') a = a - 'A' + 'a';
    if (b >= 'A' && b <= 'Z') b = b - 'A' + 'a';
    if (a != b) return false;
  }

  // Exact match, or there must be a '.' right before the suffix so we don't
  // match "evilnintendowifi.net" against "nintendowifi.net".
  if (nLen == sLen) return true;
  return name[nLen - sLen - 1] == '.';
}

// Build an A-record reply that redirects the query to `ip`.
//
// We copy the original header + question verbatim, flip it into a response,
// set ANCOUNT=1, and append one answer that points back at the question name
// with a compression pointer.
//
// `query`/`queryLen` is the original packet; `qEnd` is the offset just past
// the question (from parseQuestion). The reply is written into `out` and its
// length returned (0 on failure / buffer too small).
static size_t buildRedirectReply(const uint8_t* query, size_t qEnd,
                                 const IPAddress& ip,
                                 uint8_t* out, size_t outCap) {
  // We need the header+question plus a 16-byte answer record.
  if (qEnd + 16 > outCap) return 0;

  // Copy header + question as-is.
  memcpy(out, query, qEnd);

  // Flags = 0x8180: QR (response) + RD copied + RA (recursion available).
  out[2] = 0x81;
  out[3] = 0x80;
  // ANCOUNT = 1
  out[6] = 0x00;
  out[7] = 0x01;
  // NSCOUNT = 0, ARCOUNT = 0
  out[8] = 0x00; out[9] = 0x00;
  out[10] = 0x00; out[11] = 0x00;

  size_t p = qEnd;
  // Answer NAME: compression pointer to the question name at offset 0x0C.
  out[p++] = 0xC0;
  out[p++] = 0x0C;
  // TYPE = A (1)
  out[p++] = 0x00; out[p++] = 0x01;
  // CLASS = IN (1)
  out[p++] = 0x00; out[p++] = 0x01;
  // TTL = 30 seconds
  out[p++] = 0x00; out[p++] = 0x00; out[p++] = 0x00; out[p++] = 0x1E;
  // RDLENGTH = 4
  out[p++] = 0x00; out[p++] = 0x04;
  // RDATA = the 4 IP bytes
  out[p++] = ip[0]; out[p++] = ip[1]; out[p++] = ip[2]; out[p++] = ip[3];

  return p;
}

// Forward a raw query to the upstream resolver and relay the response back to
// the DS. Returns true if a response was relayed.
static bool forwardUpstream(const uint8_t* query, size_t queryLen,
                            const IPAddress& clientIP, uint16_t clientPort) {
  // Send the query untouched to the upstream resolver.
  if (!dnsUpstream.beginPacket(UPSTREAM_DNS, DNS_PORT)) return false;
  dnsUpstream.write(query, queryLen);
  if (!dnsUpstream.endPacket()) return false;

  // Wait up to ~1.5s for a reply.
  uint32_t start = millis();
  int rsize = 0;
  while ((millis() - start) < UPSTREAM_TIMEOUT_MS) {
    rsize = dnsUpstream.parsePacket();
    if (rsize > 0) break;
    delay(2);
  }
  if (rsize <= 0) return false;  // timed out

  static uint8_t resp[DNS_BUF_SIZE];
  int n = dnsUpstream.read(resp, sizeof(resp));
  if (n <= 0) return false;

  // Relay the upstream response back to the DS.
  dnsServer.beginPacket(clientIP, clientPort);
  dnsServer.write(resp, n);
  dnsServer.endPacket();
  return true;
}

// Handle exactly one inbound DNS packet (if any is pending).
static void handleDnsPacket() {
  int pktLen = dnsServer.parsePacket();
  if (pktLen <= 0) return;

  // Capture the client's address/port now -- before any upstream round-trip,
  // which would otherwise clobber the UDP socket's "remote" state.
  IPAddress clientIP   = dnsServer.remoteIP();
  uint16_t  clientPort = dnsServer.remotePort();

  static uint8_t query[DNS_BUF_SIZE];
  if ((size_t)pktLen > sizeof(query)) pktLen = sizeof(query);
  int n = dnsServer.read(query, sizeof(query));
  if (n <= 0) return;

  char     name[256];
  uint16_t qtype, qclass;
  size_t   qEnd;

  // If we can't parse it, just forward it and let the upstream deal with it.
  if (!parseQuestion(query, n, name, sizeof(name), qtype, qclass, qEnd)) {
    Serial.println(F("[dns] unparseable query -> forwarded"));
    forwardUpstream(query, n, clientIP, clientPort);
    return;
  }

  // Redirect only A-record (TYPE=1) / IN-class (CLASS=1) lookups for our domain.
  bool isA      = (qtype == 1 && qclass == 1);
  bool isTarget = nameMatchesSuffix(name, REDIRECT_DOMAIN);

  if (isA && isTarget) {
    static uint8_t reply[DNS_BUF_SIZE];
    size_t replyLen = buildRedirectReply(query, qEnd, WFC_REDIRECT_IP,
                                         reply, sizeof(reply));
    if (replyLen > 0) {
      dnsServer.beginPacket(clientIP, clientPort);
      dnsServer.write(reply, replyLen);
      dnsServer.endPacket();
      Serial.printf("[dns] %s -> REDIRECTED to %s\n",
                    name, WFC_REDIRECT_IP.toString().c_str());
      return;
    }
    // If we somehow couldn't build the reply, fall through to forwarding.
  }

  // Everything else: forward to the real resolver.
  bool ok = forwardUpstream(query, n, clientIP, clientPort);
  Serial.printf("[dns] %s -> forwarded%s\n", name, ok ? "" : " (TIMEOUT)");
}

// ======================== Loop ========================

void loop() {
  handleDnsPacket();
}
