# Plone (Demo) — Portainer template

Stateless Plone 6 sandbox for demos, evaluation, and short-lived
preview sites. Two services (Volto frontend + Plone backend), no ZEO,
no NFS, no volumes — **all data lives inside the backend container and
is lost on restart.** For long-lived sites use `plone-zeo-nfs`.

## Services

| Service    | Replicas      | Public      | Notes                                              |
|------------|---------------|-------------|----------------------------------------------------|
| `backend`  | configurable  | via Traefik | Plone backend with embedded ZODB. Stateless.       |
| `frontend` | configurable  | via Traefik | Volto SSR.                                         |

> **Caveat on backend replicas:** because each replica owns a private
> filestorage, scaling above 1 means requests may hit different,
> diverging copies of the site. Keep `STACK_BACKEND_REPLICAS=1` unless
> you really know what you're doing.

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
| `STACK_BACKEND_REPLICAS`  | no       | `1`     | Number of backend replicas. **Keep at 1** — see caveat above.                                            |
| `STACK_BACKEND_TYPE`      | no       | `app`   | Swarm placement constraint `node.labels.type` for the backend.                                           |

### Images

| Variable              | Required | Default                          | Description                                                                |
|-----------------------|:--------:|----------------------------------|----------------------------------------------------------------------------|
| `IMAGE_FRONTEND`      | no       | `ghcr.io/plone/demo-frontend`    | Volto frontend image. Override to use a per-tenant build or upstream `plone/plone-frontend`. |
| `IMAGE_FRONTEND_TAG`  | no       | `latest`                         | Frontend image tag.                                                        |
| `IMAGE_BACKEND`       | no       | `ghcr.io/plone/demo-backend`     | Plone backend image. Override to use upstream `plone/plone-backend` or a custom build. |
| `IMAGE_BACKEND_TAG`   | no       | `latest`                         | Backend image tag.                                                         |

### Routing & TLS (Traefik)

| Variable                    | Required | Default         | Description                                                                                  |
|-----------------------------|:--------:|-----------------|----------------------------------------------------------------------------------------------|
| `DEPLOY_HOSTNAME`           | yes      | —               | Public hostname routed by Traefik. Used in routers and VHM rewrites.                         |
| `CERTRESOLVER`              | no       | `le-cloudflare` | Traefik certificate resolver name.                                                           |
| `FRONTEND_MIDDLEWARES`      | no       | `gzip`          | Comma-separated Traefik middlewares for the frontend route. Add `mw-<STACK_PREFIX>-auth` to gate the demo behind basic auth. |
| `BASIC_AUTH_USER`           | yes      | —               | Basic-auth user for the stack-wide `mw-${STACK_PREFIX}-auth` middleware (always applied to `/ClassicUI`; opt-in for the frontend via `FRONTEND_MIDDLEWARES`). |
| `BASIC_AUTH_PASSWORD_HASH`  | yes      | —               | Basic-auth password as an htpasswd-style hash. Never the plaintext password.                 |

## Storage layout

**No external storage.** The backend image's default ZODB storage lives
inside the container at `/data/filestorage` and is lost when the container
is restarted, recreated, or rescheduled to another node. This is
intentional for the demo use-case.

If you need persistent data, use `plone-zeo-nfs`.

There is no matching `cluster_playbook` playbook for this template
because there is nothing to provision on NFS.

## Webhook plan

Same pattern as the other Plone templates: after the stack is deployed,
enable a Portainer service webhook on `backend` and `frontend` and call
them from CI when a new image is built. The webhook reuses the current
image reference, so update `IMAGE_*_TAG` first if you need a different
tag.

Webhook URLs are sensitive — store them in CI secrets, not in this repo.

## Known limitations

- **Stateless / data loss on restart.** Every container restart, swarm
  reschedule, or image update wipes the site. Document this loudly to
  any operator using the template.
- **`STACK_BACKEND_REPLICAS=1`** is the only sensible value — see caveat
  above.
- **No backups.** There's nothing to back up — the demo is the data.
