# Architektura

## Kde co běží

Authentik je v Incus kontejneru `10.10.10.100`. Skripty předpokládají, že už v něm běží Docker a Dockge. `incus launch` v tomto repozitáři není.

Infrastructure-netcup (`10.10.10.10`) má centrální Traefik. Tento stack Traefik neobsahuje a nerestartuje ho.

```text
klient
  -> https://auth.serveftp.org
  -> Traefik v Infrastructure-netcup
  -> http://10.10.10.100:9000
  -> authentik-server (embedded outpost + server)
  -> PostgreSQL na síti authentik-netcup
```

Worker zpracovává úlohy ve stejné databázi. Veřejný port nemá.

## Docker síť

`compose/00-networks.yml` síť jen připojuje (`external: true`). Vytváří ji `init.sh`.

| Projekt | Subnet v jeho `scripts/config.sh` |
| --- | --- |
| Infrastructure-netcup | `10.40.0.0/16` |
| Monitoring-netcup | `10.40.0.0/16` |
| Vaultwarden-netcup | `10.41.0.0/16` |
| Authentik-netcup | `10.42.0.0/16` |

`10.42.0.0/16` se nepřekrývá s Incus LAN `10.10.10.0/24`. Každý Incus kontejner má vlastní Docker daemon, takže cizí bridge není společná L2 síť. Seznam Docker sítí uvnitř běžícího kontejneru `10.10.10.100` z tohoto checkoutu zkontrolován nebyl.

Statické adresy v `.env.example`:

| Služba | Adresa |
| --- | --- |
| PostgreSQL | `10.42.0.10` |
| server | `10.42.0.20` |
| worker | `10.42.0.21` |

## Compose

`compose.yml` je vstup. Služby jsou v `compose/10-postgresql.yml`, `compose/20-authentik-server.yml` a `compose/30-authentik-worker.yml`.

Obrazy jsou připnuté:

- `ghcr.io/goauthentik/server:2026.8.3`
- `docker.io/library/postgres:16-alpine`

Tag `2026.8.3` je hodnota z upstream souboru `lifecycle/container/compose.yml` pro release 2026.8. Redis upstream soubor neobsahuje; authentik 2025.10 Redis odstranil a embedded outpost ukládá session do PostgreSQL.

Server publikuje jen `10.10.10.100:9000`. PostgreSQL hostitelský port nemá. Port `9443` se nepublikuje.

## Uživatelé adresářů

Ověřeno ze zdrojových Dockerfile, ne z běžícího kontejneru:

- authentik `2026.8.3`, `lifecycle/container/Dockerfile`: `adduser --uid 1000` a `USER 1000`
- PostgreSQL 16 Alpine 3.23: `adduser -u 70` / `addgroup -g 70`

`init.sh` podle toho nastaví vlastníka datových adresářů. Worker v upstream Compose běží jako root jen kvůli Docker socketu pro samostatné outposty. Tady socket není, worker zůstává uid 1000.

## Dockge

Dockge v kontejneru už používá `/docker-data/stacks`. Stack `authentik-netcup` se v něm objeví, protože `deploy.sh` a `init.sh` zapisují `compose.yml` do `/docker-data/stacks/authentik-netcup`. `deploy.sh` běžící Dockge jen zkontroluje. `install-dockge.sh` instalaci odmítne.
