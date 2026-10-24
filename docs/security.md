# Bezpečnost

## Co tento stack neotvírá

- PostgreSQL 5432, Redis 6379 a PHP-FPM 9000 nemají `ports` v Compose.
- Nginx nenaslouchá na `0.0.0.0`. Adresa je v `.env` a `check-env.sh` odmítne `0.0.0.0`, loopback i placeholder.
- Docker socket se nemountuje. Traefik ani Caddy v tomto projektu nejsou.
- Redis má heslo v `runtime/redis.conf` s oprávněním `600`, ne na příkazové řádce serveru. Politika `noeviction` chrání zámky před tichým vymazáním.
- Všechny služby mají `no-new-privileges`. Oficiální image Nextcloudu a PostgreSQL startují jako root a pak klesnou na svého uživatele; to `no-new-privileges` umožňuje.
- Runtime `.env` je jen v `/docker-data/stacks/nextcloud-gr/.env`, mód `600`, a `.gitignore` ho vylučuje.

## Proxy

`TRUSTED_PROXIES` je seznam CIDR oddělený mezerami. Nextcloud ho čte z proměnné image a Nginx z vygenerovaného `real-ip.conf`. Veřejný protokol je `https` přes `OVERWRITEPROTOCOL`, i když spojení Traefik → Nginx je HTTP. `fastcgi_param HTTPS` se zapíná jen když `X-Forwarded-Proto` je `https`.

HSTS se na tomto Nginxu nenastavuje. Má ho nastavit Traefik, který TLS ukončuje.

## Tajemství

Generovaná hesla se do dokumentace ani do logů nedávají. `BACKUP_AGE_RECIPIENT` je veřejný příjemce. Soubor identity `AGE-SECRET-KEY` do `.env`, Gitu, stacku ani archivu nepatří. `RESTIC_PASSWORD` je v `.env`; další kopie musí být offline, jinak ztráta disku s `.env` znamená ztrátu přístupu k restic repozitáři.

`docker inspect` u kontejnerů Nextcloudu a Redis heslo uvidí, protože ho oficiální image čte z prostředí. To je hranice tohoto návrhu. Soubory se do Gitu neukládají.

## Stará data

Nový stack starý datový adresář nemountuje. `NEXTCLOUD_SOURCE_DATA_DIR` je jen informace pro migraci. Compose ho nepoužívá. Stejný adresář nesmí být zároveň zapisovatelný ve staré i nové instanci.

MariaDB adresář `/SDD/nvme-1T-btrf/nextcloud_gregor/mariadb/db_data` nelze zadat jako PostgreSQL ani jako data Nextcloudu. `check-env.sh` ho odmítne.

## Upgrade

Běžný deploy neumí tiše vyměnit hlavní verzi. Selhaný upgrade nespouští starou image nad databází, která už mohla být migrovaná. Zámek `state/upgrade.lock` pak blokuje další `deploy.sh`, dokud ho správce po obnově nebo vědomém rozhodnutí nesmaže.
