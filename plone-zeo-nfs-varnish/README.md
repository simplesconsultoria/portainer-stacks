# Plone (ZEO + NFS + Varnish) — Portainer template

The [`plone-zeo-nfs`](../plone-zeo-nfs/README.md) stack with a Varnish cache
in front of it, plus a purger that sends Plone's cache invalidations to every
Varnish replica:

| Service    | Replicas      | Public              | Notes                                         |
|------------|---------------|---------------------|-----------------------------------------------|
| `varnish`  | configurable  | via Traefik (https) | Owns the public `/` and `/++api++` routes     |
| `purger`   | 1 (fixed)     | no                  | Fans PURGE out to every Varnish task          |
| `db`       | 1 (fixed)     | no                  | ZEO storage server, NFS-backed                |
| `backend`  | configurable  | `/ClassicUI` only   | Plone backend, ZEO clients, shared blob dir   |
| `frontend` | configurable  | no (internal route) | Volto SSR                                     |

Everything this README does not mention behaves as in `plone-zeo-nfs`:
the Swarm env configs, NFS layout, ZEO, `ZEO_SHARED_BLOB_DIR=on`, and the
launch wrappers.

## Request flow

```
client ──https──▶ Traefik ──▶ varnish ──(miss)──▶ Traefik `http` entrypoint
                                                  │  Host + X-Varnish-Routed: 1
                                                  ├─▶ frontend        (/)
                                                  └─▶ backend VHM     (/++api++)
client ──https──▶ Traefik ──▶ backend (/ClassicUI, basic auth, not cached)
```

- **Public routers (https)** belong to `varnish`: `Host(...)` for `/`, and
  `Host(...) && PathPrefix(/++api++)` for the API, with `gzip` plus a
  per-client rate limit (keyed on `x-real-ip`).
- **Internal routers (`http` entrypoint, no TLS)** belong to `frontend` and
  `backend`. They match only requests carrying `X-Varnish-Routed: 1`, so
  Varnish's cache misses come back through Traefik and land on the app.
- **`/ClassicUI`** stays a direct https route to the backend, behind the
  stack's basic-auth middleware, as in `plone-zeo-nfs`.

### Varnish image contract

The template ships no VCL. `IMAGE_VARNISH` must be built `FROM varnish`
(the official image) with a VCL that:

1. uses a single backend `.host = "traefik"; .port = "80";` (Traefik on the
   `public` network);
2. sets `req.http.X-Varnish-Routed = "1"` on every request it forwards;
3. allows PURGE/BAN from the overlay ranges (`10.0.0.0/8` covers Swarm's
   default address pool), since the purger reaches Varnish over the stack's
   internal network.

Do not name other services by bare name in the VCL (`backend`, `varnish`):
on the shared `public` network those names can resolve to another stack.

## Cache purging

```
Plone (plone.cachepurging) ──PURGE──▶ ${STACK_NAME}_purger ──PURGE──▶ every task of ${STACK_NAME}_varnish
```

- The purger runs `kitconcept/cluster-purger` in Swarm mode. It resolves
  `tasks.${STACK_NAME}_varnish` and repeats each PURGE against every Varnish
  task, with `Host: ${DEPLOY_HOSTNAME}`. The stack-scoped name keeps another
  stack's Varnish out of the list.
- The purger sits on the stack's internal network only. Point Plone's
  caching proxy setting (`plone.cachepurging` → *Caching proxies*) at
  `http://${STACK_NAME}_purger`. That setting lives in the site's registry,
  not in this template.
- **The public routers refuse PURGE and BAN** (`!Method(PURGE, BAN)` in their
  rules). Traefik reaches Varnish from an overlay address, which the purge
  ACL trusts, so an external PURGE must stop at Traefik. It gets a 404.

## Environment variables

Only the variables this template adds or changes are listed here. All the
others (identity, placement, images, ZEO, NFS, TLS, basic auth, MTU, Swarm
env configs) are exactly those of
[`plone-zeo-nfs`](../plone-zeo-nfs/README.md#environment-variables).

| Variable                 | Required | Default                              | Description |
|--------------------------|:--------:|--------------------------------------|-------------|
| `IMAGE_VARNISH`          | yes      | —                                    | Varnish image carrying the site's VCL (see the contract above). |
| `IMAGE_VARNISH_TAG`      | no       | `latest`                             | Varnish image tag. **Pin in production.** |
| `VARNISH_COMMAND`        | no       | `-p nuke_limit=2000 -p workspace_client=192k -p workspace_backend=192k` | Extra `varnishd` arguments. The official image's entrypoint prepends `varnishd -F ...` when they start with `-`. |
| `VARNISH_SIZE`           | no       | `100M`                               | Malloc cache size, per Varnish replica. |
| `STACK_VARNISH_REPLICAS` | no       | `1`                                  | Varnish replicas. Each keeps its own cache; the purger purges all of them. |
| `STACK_VARNISH_TYPE`     | no       | `app`                                | `node.labels.type` constraint for Varnish and the purger. |
| `IMAGE_PURGER`           | no       | `ghcr.io/kitconcept/cluster-purger`  | Purger image. |
| `IMAGE_PURGER_TAG`       | no       | `latest`                             | Purger image tag. **Pin in production.** |
| `API_RATELIMIT_AVERAGE`  | no       | `20`                                 | Average requests per second per client IP on the public `/++api++` route. |
| `API_RATELIMIT_BURST`    | no       | `50`                                 | Burst size per client IP on the public `/++api++` route. |
| `FRONTEND_MIDDLEWARES`   | no       | `gzip`                               | *Changed:* applies to the public `/` route, which Varnish serves. Add `mw-<STACK_PREFIX>-auth` to gate the site behind basic auth. |

The purger's site list is `['${DEPLOY_HOSTNAME}']`, derived from the one
hostname the stack routes; there is no separate variable.

## NFS directory layout

Same as `plone-zeo-nfs`:

```
${NFS_BASE_DIR}/data/                Data.fs (ZEO storage)
${NFS_BASE_DIR}/data/blobstorage/    blobs (shared between zeo and backend)
```

Varnish and the purger are stateless.

## Webhook plan

Enable service webhooks on `backend`, `frontend` and `varnish`. As in
`plone-zeo-nfs`, a webhook redeploys the *current* image reference: bump
`IMAGE_*_TAG` in the stack env first.

## Known limitations

- **The internal routes are reachable from outside.** Traefik's `http`
  entrypoint is public, so a client that sends `X-Varnish-Routed: 1` over
  plain http to the hostname bypasses Varnish and the API rate limit.
  Without the header, the cluster-wide redirect sends it to https.
- **Each Varnish replica has its own cache.** More replicas mean a lower
  hit rate per replica; the purger keeps them consistent.
- **One hostname per stack.** Routers, VHM rewrites and the purger's site
  list all use `DEPLOY_HOSTNAME`.
- **Traefik v2 rule syntax** (`Headers(...)`, `Method(...)`). A move to
  Traefik v3 must rewrite the rules (`Header(...)`).
- Everything listed under *Known limitations* in `plone-zeo-nfs`.
