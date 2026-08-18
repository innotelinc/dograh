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
  reach `http://ws.innotel.us:8088`. Open it in the FreePBX firewall for
  `proxy.innotel.us` only.

## Files

| File | Purpose | Destination |
|------|---------|-------------|
| `ari.conf` | ARI user `dograh` (Stasis app name + password) | `/etc/asterisk/ari.conf` |
| `http.conf` | Enable the Asterisk HTTP server on port 8088 | `/etc/asterisk/http.conf` |
| `extensions.conf` | Route inbound calls into `Stasis(dograh)` | merge into `/etc/asterisk/extensions.conf` |
| `websocket_client.conf` | External media stream to `wss://vai.innotel.us/api/v1/telephony/ws/ari` | `/etc/asterisk/websocket_client.conf` |

## Steps

1. Copy the files to your Asterisk box (e.g. `/etc/asterisk/`), merging
   `extensions.conf` into your existing dialplan.
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

## Configure Dograh

1. Log in to Dograh at `https://vai.innotel.us`.
2. Go to **Telephony Configurations** → **Add configuration** → **Asterisk ARI**.
3. Fill in:
   - **ARI Endpoint URL**: `http://ws.innotel.us:8088`
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
