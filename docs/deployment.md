# Deploying dograh to production

Production dograh is not a Vercel deployment. It runs as the `dograh-*` services of the
`christ` compose project on the estate's voice host (`45.77.221.158`, hostname `christ`),
behind `https://voice.innotel.us`:

| Service | Container | Port | Public door |
| --- | --- | --- | --- |
| `dograh-api` | `christ-dograh-api` | `8100` → `8000` | `https://voice.innotel.us/api/…` |
| `dograh-ui` | `christ-dograh-ui` | `3010` → `3010` | `https://voice.innotel.us/` |
| postgres / redis / minio | `christ-dograh-db` / `-redis` / `-minio` | internal | — |

## How a release reaches production

Merging the release-please pull request is the whole deploy:

1. The merge publishes a release (`dograh-v1.52.1`).
2. The same workflow's `images` job builds `api/Dockerfile` and `ui/Dockerfile` for amd64 and
   arm64 and publishes `ghcr.io/innotelinc/dograh-{api,ui}:<version>`, plus `:<short-sha>`
   and `:latest`. No registry secret is involved — GHCR accepts the job token because the
   job declares `packages: write`, and the packages are public, so christ pulls anonymously.
3. `deploy-production` runs in the `production` environment and SSHes to christ with an
   ed25519 key whose `authorized_keys` entry is force-commanded to `/usr/local/sbin/dograh-deploy`.
   That hook is the only thing the key can run, and it only ever touches the two dograh
   services. The key is stored as an environment secret (`CHRIST_DEPLOY_KEY`), not a repo
   secret, so only that job can read it.

The build is chained as a job rather than triggered by `release: published` because releases
are published with `GITHUB_TOKEN`, and events created by that token do not start workflows.
A `release` trigger would never have fired for an automated release — which is exactly why
nothing was built between 1.45.0 and 1.52.1.

## What the hook does

    /usr/local/sbin/dograh-deploy <version>      # force-commanded; SSH_ORIGINAL_COMMAND

* validates the version string and refuses anything else,
* `docker pull`s both tags **first**, so a missing or wrong tag changes nothing,
* backs up `.env` and dumps the database to `/root/dograh-db-<stamp>.sql`,
* rewrites `DOGRAH_API_IMAGE` / `DOGRAH_UI_IMAGE` in `.env`,
* restarts only `dograh-api` and `dograh-ui` (`up -d --no-deps`),
* polls `/api/v1/health` for the new version for 90s; on timeout it restores the `.env`
  backup, restarts, and exits non-zero so the deploy job fails loudly.

`--no-deps` and the named services matter: the same project carries the switch, the gateway,
Asterisk, the fax and the console, and none of those may restart for a dograh release.
`docker ps` should still show 20 containers afterwards.

## Deploying by hand (CI unavailable)

    ssh root@45.77.221.158
    cd /opt/christ/jesus/christ
    cp -a .env .env.bak-$(date -u +%Y%m%dT%H%M%SZ)
    docker exec christ-dograh-db pg_dump -U postgres postgres > /root/dograh-db-$(date -u +%Y%m%dT%H%M%SZ).sql
    sed -i 's|^DOGRAH_API_IMAGE=.*|DOGRAH_API_IMAGE=ghcr.io/innotelinc/dograh-api:<version>|' .env
    sed -i 's|^DOGRAH_UI_IMAGE=.*|DOGRAH_UI_IMAGE=ghcr.io/innotelinc/dograh-ui:<version>|'  .env
    docker compose -p christ --profile agents pull dograh-api dograh-ui
    docker compose -p christ --profile agents up -d --no-deps dograh-api dograh-ui
    curl -s http://127.0.0.1:8100/api/v1/health   # expect the version just pinned

## Rolling back

Restore the `.env` backup and re-run `up -d`; the previous image is still in the local store.
**The database does not roll back with it.** The api migrates on start (1.51.0 → 1.52.1
applied `d6a83e2b19f0 → 8b24d9a76c10` and `8b24d9a76c10 → 93d7a618f2c4`), so an image
rollback runs older code against the newer schema — restore the dump if the reason for
rolling back is datastore-related.

## Versions

Releases come from release-please on `main`. `1.52.0` was upstream `1.51.0` plus the Capstone
patches; `1.52.1` followed a documentation change. Both have published images, and
production pins one explicit version — never `:latest`.

## Why the Vercel workflow is gone

`release-deployment.yml` deployed this repository to Vercel on `release: published`. It could
not succeed: no `VERCEL_TOKEN` / `VERCEL_ORG_ID` / `VERCEL_PROJECT_ID` exist at repository,
environment or organisation level, so its only run (v1.45.0, 2026-10-03) failed at
`vercel pull` after 19 minutes and left the `production` environment holding that failure. It
also fired at most once, because releases are published with the workflow `GITHUB_TOKEN`.
