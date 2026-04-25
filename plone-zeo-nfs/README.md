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
| `IMAGE_BACKEND`       | yes      | —                  | Plone backend image (e.g. `plone/plone-backend`).                          |
| `IMAGE_BACKEND_TAG`   | no       | `latest`           | Backend image tag. **Pin in production**.                                  |
| `IMAGE_DB`            | no       | `plone/plone-zeo`  | ZEO server image. Override only for a custom-built ZEO.                    |
| `IMAGE_DB_TAG`        | no       | `6.0.0`            | ZEO image tag. Bump together with backend ZODB compatibility.              |

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
  template; that would be a separate `plone-relstorage` template.
