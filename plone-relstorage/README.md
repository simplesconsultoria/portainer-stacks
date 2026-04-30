# Plone (RelStorage + Postgres) — Portainer template

Two-service Plone 6 stack (Volto frontend + Plone backend) using
**RelStorage** against an **externally-managed Postgres** database.
The database is **not** part of this stack — provision it separately
(managed RDS, a dedicated Postgres stack, or your DBaaS of choice)
and pass connection details as env vars.

## Services

| Service    | Replicas      | Public      | Notes                                                |
|------------|---------------|-------------|------------------------------------------------------|
| `backend`  | configurable  | via Traefik | Plone backend, RelStorage client. Scales freely.     |
| `frontend` | configurable  | via Traefik | Volto SSR.                                           |

Unlike `plone-demo`, the backend **can** scale: RelStorage supports
concurrent ZODB clients backed by Postgres, so multiple replicas stay
consistent. Unlike `plone-zeo-nfs`, there is no single-replica storage
service constraining write throughput.

## Storage layout

**No volumes are mounted.** All persistent state — including blobs —
lives in the external Postgres database. Blobs are stored in-database
(`shared-blob-dir = false`); this matches the RelStorage maintainer's
recommendation and keeps the stack volume-free, with the database as
the single source of truth (and the single thing that needs backing
up). Blobs are cached per-container in a scratch dir
(`/tmp/blobcache` by default in Plone images).

There is no matching `cluster_playbook` playbook for this template —
nothing to provision on NFS. The companion task is **provisioning the
Postgres database, role, and credentials**, which is out of scope here.

## Database prerequisites

Before deploying, the operator must have:

1. A reachable Postgres instance (managed or self-hosted).
2. A database (`${DB_NAME}`) and a role (`${DB_USERNAME}`) for this
   site. The two are separate vars so you can run against managed
   Postgres setups where the role name differs from the database name;
   when they match, just set both to the same value.
3. Network access from the Swarm `app` nodes to the Postgres host on
   the configured port.
4. The role must have privileges to create the RelStorage schema on
   first boot (or the schema must be pre-created — see RelStorage docs).

## Environment variables

Set per-deployment via the Portainer App Templates form. Required = no
sensible default; the deployment will fail or misbehave without it.

### Stack identity & placement

| Variable                  | Required | Default | Description                                                                                              |
|---------------------------|:--------:|---------|----------------------------------------------------------------------------------------------------------|
| `STACK_NAME`              | yes      | —       | Portainer stack name. Used to address the backend internally (`${STACK_NAME}_backend`).                  |
| `STACK_PREFIX`            | yes      | —       | Short prefix for Traefik resource names (services/middlewares/routers). Keep it unique per stack.        |
| `STACK_ENV`               | yes      | —       | Target environment label. Swarm placement constraint `node.labels.env` (e.g. `staging`, `production`).   |
| `SITE_ID`                 | no       | `Plone` | Plone site path segment. Used by Volto's API path and the backend VHM rewrites.                          |
| `STACK_FRONTEND_REPLICAS` | no       | `1`     | Number of frontend (Volto) replicas.                                                                     |
| `STACK_FRONTEND_TYPE`     | no       | `app`   | Swarm placement constraint `node.labels.type` for the frontend.                                          |
| `STACK_BACKEND_REPLICAS`  | no       | `1`     | Number of backend replicas. Scale freely — RelStorage handles concurrency.                               |
| `STACK_BACKEND_TYPE`      | no       | `app`   | Swarm placement constraint `node.labels.type` for the backend.                                           |

### Images

| Variable              | Required | Default                          | Description                                                                                  |
|-----------------------|:--------:|----------------------------------|----------------------------------------------------------------------------------------------|
| `IMAGE_FRONTEND`      | yes      | —                                | Volto frontend image (e.g. `plone/plone-frontend` or a per-tenant build).                    |
| `IMAGE_FRONTEND_TAG`  | no       | `latest`                         | Frontend image tag. **Pin in production.**                                                   |
| `IMAGE_BACKEND`       | yes      | —                                | Plone backend image. Must include RelStorage + a Postgres driver (psycopg2/psycopg3).        |
| `IMAGE_BACKEND_TAG`   | no       | `latest`                         | Backend image tag. **Pin in production.**                                                    |

### Database (external Postgres)

| Variable        | Required | Default | Description                                                                                          |
|-----------------|:--------:|---------|------------------------------------------------------------------------------------------------------|
| `DB_HOST`       | yes      | —       | Postgres host reachable from the Swarm `app` nodes. May be a DNS name or IP.                         |
| `DB_PORT`       | no       | `5432`  | Postgres port.                                                                                       |
| `DB_NAME`       | yes      | —       | Postgres database name (`dbname` in the RelStorage DSN).                                             |
| `DB_USERNAME`   | yes      | —       | Postgres role used to connect (`user` in the RelStorage DSN). Often equal to `${DB_NAME}` but separable for managed Postgres setups. |
| `DB_PASSWORD`   | yes      | —       | Password for the `${DB_USERNAME}` role. **Secret** — never set as a default.                         |

### Routing & TLS (Traefik)

| Variable                    | Required | Default         | Description                                                                                  |
|-----------------------------|:--------:|-----------------|----------------------------------------------------------------------------------------------|
| `DEPLOY_HOSTNAME`           | yes      | —               | Public hostname routed by Traefik. Used in routers and VHM rewrites.                         |
| `CERTRESOLVER`              | no       | `le-cloudflare` | Traefik certificate resolver name.                                                           |
| `FRONTEND_MIDDLEWARES`      | no       | `gzip`          | Comma-separated Traefik middlewares for the frontend route. Add `mw-<STACK_PREFIX>-auth` to gate the public site behind basic auth. |
| `BASIC_AUTH_USER`           | yes      | —               | Basic-auth user for the stack-wide `mw-${STACK_PREFIX}-auth` middleware (always applied to `/ClassicUI`; opt-in for the frontend via `FRONTEND_MIDDLEWARES`). |
| `BASIC_AUTH_PASSWORD_HASH`  | yes      | —               | Basic-auth password as an htpasswd-style hash. Never the plaintext password.                 |

### Service env overrides (Swarm configs)

Each service's entrypoint sources a `*.env` file mounted from a Swarm
**config** before launching, so config objects can inject arbitrary
environment variables (Plone tunables, RelStorage cache settings,
frontend runtime config, etc.) without editing the compose file. The
config objects **must exist in the cluster before deployment** — Swarm
refuses to deploy a stack referencing a missing external config.
Configs are immutable, so rotation means creating a new object with the
next version suffix and bumping the corresponding `*_ENV_VERSION` var.

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
RELSTORAGE_CACHE_LOCAL_MB=200
ZOPE_THREADS=4
```

If a mounted file ends up empty, the wrapper silently no-ops and the
service starts normally — useful for deploying with a placeholder
`v0` config you fill in later.

## Webhook plan

Same pattern as the other Plone templates: after the stack is deployed,
enable a Portainer service webhook on `backend` and `frontend` and call
them from CI when a new image is built. The webhook reuses the current
image reference, so update `IMAGE_*_TAG` first if you need a different
tag.

Webhook URLs are sensitive — store them in CI secrets, not in this repo.

## Known limitations

- **External Postgres required.** This template will not start a
  database for you. Provision Postgres separately and ensure the role,
  database, and network reachability are in place before deploying.
- **Blobs in Postgres** (`shared-blob-dir = false`). This is the
  RelStorage-recommended layout and keeps backups simple, but every
  blob fetch round-trips to the database (with a per-container cache
  on top). Benchmark before going to production with blob-heavy sites.
- **No backups bundled.** Backups are the Postgres admin's
  responsibility — they cover the entire ZODB (data + blobs) since
  everything lives in the database.
- **First-boot schema creation.** The Plone backend will create the
  RelStorage schema on first connect if the role has DDL privileges. If
  the DBA forbids that, pre-create the schema following the RelStorage
  docs.
