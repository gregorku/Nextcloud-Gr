# Authentik configuration

This directory is synchronised into the runtime stack. It documents where Authentik stores files. It does not contain passwords or the secret key.

## What is not in Git

| Path in the container | Host path | Contents |
| --- | --- | --- |
| `/data` | `/docker-data/authentik-netcup/authentik/data` | File storage (`AUTHENTIK_STORAGE__FILE__PATH`) |
| `/templates` | `/docker-data/authentik-netcup/authentik/templates` | Custom templates |
| `/certs` | `/docker-data/authentik-netcup/authentik/certs` | Worker certificate files |
| `/var/lib/postgresql/data` | `/docker-data/authentik-netcup/postgresql` | PostgreSQL data directory |

`init.sh` creates those directories and sets the owners recorded in `scripts/config.sh`.

## Blueprints

The server image already contains the packaged blueprints at `/blueprints`. This stack does not mount over that path, because an empty mount would hide them.

A custom blueprint that should travel with Git can be added under `configs/authentik/blueprints/` and then mounted read-only at its own path. Do not mount it onto `/blueprints` unless the packaged blueprints are intentionally replaced.

## Embedded outpost

The embedded outpost is part of the server process and listens on container port 9000. There is no separate proxy-outpost service and the worker does not receive `/var/run/docker.sock`.

## Runtime settings

Versions, the database password, `AUTHENTIK_SECRET_KEY`, SMTP and the trusted proxy CIDR are runtime `.env` values. See `.env.example`. Placeholders that start with `set_` are rejected by `scripts/check-env.sh`.
