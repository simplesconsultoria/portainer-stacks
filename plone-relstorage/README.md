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
2. A role and database for this site. By convention, the role name
   matches the database name — the compose uses `${DB_NAME}` for both
   `dbname` and `user` in the RelStorage DSN.
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
| `DB_NAME`       | yes      | —       | Postgres database **and** role name. The DSN reuses this value for `dbname` and `user`.              |
| `DB_PASSWORD`   | yes      | —       | Postgres password. **Secret** — never set as a default.                                              |

### Routing & TLS (Traefik)

| Variable                    | Required | Default         | Description                                                                                  |
|-----------------------------|:--------:|-----------------|----------------------------------------------------------------------------------------------|
| `DEPLOY_HOSTNAME`           | yes      | —               | Public hostname routed by Traefik. Used in routers and VHM rewrites.                         |
| `CERTRESOLVER`              | no       | `le-cloudflare` | Traefik certificate resolver name.                                                           |
| `FRONTEND_MIDDLEWARES`      | no       | `gzip`          | Comma-separated Traefik middlewares for the frontend route. Add `mw-<STACK_PREFIX>-auth` to gate the public site behind basic auth. |
| `BASIC_AUTH_USER`           | yes      | —               | Basic-auth user for the stack-wide `mw-${STACK_PREFIX}-auth` middleware (always applied to `/ClassicUI`; opt-in for the frontend via `FRONTEND_MIDDLEWARES`). |
| `BASIC_AUTH_PASSWORD_HASH`  | yes      | —               | Basic-auth password as an htpasswd-style hash. Never the plaintext password.                 |

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
