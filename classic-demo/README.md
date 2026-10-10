# Plone Classic (Demo) — Portainer template

Stateless Plone Classic UI site for the legacy Plone images
(`plone/plone` 1.0 – 4.2): a single backend, **no frontend**, no ZEO, no
NFS. Traefik serves the Plone site at the root of the hostname through a
Virtual Host Monster (VHM) rule. **All data lives inside the backend
container and is lost on restart.** For a persistent site use
[`classic-zeo-nfs`](../classic-zeo-nfs/README.md); for Plone 6 with Volto
use [`plone-demo`](../plone-demo/README.md).

Being stateless suits two cases: demos and evaluation (the `-demo` images
ship a site already created at `/Plone`), and **read-only archive sites**
whose image carries the site's own database — every new task starts again
from the database in the image.

> [!WARNING]
> Plone 1.0 – 4.2, Zope 2 and Python 2 have known, unpatched security
> issues. Expose these sites only through Traefik, never publish port 8080.

## Services

| Service   | Replicas      | Public      | Notes                                         |
|-----------|---------------|-------------|-----------------------------------------------|
| `backend` | configurable  | via Traefik | Legacy Plone with embedded ZODB. Stateless.   |

> **Caveat on backend replicas:** each replica owns a private
> filestorage, so scaling above 1 means requests may hit different,
> diverging copies of the site. Keep `STACK_BACKEND_REPLICAS=1`.

## Routing

One router, `Host(${DEPLOY_HOSTNAME})`, with the middlewares
`${BACKEND_MIDDLEWARES},mw-${STACK_PREFIX}-backend-vhm`. The VHM middleware
adds the prefix

```
/VirtualHostBase/https/${DEPLOY_HOSTNAME}:443/${SITE_ID}/VirtualHostRoot
```

to every request, so `https://${DEPLOY_HOSTNAME}/<path>` reaches
`<path>` inside the Plone site `${SITE_ID}` and the site writes its links
with the public hostname.

The explicit `:443` pins the port of the links the site writes. Without
it, Zope takes the port from the request's `Host` header. Traefik forwards
the header without a port, so the links come out right either way, but a
request that does carry one (e.g. straight to the backend on 8080) would
put that port in every link.

The Zope root (and its ZMI) is not routed. The site's own ZMI is at
`https://${DEPLOY_HOSTNAME}/manage`.

## Environment variables

Set per-deployment via the Portainer App Templates form. Required = no
sensible default; the deployment will fail or misbehave without it.

`STACK_NAME` is not used: there is a single service, so nothing addresses
it by Swarm DNS.

### Stack identity & placement

| Variable                 | Required | Default | Description                                                                                            |
|--------------------------|:--------:|---------|--------------------------------------------------------------------------------------------------------|
| `STACK_PREFIX`           | yes      | —       | Short prefix for Traefik resource names (services/middlewares/routers). Keep it unique per stack.      |
| `STACK_ENV`              | yes      | —       | Target environment label. Swarm placement constraint `node.labels.env` (e.g. `staging`, `production`). |
| `SITE_ID`                | no       | `Plone` | Id of the Plone site inside the Zope root. The VHM rule serves this site at the root of the hostname.  |
| `STACK_BACKEND_REPLICAS` | no       | `1`     | Number of backend replicas. **Keep at 1** — see caveat above.                                          |
| `STACK_BACKEND_TYPE`     | no       | `app`   | Swarm placement constraint `node.labels.type` for the backend.                                         |

### Image

| Variable            | Required | Default       | Description                                                                                         |
|---------------------|:--------:|---------------|-----------------------------------------------------------------------------------------------------|
| `IMAGE_BACKEND`     | no       | `plone/plone` | Legacy Plone image, or an image built on one.                                                       |
| `IMAGE_BACKEND_TAG` | no       | `3.3-demo`    | Image tag. Pin it in production. `-demo` tags ship a site at `/Plone`; plain tags start empty.      |

A private image (e.g. on `ghcr.io`) needs the registry credentials
configured in Portainer (Registries) before deploying.

### Routing & TLS (Traefik)

| Variable              | Required | Default         | Description                                                                         |
|-----------------------|:--------:|-----------------|-------------------------------------------------------------------------------------|
| `DEPLOY_HOSTNAME`     | yes      | —               | Public hostname routed by Traefik. Used in the router rule and the VHM prefix.      |
| `CERTRESOLVER`        | no       | `le-cloudflare` | Traefik certificate resolver name.                                                  |
| `BACKEND_MIDDLEWARES` | no       | `gzip`          | Comma-separated Traefik middlewares applied before the VHM rewrite (always appended). |

### Zope admin

| Variable         | Required | Default | Description                                                                                                                                         |
|------------------|:--------:|---------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
| `ADMIN_PASSWORD` | no       | —       | Sets the Zope root `admin` password when the container creates (plain images) or seeds (`-demo` and site images) its database. Empty keeps the credentials of a shipped database. |

## Storage layout

**No external storage.** The image's ZODB lives inside the container at
`/data/filestorage`, and a new task starts from what the image ships. That
includes every restart, reschedule, and image update.

The legacy images declare `/data` as a volume, so Docker creates an
anonymous volume for each task. Check the nodes for leftovers with
`docker volume ls -f dangling=true` if tasks are recreated often.

There is no matching `cluster_playbook` playbook for this template because
there is nothing to provision on NFS.

## Webhook plan

Same pattern as the other Plone templates: after the stack is deployed,
enable a Portainer service webhook on `backend` and call it from CI when a
new image is built. The webhook reuses the current image reference, so
update `IMAGE_BACKEND_TAG` first if you need a different tag.

Webhook URLs are sensitive — store them in CI secrets, not in this repo.

## Known limitations

- **Stateless / data loss on restart.** Every task restart, swarm
  reschedule, or image update starts again from the image. Edits made
  through the web are lost.
- **`STACK_BACKEND_REPLICAS=1`** is the only sensible value — see caveat
  above.
- **First start copies the database.** For images that ship a large
  database, the first start of every task copies it into `/data` before
  Zope starts (a few seconds for ~400 MB).
- **`linux/amd64` only.** The legacy images exist for no other platform.
- **No backups.** There's nothing to back up — the image is the data.
