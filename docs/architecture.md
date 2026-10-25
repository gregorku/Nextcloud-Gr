# Architektura

Veřejná cesta zůstává:

```text
Internet → veřejná IP VPS → HAProxy → Infrastructure-netcup / Traefik
        → WireGuard → Nginx v Incus kontejneru na domácím serveru
```

Tento repozitář popisuje jen poslední úsek. DNS, HAProxy, firewall VPS, WireGuard a soubor `configs/traefik/dynamic/nextcloud.yml` v Infrastructure-netcup sem nepatří.

## Služby

| Služba | Image, ověřeno 2026-10-20 | Port na hostiteli |
| --- | --- | --- |
| postgresql | `docker.io/library/postgres:18.6` | žádný |
| redis | `docker.io/library/redis:8.10.2-alpine` | žádný |
| nextcloud | `docker.io/library/nextcloud:35.0.2-fpm` | žádný, PHP-FPM 9000 jen v síti Compose |
| nginx | `docker.io/library/nginx:1.30.6-alpine` | `NEXTCLOUD_BACKEND_BIND:NEXTCLOUD_BACKEND_PORT` |
| cron | stejný tag jako nextcloud, příkaz `/cron.sh` | žádný |

Zdroje pinů:

- Nextcloud 35.0.2, 15. října 2026: https://nextcloud.com/install/
- Požadavky Nextcloud 35, PHP 8.3 / 8.4 / 8.5 (doporučeno 8.5), PostgreSQL 14–18 (doporučeno 18): https://docs.nextcloud.com/server/stable/admin_manual/installation/system_requirements.html
- Tag `35.0.2-fpm` v official-images a Dockerfile `FROM php:8.5-fpm-trixie`, commit `a1af1a30`: https://github.com/nextcloud/docker
- PostgreSQL 18.6, `PGDATA=/var/lib/postgresql/18/docker`, volume `/var/lib/postgresql`: https://hub.docker.com/_/postgres
- Redis 8.10.2 a nginx 1.30.6 stable: https://hub.docker.com/_/redis a https://hub.docker.com/_/nginx

Pohyblivé tagy `latest`, `stable` a `stable-fpm` se nepoužívají. `35.0.2-fpm` je zároveň `fpm` a `35-fpm` v katalogu Docker Hubu; v `.env` je jen přesný patch tag.

Image Nextcloudu obsahuje APCu, OPcache (včetně doporučeného `opcache-recommended.ini`), rozšíření `redis` a `pdo_pgsql`. `apcu.config.php` nastavuje `memcache.local` na APCu. `redis.config.php` nastavuje distribuovanou cache a zamykání, když je `REDIS_HOST`. Hook `configs/nextcloud/hooks/10-apcu.sh` stejné hodnoty zapíše i do `config.php`, aby je obsahovala záloha konfigurace.

## Síť

Compose síť `nextcloud-gr` je external. `deploy.sh` ji vytvoří až z `DOCKER_NETWORK_SUBNET` a `DOCKER_NETWORK_GATEWAY`. Rozsah z tohoto checkoutu není zvolený: rozsahy WireGuardu a domácí LAN nebyly ověřené. `check-env.sh` odmítne placeholder i rozsah mimo RFC1918 a CGNAT `100.64.0.0/10`.

Kontejnery nemají pevné IP. Nginx volá PHP-FPM jako `nextcloud:9000`. Nextcloud volá databázi `postgresql` a Redis `redis`.

Bind adresa backendu je placeholder `set_backend_bind_address`. `0.0.0.0` a loopback `check-env.sh` odmítne. Povolená je jen konkrétní adresa z RFC1918 nebo CGNAT, aby Traefik na VPS dosáhl na domácí kontejner a port nebyl vystavený na všech rozhraních.

## Data

| Účel | Kde se nastavuje | Poznámka |
| --- | --- | --- |
| HTML, config, custom apps, themes | `/docker-data/nextcloud-gr/html` | disk Incus připojený jako `/docker-data` |
| PostgreSQL 18 | `POSTGRESQL_HOST_DIR` | adresář uvnitř mountu na SSD/NVMe, ne samotný mountpoint |
| Uživatelská data | `NEXTCLOUD_DATA_HOST_DIR` | adresář uvnitř HDD RAID mountu, ne data staré instance |
| Stav instalace | `/docker-data/nextcloud-gr/state` | installed-version, postgres-major, upgrade.lock |
| Age archiv | `/docker-data/backups/nextcloud-gr` | dump, config, apps, themes, manifest |
| Restic | `RESTIC_REPOSITORY` | jen uživatelský datový adresář |

Na stroji, kde vznikl tento checkout (`/run/media/gregor/DataLinux`, btrfs), cesty `/docker-data`, `/HDD`, `/SDD` a `/incus-dir` neexistují. Filesystém cílových disků v novém Incus kontejneru odsud ověřit nešel. `deploy.sh` proto při chybějícím mountu adresář nevytvoří.

Uvnitř kontejneru je uživatel Nextcloudu `www-data` uid 33 a uživatel PostgreSQL uid 999. To jsou uid v namespace kontejneru. Na hostiteli je u neprivilegovaného Incus vidět posunuté id. Skripty se spouštějí uvnitř kontejneru a `chown -R` na existujícím stromu nedělají.

## Oddělení verze

`NEXTCLOUD_TAG` v `.env.example` je framework hodnota. `update-env.sh` ji zkopíruje do runtime `.env`, ale tím upgrade nespustí. `deploy.sh` porovná tag se souborem `state/installed-version`. Liší-li se, skončí a odkáže na `upgrade.sh`. Stejná kontrola platí pro hlavní verzi PostgreSQL v `state/postgres-major` a pro `PG_VERSION` v datovém adresáři. Neprázdný datový adresář bez jediného čitelného `PG_VERSION` se nespustí. Image entrypoint by při startu novějšího kódu migraci spustil sám, proto se k `compose up` při neshodě vůbec nedojde.

`config.php` s `installed => true` a bez `installed-version` není čistá instalace. `deploy.sh` ji znovu neinstaluje. Pokračuje jen když `version.php`, `PG_VERSION` v `POSTGRESQL_HOST_DIR/<major>/docker` a u běžícího stacku i `occ` souhlasí s pinem. Evidenci zapíše až potom, a jen když je cron zdravý. Jiný tag nebo jiný major PostgreSQL nespustí a existující evidenci nepřepíše. Soubor bez `installed => true` je nedokončená instalace a evidence se nezapíše, dokud instalace neskončí.

Cron má `NEXTCLOUD_UPDATE=0` a vlastní entrypoint `/cron.sh`. Oficiální image spouští instalaci a upgrade jen u výchozího příkazu `php-fpm`. Upgrade tedy běží jen v kontejneru `nextcloud`.
