# Plone Classic (ZEO + NFS) — Portainer template

Persistent Plone Classic UI site for the legacy buildout-era Plone images
(`plone/plone` 3.1 – 4.3): a ZEO server and one or more ZEO client
backends, **no frontend**. Traefik serves the Plone site at the root of the
hostname through a Virtual Host Monster (VHM) rule. The ZEO data lives on
NFS. For a throwaway or read-only site use
[`classic-demo`](../classic-demo/README.md); for Plone 6 with Volto use
[`plone-zeo-nfs`](../plone-zeo-nfs/README.md).

> [!WARNING]
> Plone 3.1 – 4.3, Zope 2 and Python 2 have known, unpatched security
> issues. Expose these sites only through Traefik, never publish port 8080.

## Services

| Service   | Replicas     | Public      | Notes                                                                 |
|-----------|--------------|-------------|-----------------------------------------------------------------------|
| `db`      | 1            | no          | ZEO server, run from the same legacy image as the backend. NFS-backed. |
| `backend` | configurable | via Traefik | ZEO client (`ZEO_ADDRESS=${STACK_NAME}_db:${ZEO_PORT}`).              |

### Why the ZEO server is a legacy image

`plone/plone-zeo` is ZODB 5, and the ZEO protocol of Zope 2 / ZODB 3 is not
compatible with it. The `db` service therefore runs the ZEO server from
the legacy image itself, and picks how by `INSTANCE_HOME`:

- **3.1 – 4.2** images define it: `db` runs `ZEO.runzeo` through
  `$INSTANCE_HOME/bin/zopepy`, on `/data/filestorage/Data.fs`, with no blobs.
- **4.3** images do not: `db` runs the buildout's own
  `/plone/instance/parts/zeo/bin/runzeo` in the foreground as `plone`, with
  `-a 0.0.0.0:${ZEO_PORT}`. Its configuration keeps blobs in
  `/data/blobstorage` and the ZEO log in `/data/zeoserver/`, on the same
  share. These images bake the `/data` layout into the image instead of
  creating it at start, so `db` creates it as `plone` first.

Either way, use the **same image and tag** for `db` and `backend`. The 4.3
backend needs no blob mount: it is not a shared-blob client, and receives
blobs from ZEO over the network.

The command goes through the image's own entrypoint, which lays out `/data`
first. An image that ships a database (the `-demo` variants, or a site
image built on top of a legacy one) also **seeds
the NFS share with that database** on the first start against an empty
`data/` directory; later starts use what is on the share.

The image's built-in healthcheck probes HTTP on 8080, which a ZEO server
never answers, so `db` overrides it with a TCP check on `${ZEO_PORT}`
(with `$PYTHON` on the older images, the `python` on `PATH` on 4.3).

## Routing

One router, `Host(${DEPLOY_HOSTNAME})`, with the middlewares
`${BACKEND_MIDDLEWARES},mw-${STACK_PREFIX}-backend-vhm`. The VHM middleware
adds the prefix

```
/VirtualHostBase/https/${DEPLOY_HOSTNAME}:443/${SITE_ID}/VirtualHostRoot
```

to every request, so `https://${DEPLOY_HOSTNAME}/<path>` reaches `<path>`
inside the Plone site `${SITE_ID}`. The explicit `:443` pins the port of the
generated links; without it, Zope takes the port from the request's `Host`
header, which Traefik forwards without one.

## Environment variables

Set per-deployment via the Portainer App Templates form. Required = no
sensible default; the deployment will fail or misbehave without it.

### Stack identity & placement

| Variable                 | Required | Default | Description                                                                                                      |
|--------------------------|:--------:|---------|------------------------------------------------------------------------------------------------------------------|
| `STACK_NAME`             | yes      | —       | Portainer stack name — type it again here (Portainer does not inject it). Used for the ZEO address `${STACK_NAME}_db`. |
| `STACK_PREFIX`           | yes      | —       | Short prefix for Traefik resource names and the Swarm config name. Keep it unique per stack.                     |
| `STACK_ENV`              | yes      | —       | Target environment label. Swarm placement constraint `node.labels.env`.                                          |
| `SITE_ID`                | no       | `Plone` | Id of the Plone site inside the Zope root. The VHM rule serves this site at the root of the hostname.            |
| `STACK_BACKEND_REPLICAS` | no       | `1`     | Number of ZEO client replicas.                                                                                   |
| `STACK_BACKEND_TYPE`     | no       | `app`   | Swarm placement constraint `node.labels.type` for the backend.                                                   |
| `STACK_DB_TYPE`          | no       | `data`  | Swarm placement constraint `node.labels.type` for ZEO. Pin to a node with reliable NFS access.                   |

### Images

| Variable             | Required | Default                 | Description                                                                                         |
|----------------------|:--------:|-------------------------|-----------------------------------------------------------------------------------------------------|
| `IMAGE_BACKEND`      | no       | `plone/plone`           | Legacy Plone image (3.1 – 4.3), or an image built on one.                                           |
| `IMAGE_BACKEND_TAG`  | no       | `3.3.6`                 | Image tag. Pin it in production.                                                                    |
| `IMAGE_DB`           | no       | `plone/plone`           | ZEO server image. Same as `IMAGE_BACKEND`.                                                          |
| `IMAGE_DB_TAG`       | no       | `3.3.6`                 | Same as `IMAGE_BACKEND_TAG`.                                                                        |
| `BACKEND_ENTRYPOINT` | no       | `/docker-entrypoint.sh` | Entrypoint the env-config wrapper exec's. Images built on the legacy ones may wrap it with their own. |
| `BACKEND_COMMAND`    | no       | `start`                 | Command passed to `BACKEND_ENTRYPOINT`.                                                             |

A private image (e.g. on `ghcr.io`) needs the registry credentials
configured in Portainer (Registries) before deploying.

### ZEO

| Variable      | Required | Default | Description                          |
|---------------|:--------:|---------|--------------------------------------|
| `ZEO_PORT`    | no       | `8100`  | Port the ZEO server listens on.      |
| `ZEO_STORAGE` | no       | `1`     | ZEO storage name. Rarely changed.    |

### NFS storage

| Variable       | Required | Default | Description                                                                 |
|----------------|:--------:|---------|-----------------------------------------------------------------------------|
| `NFS_HOST`     | yes      | —       | NFS server address (IP or DNS name).                                        |
| `NFS_BASE_DIR` | yes      | —       | Per-site path on the NFS export. Its `data/` subdirectory is mounted at `/data` in `db`. |

### Routing & TLS (Traefik)

| Variable              | Required | Default         | Description                                                                           |
|-----------------------|:--------:|-----------------|---------------------------------------------------------------------------------------|
| `DEPLOY_HOSTNAME`     | yes      | —               | Public hostname routed by Traefik. Used in the router rule and the VHM prefix.        |
| `CERTRESOLVER`        | no       | `le-cloudflare` | Traefik certificate resolver name.                                                    |
| `BACKEND_MIDDLEWARES` | no       | `gzip`          | Comma-separated Traefik middlewares applied before the VHM rewrite (always appended). |

### Backend env config & networking

| Variable              | Required | Default | Description                                                                                                       |
|-----------------------|:--------:|---------|-------------------------------------------------------------------------------------------------------------------|
| `BACKEND_ENV_VERSION` | no       | `v0`    | Version suffix of the Swarm config `${STACK_PREFIX}_backend_env_${BACKEND_ENV_VERSION}`, which must already exist. |
| `NETWORK_MTU`         | no       | `1450`  | MTU for the internal overlay network.                                                                             |

## Backend env config (Swarm config)

As in `plone-zeo-nfs`, the backend sources `/run/configs/backend.env` (a
Swarm config, `KEY=value` lines) before exec'ing the image entrypoint.
Secrets belong there, not in the stack env. Create it before deploying:

```shell
printf 'ADMIN_PASSWORD=…\n' | docker config create classic-acme_backend_env_v0 -
```

An empty config is fine. The legacy images read `ADMIN_USER` /
`ADMIN_PASSWORD` there. **Under ZEO, `ADMIN_PASSWORD` is applied to the
Zope root on every backend start**, which overwrites a password changed
through the ZMI; leave it out once the site is set up.

## NFS directory layout

`cluster_playbook` must create the per-instance directory before the stack
is deployed:

```
${NFS_BASE_DIR}/data/    the whole of the ZEO server's /data:
                         filestorage/Data.fs, log/, ...
                         (4.3: also blobstorage/ and zeoserver/)
```

It must be owned by **uid/gid 500** (the images' `plone` user). The volume
uses the docker `local` driver with `nfs` options
(`rw,sync,hard,nfsvers=4`).

The matching playbook would live at
`cluster_playbook/playbooks/classic-zeo-nfs-site.yml`; it does not exist yet.

## Webhook plan

After Portainer instantiates the stack, enable a service webhook on
`backend` (Portainer UI → Service → Webhook → Create) and call it from CI
when a new image is built. Update `IMAGE_DB_TAG` together with
`IMAGE_BACKEND_TAG`; `db` is updated `stop-first`, so the site is briefly
unavailable while ZEO restarts.

Webhook URLs are sensitive — store them in CI secrets, not in this repo.

## Known limitations

- **ZEO does not scale.** Only the backend does.
- **Buildout era only (3.1 – 4.3).** The tarball-era images (1.0 – 3.0)
  start ZEO differently. Use `classic-demo` for those.
- **Verified with Plone 3.3 and 4.3.** Plone 3.3 has no blobs; with 4.3,
  blobs live in `/data/blobstorage` on the share. Plone 4.0 – 4.2 sites
  with blob content still run ZEO without a blob directory: not worked
  out in this template yet.
- **`linux/amd64` only.** The legacy images exist for no other platform.
