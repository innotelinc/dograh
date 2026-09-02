# Asterisk / FreePBX ARI wiring (voice.innotel.us)

This directory contains the Asterisk config files that connect your
FreePBX/Asterisk box at **voice.innotel.us** to Dograh — ARI REST at
**ari.voice.innotel.us**, external media WebSocket at **ws.vai.innotel.us** — using
the **Asterisk ARI** integration.

Dograh talks to Asterisk over two channels. The connection direction is important:
VAI connects to the PBX's internal ARI endpoint, while Asterisk opens the external
media WebSocket outbound to VAI. `ws.vai.innotel.us` must therefore proxy to the VAI
API, never to the PBX.

1. **ARI REST + WebSocket** — Dograh controls calls (answer, hangup, transfer)
   and listens for `StasisStart` events on the ARI WebSocket.
2. **External media WebSocket** — Asterisk streams the call audio to Dograh via
   `chan_websocket` so your voice agent can hear and speak.

## Prerequisites on the Asterisk box

- Asterisk with `res_ari`, `chan_websocket`, and `res_websocket_client` modules
  (Asterisk 20 LTS or 22+ known-working; verify with
  `asterisk -rx "module show like chan_websocket"` and
  `asterisk -rx "module show like res_websocket_client"`).
- Outbound HTTPS (port 443) from the Asterisk box to `ws.vai.innotel.us` (the
  external-media WebSocket hostname, fronted by NPM).
- Port **8088** reachable from the Dograh server (`proxy.innotel.us`) so Dograh can
  reach the ARI service through `https://ari.voice.innotel.us`. NPM forwards that
  hostname to `192.168.1.9:8088`; keep port 8088 off the public router.

> **Same-box install?** If FreePBX/Asterisk and Dograh run on the **same
> server**, run `sudo ./scripts/setup_inplace.sh` from the Dograh repo instead
> of doing the steps below by hand — it backs up and wires `ari.conf`,
> `http.conf`, `websocket_client.conf`, and the `Stasis(dograh)` dialplan
> entry automatically (FreePBX-safe, uses `extensions_custom.conf`), reloads
> Asterisk, and prints the dashboard values + the one-time GUI steps for the
> inbound route.

## Files

| File | Purpose | Destination |
|------|---------|-------------|
| `ari.conf` | ARI user `dograh` (Stasis app name + password) | `/etc/asterisk/ari.conf` |
| `http.conf` | Enable the Asterisk HTTP server on port 8088 | `/etc/asterisk/http.conf` |
| `extensions.conf` | Route inbound calls into `Stasis(dograh)` (vanilla Asterisk only) | merge into `/etc/asterisk/extensions.conf` |
| `websocket_client.conf` | External media stream to `wss://ws.vai.innotel.us/api/v1/telephony/ws/ari` | `/etc/asterisk/websocket_client.conf` |

> **Media-socket auth (already enabled):** the media WebSocket is public
> (``ws.vai.innotel.us``) and authenticated per call — Dograh appends
> ``?workflow_id=…&organization_id=…&workflow_run_id=…&token=…`` to the URL
> dynamically via the ``v()`` transport params whenever it creates the
> external-media channel, so the **static ``websocket_client.conf`` URI needs no
> token and no change**. The token is an HMAC-SHA256 of the id triple signed
> with ``TELEPHONY_WS_TOKEN_SECRET`` (set in the Dograh server's gitignored
> ``.env``); with ``TELEPHONY_WS_TOKEN_ENFORCE=true`` a connection without a
> valid token is rejected with close code ``4401``. If you ever see
> ``UNVERIFIED media socket`` in Dograh's logs, the two sides are out of sync.

## Steps

1. Copy the files to your Asterisk box (e.g. `/etc/asterisk/`), merging
   `extensions.conf` into your existing dialplan. **On FreePBX, skip
   `extensions.conf`** — use the GUI recipe below instead (FreePBX regenerates
   that file on every Apply Config, so manual edits get wiped).
2. In `ari.conf`, change `CHANGE_ME_ARI_PASSWORD` to a strong password.
   **This exact password is the "App Password" you'll enter in Dograh.**
3. Reload Asterisk:

   ```bash
   asterisk -rx "ari reload"
   asterisk -rx "dialplan reload"
   asterisk -rx "module reload res_websocket_client.so"
   asterisk -rx "core reload"     # picks up http.conf
   ```

4. Verify the modules are running:

   ```bash
   asterisk -rx "module show like chan_websocket"
   asterisk -rx "module show like res_websocket_client"
   ```

## FreePBX (GUI) setup — use this instead of editing extensions.conf

FreePBX regenerates `/etc/asterisk/extensions.conf` on every Apply Config, so
manual edits get wiped. Use the native GUI mechanism instead:

1. **Applications → Custom Contexts → Add Custom Context**
   - Context name: `dograh-inbound`
   - Content:

     ```
     exten => 8000,1,NoOp(Dograh voice agent inbound)
      same => n,Stasis(dograh)
      same => n,Hangup()
     ```

   - Add one `exten =>` line per extension registered in Dograh (or use a
     pattern like `_8XXX`). Submit → **Apply Config**.

2. **Admin → Custom Destinations → Add Destination**
   - Description: `Dograh Voice Agent`
   - Destination: `dograh-inbound,8000,1`

   ⚠️ Keep the concrete extension (e.g. `8000`) in the destination — do **not**
   use `s`. Dograh matches inbound calls by the channel's dialplan exten at
   `StasisStart`; if the exten is `s` the call is hung up as "no matching phone
   number". Submit → **Apply Config**.

3. **Route calls into it**
   - External/DID calls: **Connectivity → Inbound Routes → Add** → DID Number
     `8000` → Set Destination → *Custom Destinations → Dograh Voice Agent*.
   - Internal calls (dialing 8000 from a desk phone): **Applications →
     Extensions → Add Extension → Custom** → Extension `8000` → Destination →
     the same custom destination.

## Configure Dograh

1. Log in to Dograh at `https://vai.innotel.us`.
2. Go to **Telephony Configurations** → **Add configuration** → **Asterisk ARI**.
3. Fill in:
   - **ARI Endpoint URL**: `https://ari.voice.innotel.us` (NPM proxy to the PBX's ARI service)
   - **Stasis App Name**: `dograh` (the section name in `ari.conf`)
   - **App Password**: the password you set in `ari.conf`
   - **WebSocket Client Name**: `dograh` (the section name in `websocket_client.conf`)
   - **From Extensions**: optional SIP extensions for outbound, e.g. `PJSIP/6001`
4. Save, then open the configuration and add each extension (e.g. `8000`) as a
   **phone number**. Assign an **Inbound workflow** to each extension.
5. Place a test call to one of the extensions — the assigned voice agent should
   answer.

> Note: Dograh's external media channel uses **G.711 µ-law (`ulaw`)**. Make sure
> any PJSIP endpoint or SIP trunk that places/receives calls through Dograh
> allows `ulaw` (e.g. `allow=ulaw` on the endpoint).

## NAT: externip / localnet (one-way audio fix)

**This deployment**

| Role | Address |
|------|---------|
| FreePBX/Asterisk (`voice.innotel.us`) | `192.168.1.9` |
| Docker host (Dograh + NPM forward targets) | `192.168.1.63` |
| LAN | `192.168.1.0/24` |
| Router forwards (external callers only) | `5060/UDP` (SIP), optional `5061/TCP` (SIP-TLS), `10000-20000/UDP` (RTP) → `192.168.1.9` |
| Public IP | the router's WAN address — store it in the repo's gitignored `.env` as `SERVER_IP` (a real IP is never committed) and substitute it for `<PUBLIC_IP>` below |

**When you need this:** external callers reach the PBX from the internet. Without
NAT configuration, Asterisk advertises its private IP (`192.168.1.9`) in
SIP/SDP, so callers hear nothing (one-way or no audio). If all calls stay on the
LAN, skip this section.

### chan_pjsip (FreePBX default) — `/etc/asterisk/pjsip.conf`

On the **transport** that faces the internet:

```ini
[transport-udp]
type = transport
protocol = udp
bind = 0.0.0.0:5060
local_net = 192.168.1.0/24        ; the only subnet that is NOT NAT'd
; public IP from .env SERVER_IP (or a STUN-derived one):
external_media_address = <PUBLIC_IP>
external_signaling_address = <PUBLIC_IP>
; external_signaling_port = 5060  ; only if the router maps to a different port
```

On each **endpoint** that takes external calls:

```ini
[6001]
type = endpoint
direct_media = no        ; force media through Asterisk so NAT rewriting applies
rewrite_contact = yes
```

Reload: `asterisk -rx "pjsip reload"`, then check the advertised contact with
`asterisk -rx "pjsip show contacts"` — it must show the public IP, not
`192.168.1.9`.

### chan_sip (legacy) — `/etc/asterisk/sip.conf`

```ini
[general]
externip = <PUBLIC_IP>
localnet = 192.168.1.0/255.255.255.0
nat = force_rport,comedia
```

### RTP media — `/etc/asterisk/rtp.conf`

```ini
[general]
rtpstart = 10000
rtpend = 20000
externip = <PUBLIC_IP>     ; only needed if the RTP streams also traverse NAT
; stunaddr = stun.l.google.com:19302   ; STUN alternative to a static IP
```

Keep this range (`10000-20000`) in sync with the router forward.

### FreePBX GUI (preferred over hand-editing)

- **Settings → Asterisk SIP Settings → NAT**: set **External Address** to the
  public IP and **Local Networks** to `192.168.1.0/255.255.255.0` (this writes
  `sip.conf`'s `externip`/`localnet`).
- For PJSIP trunks/extensions: **Connectivity → Trunks / Extensions → the
  NAT/Advanced tab** per endpoint (`direct_media` off, contact rewrite on).
- **Disable SIP ALG on the router** — SIP ALG mangles SIP headers and breaks
  registration/media even with correct externip. Turn it off if the router has
  the option.

### Router

- Forward `5060/UDP` and `10000-20000/UDP` → `192.168.1.9` (add `5061/TCP` only
  if you enable SIP-TLS).
- Disable **SIP ALG**.

### Verify

```bash
asterisk -rx "pjsip show contacts"   # or: asterisk -rx "sip show peers"
asterisk -rx "rtp set debug on"      # during a test call, then "rtp set debug off"
asterisk -rx "core set verbose 4"
```

A successful external call shows the caller's audio reaching the PBX (RTP
received from the public IP) and the `ulaw` codec negotiated (Dograh's external
media channel uses G.711 µ-law).

## Troubleshooting

### CDR: "cdr_odbc.c: unable to retrieve database handle. cdr failed"

FreePBX writes call detail records to MariaDB over ODBC. The classic cause is a
corrupted `cdr_odbc.conf` whose `dsn=` names an ODBC DSN
(`MySQL-asteriskcdrdb`) instead of a res_odbc class (`asteriskcdrdb`). Check
and fix:

```bash
grep -n "dsn" /etc/asterisk/cdr_odbc.conf
# if it says: dsn=MySQL-asteriskcdrdb   <-- wrong, must be a class name
sed -i 's/^dsn *= *MySQL-asteriskcdrdb$/dsn=asteriskcdrdb/' /etc/asterisk/cdr_odbc.conf
asterisk -rx "module reload cdr_odbc.so"
asterisk -rx "cdr show status"
```

Verify a call is actually logged:

```bash
mysql -e "SELECT calldate, src, dst, disposition FROM asteriskcdrdb.cdr ORDER BY calldate DESC LIMIT 3;"
```

`cdr_odbc.conf` is auto-generated by FreePBX — if the corruption recurs after an
Apply Config or module upgrade, repair the module:
`fwconsole ma install cdr && fwconsole reload`.

### Voicemail: "Data source name not found and no default driver specified"

The `asteriskvoicemail` res_odbc class points at the `MySQL-asteriskvoicemail`
ODBC DSN, which is missing from `/etc/odbc.ini`. Add it (mirroring the working
`asteriskcdrdb` entry, using the same password):

```bash
mysql -e "CREATE DATABASE IF NOT EXISTS asteriskvoicemail; GRANT ALL PRIVILEGES ON asteriskvoicemail.* TO 'asterisk'@'localhost'; FLUSH PRIVILEGES;"
cat >> /etc/odbc.ini <<'EOF'

[MySQL-asteriskvoicemail]
Description=MySQL connection to 'asteriskvoicemail' database
driver=MySQL
server=localhost
database=asteriskvoicemail
username=asterisk
password="<same password as MySQL-asteriskcdrdb>"
Port=3306
Socket=/run/mysqld/mysqld.sock
option=3
Charset=utf8
EOF
asterisk -rx "module reload res_odbc.so"
asterisk -rx "odbc show asteriskvoicemail"
```

If `odbc show asteriskvoicemail` still reports a failed attempt, confirm the
`asterisk` user's grants with `mysql -e "SHOW GRANTS FOR 'asterisk'@'localhost';"`.
