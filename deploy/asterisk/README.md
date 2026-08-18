# Asterisk / FreePBX ARI wiring (voice.innotel.us)

This directory contains the Asterisk config files that connect your
FreePBX/Asterisk box at **voice.innotel.us** to Dograh at **vai.innotel.us**
using the **Asterisk ARI** integration.

Dograh talks to Asterisk over two channels:

1. **ARI REST + WebSocket** — Dograh controls calls (answer, hangup, transfer)
   and listens for `StasisStart` events on the ARI WebSocket.
2. **External media WebSocket** — Asterisk streams the call audio to Dograh via
   `chan_websocket` so your voice agent can hear and speak.

## Prerequisites on the Asterisk box

- Asterisk with `res_ari`, `chan_websocket`, and `res_websocket_client` modules
  (Asterisk 20 LTS or 22+ known-working; verify with
  `asterisk -rx "module show like chan_websocket"` and
  `asterisk -rx "module show like res_websocket_client"`).
- Outbound HTTPS (port 443) from the Asterisk box to `vai.innotel.us`.
- Port **8088** reachable from the Dograh server (`proxy.innotel.us`) so Dograh can
  reach `http://192.168.1.9:8088` (the PBX's internal LAN address). Open it in the FreePBX firewall for
  `proxy.innotel.us` only.

## Files

| File | Purpose | Destination |
|------|---------|-------------|
| `ari.conf` | ARI user `dograh` (Stasis app name + password) | `/etc/asterisk/ari.conf` |
| `http.conf` | Enable the Asterisk HTTP server on port 8088 | `/etc/asterisk/http.conf` |
| `extensions.conf` | Route inbound calls into `Stasis(dograh)` (vanilla Asterisk only) | merge into `/etc/asterisk/extensions.conf` |
| `websocket_client.conf` | External media stream to `wss://vai.innotel.us/api/v1/telephony/ws/ari` | `/etc/asterisk/websocket_client.conf` |

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
   - **ARI Endpoint URL**: `http://192.168.1.9:8088` (internal LAN address — the PBX is not exposed publicly)
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
