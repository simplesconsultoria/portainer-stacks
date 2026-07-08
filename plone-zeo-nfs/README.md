# Plone (ZEO + NFS) — Portainer template

Three-service Plone 6 stack deployed to the Simples / Tangrama Swarm cluster
with persistent data on NFS:

| Service    | Replicas      | Public        | Notes                            |
|------------|---------------|---------------|----------------------------------|
| `db`       | 1 (fixed)     | no            | ZEO storage server, NFS-backed   |
| `backend`  | configurable  | via Traefik   | Plone backend, ZEO clients       |
| `frontend` | configurable  | via Traefik   | Volto SSR                        |

ZEO is single-replica by design. Backend and frontend scale horizontally as
ZEO clients.

## Environment variables

Set per-deployment via the Portainer App Templates form. Required = no
sensible default; the deployment will fail or misbehave without it.

### Stack identity & placement

| Variable                  | Required | Default | Description                                                                                              |
|---------------------------|:--------:|---------|----------------------------------------------------------------------------------------------------------|
| `STACK_NAME`              | yes      | —       | Portainer stack name. Used to address services internally (`${STACK_NAME}_db`, `${STACK_NAME}_backend`). |
| `STACK_PREFIX`            | yes      | —       | Short prefix for Traefik resource names (services/middlewares/routers). Keep it unique per stack.        |
| `STACK_ENV`               | yes      | —       | Target environment label. Swarm placement constraint `node.labels.env` (e.g. `staging`, `production`).   |
| `SITE_ID`                 | yes      | —       | Plone site id (path segment). Used by Volto's `RAZZLE_INTERNAL_API_PATH` and the backend VHM rewrites.   |
| `STACK_FRONTEND_REPLICAS` | no       | `1`     | Number of frontend (Volto) replicas.                                                                     |
| `STACK_FRONTEND_TYPE`     | no       | `app`   | Swarm placement constraint `node.labels.type` for the frontend.                                          |
| `STACK_BACKEND_REPLICAS`  | no       | `1`     | Number of backend replicas.                                                                              |
| `STACK_BACKEND_TYPE`      | no       | `app`   | Swarm placement constraint `node.labels.type` for the backend.                                           |
| `STACK_DB_TYPE`           | no       | `data`  | Swarm placement constraint `node.labels.type` for ZEO. Pin to a node with reliable NFS access.           |

### Images

| Variable              | Required | Default            | Description                                                                |
|-----------------------|:--------:|--------------------|----------------------------------------------------------------------------|
| `IMAGE_FRONTEND`      | yes      | —                  | Volto frontend image (e.g. `plone/plone-frontend` or a per-tenant build).  |
| `IMAGE_FRONTEND_TAG`  | no       | `latest`           | Frontend image tag. **Pin in production** — `latest` is forbidden by repo policy. |
| `FRONTEND_COMMAND`    | no       | `pnpm start`       | Command passed to the frontend image's `docker-entrypoint.sh`. Override for non-upstream Volto images (e.g. older Volto using `yarn start:prod`). |
| `IMAGE_BACKEND`       | yes      | —                  | Plone backend image (e.g. `plone/plone-backend`).                          |
| `IMAGE_BACKEND_TAG`   | no       | `latest`           | Backend image tag. **Pin in production**.                                  |
| `BACKEND_COMMAND`     | no       | `start`            | Command passed to the backend image's `/app/docker-entrypoint.sh`. Override only for images whose CMD differs from upstream Plone. |
| `IMAGE_DB`            | no       | `plone/plone-zeo`  | ZEO server image. Override only for a custom-built ZEO.                    |
| `IMAGE_DB_TAG`        | no       | `6.0.0`            | ZEO image tag. Bump together with backend ZODB compatibility.              |

> **Why these `_COMMAND` vars exist.** The `backend` and `frontend`
> services use an `entrypoint:` wrapper to source a Swarm-config `.env`
> file before launching, then `exec` the image's native entrypoint.
> Defining `entrypoint:` resets the image's `CMD`, so the original
> command must be reasserted via `command:` in the compose. The
> `*_COMMAND` vars expose that override to the operator, defaulting to
> upstream Plone / Volto. The `db` (ZEO) service takes no env config and
> keeps its stock entrypoint untouched.

### ZEO

| Variable        | Required | Default | Description                          |
|-----------------|:--------:|---------|--------------------------------------|
| `ZEO_PORT`      | no       | `8100`  | Port the ZEO server listens on.      |
| `ZEO_STORAGE`   | no       | `1`     | ZEO storage name (rarely changed).   |

### Routing & TLS (Traefik)

| Variable                    | Required | Default         | Description                                                                                  |
|-----------------------------|:--------:|-----------------|----------------------------------------------------------------------------------------------|
| `DEPLOY_HOSTNAME`           | yes      | —               | Public hostname routed by Traefik (e.g. `site.example.com`). Used in routers and VHM rewrites. |
| `CERTRESOLVER`              | no       | `le-cloudflare` | Traefik certificate resolver name.                                                           |
| `FRONTEND_MIDDLEWARES`      | no       | `gzip`          | Comma-separated list of Traefik middlewares applied to the frontend route. To gate the public site behind basic auth, set this to `gzip,mw-<STACK_PREFIX>-auth` (substituting your `STACK_PREFIX`). |
| `BASIC_AUTH_USER`           | yes      | —               | Basic-auth user. Used by the stack-wide `mw-${STACK_PREFIX}-auth` middleware (always applied to `/ClassicUI`; opt-in for the frontend via `FRONTEND_MIDDLEWARES`). |
| `BASIC_AUTH_PASSWORD_HASH`  | yes      | —               | Basic-auth password as an htpasswd-style hash. Never the plaintext password.                 |

### NFS storage

| Variable        | Required | Default | Description                                                                  |
|-----------------|:--------:|---------|------------------------------------------------------------------------------|
| `NFS_HOST`      | yes      | —       | NFS server address (IP or DNS name).                                         |
| `NFS_BASE_DIR`  | yes      | —       | Base path on the NFS export for this site. Mounted at `/data` (data) and `/data/blobstorage` (blobs) inside containers. |

### Networking

| Variable        | Required | Default | Description                                                  |
|-----------------|:--------:|---------|--------------------------------------------------------------|
| `NETWORK_MTU`   | no       | `1450`  | MTU for the internal overlay network. Lower it if running across VXLAN-encapsulated networks (e.g. some cloud overlays). |

### Service env overrides (Swarm configs)

The `backend` and `frontend` entrypoints each source a `*.env` file
mounted from a Swarm **config** before launching, so config objects can
inject arbitrary environment variables (Plone tunables, ZEO client
settings, frontend runtime config, etc.) without editing the compose
file. The config objects **must exist in the cluster before
deployment** — Swarm refuses to deploy a stack referencing a missing
external config. Configs are immutable, so rotation means creating a new
object with the next version suffix and bumping the corresponding
`*_ENV_VERSION` var.

| Variable                | Required | Default | Description                                                                                                                                                              |
|-------------------------|:--------:|---------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `BACKEND_ENV_VERSION`   | no       | `v0`    | Version suffix of the backend Swarm config. The compose references `${STACK_PREFIX}_backend_env_${BACKEND_ENV_VERSION}`, mounted at `/run/configs/backend.env`.          |
| `FRONTEND_ENV_VERSION`  | no       | `v0`    | Version suffix of the frontend Swarm config. The compose references `${STACK_PREFIX}_frontend_env_${FRONTEND_ENV_VERSION}`, mounted at `/run/configs/frontend.env`.      |

Create the configs in Portainer (**Configs → Add config**) or via CLI:

```bash
docker config create acme-prod_backend_env_v0 ./backend.env
docker config create acme-prod_frontend_env_v0 ./frontend.env
```

Where each file is plain `KEY=value` lines (shell-sourceable), e.g.:

```bash
# backend.env
ZOPE_THREADS=4
```

If a mounted file ends up empty, the wrapper silently no-ops and the
service starts normally — useful for deploying with a placeholder `v0`
config you fill in later.

> **`RAZZLE_*` frontend vars are build-time, not runtime.** Volto inlines
> every `RAZZLE_*` variable into the browser bundle during `pnpm build`.
> Sourcing them through `frontend.env` only affects **SSR-side** (Node)
> reads at runtime — changing e.g. `RAZZLE_MATOMO_*` via the env config
> will **not** reach the client bundle without rebuilding the frontend
> image. Use the env config for server-side runtime settings; bake
> client-facing `RAZZLE_*` values into the image at build time.

## NFS directory layout

`cluster_playbook` must create the per-instance directory tree on the NFS
share **before** the stack is deployed. The `NFS_BASE_DIR` env var points to
the per-site root, and the compose mounts:

```
${NFS_BASE_DIR}/data/                Data.fs (ZEO storage)
${NFS_BASE_DIR}/data/blobstorage/    blobs (shared between zeo and backend)
```

Both volumes use the docker `local` driver with `nfs` options
(`rw,sync,hard,nfsvers=4`) — durability over throughput.

The matching playbook lives at `cluster_playbook/playbooks/plone-zeo-nfs-site.yml`
and should accept the per-instance `site_id` plus the same `NFS_HOST` /
`NFS_BASE_DIR` resolution the compose uses, and chown the directories to
match the ZEO container's runtime UID/GID.

## Webhook plan

After Portainer instantiates the stack, enable a service webhook on
`backend` and `frontend` (Portainer UI → Service → Webhook → Create). The
CI/CD pipeline that builds new images calls these webhooks to trigger a
re-pull and rolling restart.

The webhook reuses the *current* image reference, so to deploy a new pinned
tag the operator updates `IMAGE_BACKEND_TAG` / `IMAGE_FRONTEND_TAG` in the
stack's env first, then triggers the webhook (or lets CI do it).

Webhook URLs are sensitive — store them in CI secrets, not in this repo.

## Known limitations

- **ZEO does not scale.** Only the backend and frontend do.
- **Plone is slow to start.** Rolling updates use `order: start-first` and a
  5s delay so the old replica stays up while the new one warms. Increase
  `delay` for sites with long startup times.
- **Blobs on NFS** trade I/O performance for operational simplicity.
  `ZEO_SHARED_BLOB_DIR=on` lets the backend access blobs directly via the
  shared mount, avoiding round-trips through ZEO.
- **ZEO storage only.** RelStorage + Postgres is not in scope for this
  template — use the sibling `plone-relstorage` template for that backend.
