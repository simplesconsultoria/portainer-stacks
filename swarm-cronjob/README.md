# swarm-cronjob — Portainer template

Single-replica deployment of [`crazymax/swarm-cronjob`][upstream] — a small
controller that schedules cron-like jobs on a Docker Swarm cluster by
triggering rolling updates on services that opt in via labels.

It does **not** run shell scripts or arbitrary commands itself. Each
"cronjob" is a pre-existing Swarm service whose container's `CMD` does the
work; `swarm-cronjob` watches the cluster, and on the configured cadence
forces that service to redeploy (which re-runs the `CMD`). Typical pattern:
the target service is a `replicas: 0` job-runner that scales to 1 on each
trigger, runs to completion, and stops.

[upstream]: https://github.com/crazy-max/swarm-cronjob

## Services

| Service   | Replicas | Public | Notes                                                                                |
|-----------|----------|--------|--------------------------------------------------------------------------------------|
| `cronjob` | `1`      | no     | Pinned to a manager node (needs `/var/run/docker.sock` to enumerate/trigger services). |

> **One per Swarm cluster.** Two parallel replicas would double-fire every
> job. The compose hard-codes `replicas: 1` — do not override.

## How target services opt in

`swarm-cronjob` reads labels on **other** services in the same Swarm. The
labels live on the *target* service (e.g. a backup runner), not on this
stack:

```yaml
deploy:
  labels:
    - swarm.cronjob.enable=true
    - swarm.cronjob.schedule=0 4 * * *      # cron expression in TZ below
    - swarm.cronjob.skip-running=true        # don't re-fire if previous run is still active
```

See the [upstream README][upstream] for the full label reference
(`swarm.cronjob.replicas`, etc.).

## Environment variables

Set per-deployment via the Portainer App Templates form. Required = no
sensible default; the deployment will fail or misbehave without it.

### Placement

The service is hard-pinned to `node.role == manager` so it can read the
Docker socket. There is no env-driven placement: a Swarm has one manager
quorum, and one cronjob controller serves it.

### Image

| Variable             | Required | Default                   | Description                                                          |
|----------------------|:--------:|---------------------------|----------------------------------------------------------------------|
| `IMAGE_CRONJOB`      | no       | `crazymax/swarm-cronjob`  | Image. Override only for a private mirror.                           |
| `IMAGE_CRONJOB_TAG`  | no       | `latest`                  | Image tag. **Pin in production** — `latest` ships breaking changes.  |

### Runtime config

| Variable     | Required | Default | Description                                                                                     |
|--------------|:--------:|---------|-------------------------------------------------------------------------------------------------|
| `TZ`         | no       | `UTC`   | IANA timezone used to evaluate every `swarm.cronjob.schedule` expression (e.g. `America/Sao_Paulo`). |
| `LOG_LEVEL`  | no       | `info`  | Logger verbosity (`debug`, `info`, `warn`, `error`).                                            |
| `LOG_JSON`   | no       | `false` | Emit JSON-formatted logs (`true`/`false`). Useful when shipping to a log aggregator.            |

## Storage layout

**No persistent storage.** State is in-memory and reconstructed at startup
from the labels on existing services. Restarting the controller is safe;
no backup needed. There is no matching `cluster_playbook` playbook for
this template.

## Webhook plan

Same pattern as the other templates: enable a Portainer service webhook on
`cronjob` after deploy and call it from CI when a new image is built. To
deploy a new pinned tag, update `IMAGE_CRONJOB_TAG` in the stack first,
then trigger the webhook.

Webhook URLs are sensitive — store them in CI secrets, not in this repo.

## Known limitations

- **Single replica only.** Multiple controllers in the same Swarm would
  each schedule and double-fire every job.
- **Manager-only.** The Docker socket must belong to a Swarm manager so
  the controller can issue service updates. Mounted read-only, but socket
  access is effectively root on that node — only deploy on trusted
  managers.
- **One controller per Swarm.** Schedules and target labels are global to
  the cluster. If you need staging/production isolation, run two separate
  Swarms — not two controllers in the same one.
- **No public surface.** No Traefik routes, no exposed port. Operators
  monitor it via `docker service logs`.
