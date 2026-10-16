# Maintaining this fork

`innotelinc/dograh` is a private fork of [dograh-hq/dograh](https://github.com/dograh-hq/dograh).
This file covers how to take upstream updates without losing our changes.

## Remotes

| Remote | Points at | Used for |
|---|---|---|
| `origin` | `innotelinc/dograh` | pushing our work, and the images CI publishes |
| `upstream` | `dograh-hq/dograh` | fetching the author's releases |

```bash
git remote add upstream https://github.com/dograh-hq/dograh.git
git fetch upstream --tags
```

The fork carries a `fork-before-sync` tag on the last commit before any rebase
onto upstream, so a bad sync is recoverable with `git reset --hard fork-before-sync`.

## Where our changes live

Our customizations are **ordinary commits on `main`**, not patches. They sit
after the upstream commits they modify, so `git log --oneline main` reads as
"upstream, then our delta".

They used to live the other way round: as loose `.patch` files in
`capstone/dograh/patches/`, applied by `capstone/scripts/apply-dograh-patches.sh`
to a gitignored `capstone/dograh/upstream` clone. That had two failure modes —
a fresh clone silently lost the patches unless setup ran, and an upstream change
to a patched file made the patch fail to apply with no partial success. As
commits, a conflicting sync surfaces at merge time on the one file that moved,
and the conflict is in the file rather than in a patch application log.

### The customizations

| Area | What | Files |
|---|---|---|
| OIDC session + operator-visible workflows | sign-in, session handling, workflow list visibility | `api/services/auth/oidc_auth.py`, `api/routes/auth.py`, `api/db/user_client.py`, `ui/src/app/auth/login/*`, `ui/src/app/page.tsx`, `ui/src/app/workflow/page.tsx` |
| Group-based admission | admit an identity by Authentik group (`AUTHENTIK_ALLOWED_GROUPS`) | `api/services/auth/oidc_auth.py`, `api/tests/test_oidc_auth.py` |
| Adopt an existing email instead of failing sign-in | a known identity that arrives with a new OIDC subject keeps its row | `api/routes/auth.py`, `api/db/user_client.py` |
| Zeus interview return | return a finished interview to the Zeus voice plane (`ZEUS_RETURN_ENABLED`) | `api/services/telephony/ari_manager.py`, `api/services/telephony/providers/ari/strategies.py` |
| OIDC state cookie scoping | bind the state cookie to the app domain | `ui/src/components/SignInClient.tsx`, `ui/src/lib/auth/server.ts` |
| Memory-capped UI build | cap webpack cache, static-generation workers, and the type-check so `next build` fits a 4 GiB cgroup | `ui/next.config.ts`, `ui/Dockerfile` |

### Retired: the Asterisk plaintext control-frame patch

We used to patch `pipecat/src/pipecat/serializers/asterisk.py` so the serializer
understood Asterisk's plaintext `MEDIA_START` / `MEDIA_XOFF` frames instead of
warning "Failed to parse JSON message" on every call.

**Upstream implemented this itself** in Pipecat 1.12.0 as a module-level
`_parse_control_message()` (`asterisk.py:45`), which parses both the JSON and
plaintext forms and normalises them to one shape. It is stricter than ours — it
validates the event name against `^[A-Z][A-Z0-9_]*$` rather than only checking
that it is upper-case — and it adds `MEDIA_START` logging that records the
negotiated format and frame size.

The patch is therefore redundant and was dropped rather than re-applied. Do not
re-add it; if a future Pipecat bump removes `_parse_control_message`, re-derive
the change from upstream's implementation rather than resurrecting the old diff.

## Syncing from upstream

```bash
git fetch upstream --tags
git log --oneline upstream/main..main     # what we carry
git log --oneline main..upstream/main     # what upstream gained

# rebase our commits onto the new upstream, then resolve per-file
git rebase upstream/main
```

Expect conflicts only in the files listed above. Resolve each against upstream's
current code — our commits are usually a small behavioural delta on top of a
method upstream has since rewritten — then:

```bash
npm --prefix ui run lint && npm --prefix ui run build   # if the UI moved
cd api && pytest                                          # if the api moved
```

`api/tests/test_oidc_auth.py` is ours, so it is the first thing that catches an
OIDC refactor upstream.

### Version numbers

`release-please` owns `.release-please-manifest.json`, `api/pyproject.toml`, and
`ui/package.json`, and it computes the next version from *this* repo's history.
After a rebase it has been known to stamp a version **lower** than the upstream
release the tree now contains — the content becomes 1.48.0 while the manifest
still says 1.47.0.

Check all three agree, and that they agree with upstream, after every sync:

```bash
cat .release-please-manifest.json && grep '^version' api/pyproject.toml
git show upstream/main:.release-please-manifest.json
```

The runtime reports its version through `GET /api/v1/health` (`"version"`), and
the Zeus portal surfaces it in `/api/health` as `dograh_engine`. If those disagree
with the manifest, trust the manifest only after fixing it.

## Building images

CI publishes `ghcr.io/innotelinc/dograh-api` and `dograh-ui` from tags. The API
image is pip-based and builds anywhere; the **UI image OOM-kills `next build` on
memory-capped hosts** (webpack holds every module in memory for a production
build), which is what the `ui/next.config.ts` caps exist for. Build the UI where
there is room and ship it:

```bash
docker save dograh-local/dograh-ui:capstone | gzip -1 | ssh root@<host> 'gunzip | docker load'
```

Capstone drives this end to end — see `capstone/docker-compose.dograh-build.yml`.