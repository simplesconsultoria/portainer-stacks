# portainer-stacks

[Portainer App Templates](https://docs.portainer.io/admin/templates/build) for
the Simples Consultoria / Tangrama Swarm cluster.

Each template is a Swarm-mode `docker-compose.yml` plus metadata that lets a
non-DevOps user spin up a new stack from the Portainer UI by filling in a
form.

This repository is **content only** — nothing here runs on its own. Portainer
fetches `templates.json` and the per-template compose files at deploy time.

## How Portainer consumes this repo

1. Portainer (Settings → App Templates) is configured with the raw URL of
   `templates.json` from this repo:

   ```
   https://raw.githubusercontent.com/simplesconsultoria/portainer-stacks/main/templates.json
   ```

2. Portainer reads `templates.json` and lists each entry under **App Templates**.
3. The user picks a template, fills in env vars in the form, and clicks **Deploy**.
4. Portainer fetches the referenced compose file, substitutes the env vars,
   and creates a Swarm stack.

## Layout

```
Makefile             Validation entrypoints: make all (lint + check-env + validate)
templates.json       Portainer App Templates v3 index, served raw to Portainer

<template-id>/
├── docker-compose.yml   Swarm-mode compose, ${VAR} placeholders
├── logo.png             Icon shown in Portainer (≤ 64×64 PNG)
├── .env.sample          Placeholder env values for `make validate`
└── README.md            Template doc: what it is, env vars, storage layout, webhooks
```

## Available templates

| ID              | Description                                                          |
|-----------------|----------------------------------------------------------------------|
| `plone-zeo-nfs` | Plone 6 (ZEO storage, backend, Volto) — persistent, NFS-backed       |
| `plone-demo`    | Plone 6 (backend + Volto) — stateless sandbox, data lost on restart  |

## Companion: `cluster_playbook`

Templates that need persistent storage (e.g. `plone-zeo-nfs`) rely on the
`cluster_playbook` Ansible repo to pre-create per-instance NFS directories
**before** a stack is deployed. Each NFS-backed template here has a
matching `playbooks/<id>-site.yml` over there. Stateless templates
(e.g. `plone-demo`) need no companion playbook. See `.claude/CLAUDE.local.md`
for the full split of responsibilities.

## Adding a new template

See `.claude/CLAUDE.local.md` for the full checklist. Short version: pick
an `<id>`, create the directory with the four files above, append an entry
to `templates.json`, write the matching folder-prep playbook in
`cluster_playbook` if the template needs NFS, run `make all` locally, and
test on staging before merging.
