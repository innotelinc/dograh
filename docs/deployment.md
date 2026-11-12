# Deploying dograh to production

Production dograh is not a Vercel deployment. It runs as the `dograh-*` services of the
`christ` compose project on the estate's voice host (`45.77.221.158`, hostname `christ`),
behind `https://voice.innotel.us`:

| Service | Container | Port | Public door |
| --- | --- | --- | --- |
| `dograh-api` | `christ-dograh-api` | `8100` → `8000` | `https://voice.innotel.us/api/…` |
| `dograh-ui` | `christ-dograh-ui` | `3010` → `3010` | `https://voice.innotel.us/` |
| postgres / redis / minio | `christ-dograh-db` / `-redis` / `-minio` | internal | — |

The compose file reads the release from `.env`, so a deploy is an image pin and not a file
edit:

    DOGRAH_API_IMAGE=dograhai/dograh-api:<tag>
    DOGRAH_UI_IMAGE=dograhai/dograh-ui:<tag>

Both keys were absent until 2026-11-11, so the stack ran whatever `:latest` resolved to when
it was last started — 1.49.0, built 2026-10-12. They are pinned now, which is what makes a
deployment reproducible and reviewable rather than "whatever the tag pointed at that day".

## Rolling one out

    ssh root@45.77.221.158
    cd /opt/christ/jesus/christ
    cp -a .env .env.bak-$(date -u +%Y%m%dT%H%M%SZ)
    docker exec christ-dograh-db pg_dump -U postgres postgres > /root/dograh-db-$(date -u +%Y%m%dT%H%M%SZ).sql
    sed -i 's/^DOGRAH_API_IMAGE=.*/DOGRAH_API_IMAGE=dograhai\/dograh-api:<tag>/' .env
    sed -i 's/^DOGRAH_UI_IMAGE=.*/DOGRAH_UI_IMAGE=dograhai\/dograh-ui:<tag>/'  .env
    docker compose -p christ --profile agents pull dograh-api dograh-ui
    docker compose -p christ --profile agents up -d --no-deps dograh-api dograh-ui
    curl -s http://127.0.0.1:8100/api/v1/health   # expect the version just pinned

`--no-deps` and the named services matter: the same project carries the switch, the gateway,
Asterisk, the fax and the console, and none of those should restart for a dograh release.
Confirm afterwards that their `Up` times did not change.

To roll back, restore the `.env` backup and re-run `up -d`; the previous image is still in
the local store. The dump above is the schema's safety net — the api migrates on start.

## Versions

Upstream publishes `dograhai/dograh-{api,ui}` tags up to `1.51.0`; no `1.52.0` image exists.
`1.52.0` is this fork's release number for upstream `1.51.0` plus the Capstone patches, so
deploying the patches themselves needs an image built from tag `dograh-v1.52.0` and pushed to
a registry christ can pull from. Until then a production deploy tracks the upstream line.

## Why the Vercel workflow is gone

`release-deployment.yml` deployed this repository to Vercel on `release: published`. It could
not succeed: no `VERCEL_TOKEN` / `VERCEL_ORG_ID` / `VERCEL_PROJECT_ID` exist at repository,
environment or organisation level, so its only run (v1.45.0, 2026-10-03) failed at
`vercel pull` after 19 minutes and left the `production` environment holding a failure. It
also fired at most once, because releases are published with the workflow `GITHUB_TOKEN` and
events created by that token do not start other workflows.
