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
* polls `/api/v1/health` for the new version for 90s;
* on timeout, re-reads `alembic_version` and branches:
    * **revision unchanged** — restores the `.env` backup, restarts, exits non-zero so the
      deploy job fails loudly;
    * **revision moved** — refuses the rollback and leaves the new pin in place, because the
      previous images carry an older alembic head and would only replace one non-starting
      stack with another. It prints the dump path and the restore commands instead.

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

The image rolls back; the schema does not, and the difference is sharper than "older code on a
newer schema". Measured 2026-11-12 on a throwaway copy of the production database: upstream
`dograhai/dograh-api:1.51.0` started against the 1.52.2 schema and died three seconds later —

    FAILED: Can't locate revision identified by '93d7a618f2c4'      (exit 255)

— because the entrypoint runs `alembic upgrade head` and 1.51.0 has no such revision. An image
rollback that crosses a migration therefore does not serve old code; it serves nothing at all.
Within one migration set the pin alone is enough (1.52.1 ↔ 1.52.2 added no revision).

Across one, restore the dump as well:

    docker compose -p christ --profile agents stop dograh-api
    docker exec christ-dograh-db psql -U postgres -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'
    docker exec -i christ-dograh-db psql -U postgres -d postgres < /root/dograh-db-<stamp>.sql
    # then restore the .env backup and `up -d`

The hook used to cover only the pin, which was worse than useless after a migration: it put
back an image that could not start. It now compares `alembic_version` before the release and
again when health fails, and refuses the automatic restore when the revision moved, leaving the
new pin in place with the dump path and the restore commands. When the failure follows a
migration, treat it as a database restore, not a version edit.

## Rehearsing a rollback before you need it

`/usr/local/sbin/dograh-rehearse-rollback <tag>` (kept in `innotelinc/jesus`,
`christ/deploy/dograh-rehearse-rollback`) answers the one question a rollback plan depends on:
can that image start on the schema production is on right now? It copies the live database into
a throwaway stack on its own network — `dograh-rehearse-<pid>-{pg,redis,minio,api}` — starts
the candidate against the copy with every endpoint and credential swapped for the scratch one,
waits for `/api/v1/health`, then removes everything. Live containers are never touched.

    ssh root@45.77.221.158
    /usr/local/sbin/dograh-rehearse-rollback 1.52.1     # same migration set: expect 0
    /usr/local/sbin/dograh-rehearse-rollback 1.51.0     # older than the schema: expect 1

Exit codes follow the estate convention: `0` the candidate serves on this schema, so a pin-only
rollback is safe; `1` it cannot start, so the rollback must restore the dump too; `2` the
rehearsal could not run (or was inconclusive) — never reported as a pass.

## Versions

Releases come from release-please on `main`. `1.52.0` was upstream `1.51.0` plus the Capstone
patches; `1.52.1` followed a documentation change; `1.52.2` merged the release-please PR that
the automated pipeline then shipped end to end. All three have published images, and production
pins one explicit version — never `:latest`.

## Why the Vercel workflow is gone

`release-deployment.yml` deployed this repository to Vercel on `release: published`. It could
not succeed: no `VERCEL_TOKEN` / `VERCEL_ORG_ID` / `VERCEL_PROJECT_ID` exist at repository,
environment or organisation level, so its only run (v1.45.0, 2026-10-03) failed at
`vercel pull` after 19 minutes and left the `production` environment holding that failure. It
also fired at most once, because releases are published with the workflow `GITHUB_TOKEN`.
