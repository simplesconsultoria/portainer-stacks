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
templates.json       Portainer App Templates v3 index, served raw to Portainer

<template-id>/
├── docker-compose.yml   Swarm-mode compose, ${VAR} placeholders
├── logo.png             Icon shown in Portainer (≤ 64×64 PNG)
└── README.md            Template doc: what it is, env vars, NFS layout, webhooks
```

## Available templates

| ID              | Description                                            |
|-----------------|--------------------------------------------------------|
| `plone-zeo-nfs` | Plone 6 (ZEO storage, backend, Volto) — NFS-backed    |

## Companion: `cluster_playbook`

Per-instance NFS directories are created by the `cluster_playbook` Ansible
repo **before** a stack is deployed. Each template here has a matching
`playbooks/<id>-site.yml` over there. See `.claude/CLAUDE.local.md` for the
full split of responsibilities.

## Adding a new template

See `.claude/CLAUDE.local.md` for the full checklist. Short version: pick an
`<id>`, create the directory with the three files above, append an entry to
`templates.json`, write the matching folder-prep playbook in
`cluster_playbook`, validate locally, and test on staging before merging.
