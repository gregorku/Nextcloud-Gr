# Provoz

Skripty se spouštějí jako root v Incus kontejneru, ve kterém už běží Docker a Dockge. Vytvoření kontejneru, disk device a síť device je práce správce mimo tento repozitář.

## Před init.sh

Ověřte v kontejneru:

```bash
findmnt /docker-data
findmnt -T /cesta/k/rodici/postgresql
findmnt -T /cesta/k/rodici/nextcloud-data
```

`/docker-data` musí být přímo mountpoint disku Incus, ideálně SSD/NVMe. PostgreSQL a uživatelská data musí ležet v adresáři uvnitř jiného mountu, ne na kořenovém filesystému kontejneru a ne na samotném mountpointu. Adresář dat nemá být ten, do kterého ještě zapisuje starý Nextcloud.

Doporučené device v Incus, názvy upraví správce podle hostitele:

| Device v kontejneru | Účel | Filesystém | Poznámka |
| --- | --- | --- | --- |
| `/docker-data` | stack, HTML, lokální age archivy | SSD/NVMe | musí být mountpoint |
| rodič `POSTGRESQL_HOST_DIR` | data PostgreSQL 18 | SSD/NVMe | jiný disk než HDD s fotkami, pokud to kapacita dovolí |
| rodič `NEXTCLOUD_DATA_HOST_DIR` | nový datadir | HDD RAID | zatím prázdný adresář |
| zdroj migrace, read-only | staré soubory | stávající HDD | `readonly=true`, jen pro pozdější kopii |
| volitelný backup mount | age kopie nebo restic repo | jiný disk nebo export | `backup.sh` ho přijme jen jako mountpoint |

Vlastník nových prázdných adresářů: PostgreSQL `999:999`, Nextcloud `33:33`. Existující neprázdný strom skript nepřepisuje rekurzivním `chown`. Průchodnost se ověří zápisem jednoho souboru a jeho smazáním v cílovém adresáři, ne ve starých datech.

Na tomto checkoutu ty mounty nejsou. Jejich filesystém, vlastníka a test zápisu musí potvrdit správce v novém kontejneru.

## Pořadí

```bash
./scripts/init.sh
./scripts/update-env.sh
./scripts/check-env.sh
./scripts/deploy.sh
./scripts/post-deploy.sh
./scripts/test.sh
```

`init.sh` zkopíruje Compose a konfiguraci. Nevytváří Docker síť, protože subnet ještě není známý. `deploy.sh` síť vytvoří, připraví adresáře, zapíše `runtime/redis.conf` a `runtime/real-ip.conf` a teprve potom spustí Compose.

`post-deploy.sh` počká na healthchecky. Stavové soubory zapíše atomicky až když běžící obrazy odpovídají pinu, `occ status` souhlasí s `NEXTCLOUD_TAG`, `needsDbUpgrade` je false, hlavní verze PostgreSQL souhlasí s `POSTGRES_IMAGE` a s `PG_VERSION`, a `/status.php` hlásí nainstalovanou instanci mimo maintenance. Když kontrola selže, soubory se nezmění. Nedokončená první instalace evidenci nedostane.

Čistá instalace nemá `config.php` ani `state/installed-version`. Tu `deploy.sh` spustí. `config.php` bez `installed => true` je nedokončená instalace: stejné obrazy se smí spustit, ale stavové soubory vzniknou až když `post-deploy.sh` uvidí nainstalovaný Nextcloud. `config.php` s `installed => true` a bez evidence verze deploy nespustí. `./scripts/record-installed.sh --confirm nextcloud-gr` tehdy přečte `version.php` a `PG_VERSION`. Před startem aplikace deploy sjednotí vlastníka tabulek `oc_*` s `PG_USER`. Nemění heslo v logu, nedává roli SUPERUSER a nemaže datové adresáře.

## Běžný deploy

`deploy.sh` smí běžet opakovaně pro změnu Nginx konfigurace, limitů a ostatních framework hodnot. Když se v Gitu změní `NEXTCLOUD_TAG`, `update-env.sh` ho přenese do `.env` a `deploy.sh` skončí chybou s odkazem na `upgrade.sh`. Samotný deploy tedy databázovou migraci nespustí.

`reload.sh` volá `deploy.sh` a pak kontejnery znovu vytvoří. I tady platí stejná pojistka verze.

## Co musí správce doplnit

- `NEXTCLOUD_BACKEND_BIND` a případně port, pokud 8080 nevyhovuje
- `TRUSTED_PROXIES`, CIDR adresy, ze kterých Traefik posílá `X-Forwarded-*`
- `DOCKER_NETWORK_SUBNET` a gateway po kontrole kolize s WireGuardem, Incus a LAN
- `POSTGRESQL_HOST_DIR` na SSD/NVMe mountu
- `NEXTCLOUD_DATA_HOST_DIR` na HDD, jiný adresář než živá stará data
- `NEXTCLOUD_ADMIN_USER`
- `RESTIC_REPOSITORY` a offline kopii vygenerovaného `RESTIC_PASSWORD`
- `BACKUP_AGE_RECIPIENT`, veřejný age příjemce
- volitelně SMTP a `BACKUP_EXTERNAL_DIR`, pokud je to opravdu mountpoint

Hesla `PG_PASS`, `REDIS_PASSWORD`, `NEXTCLOUD_ADMIN_PASSWORD` a `RESTIC_PASSWORD` generuje `update-env.sh`. Do logu je nepíše.

## Uživatelé a klienti

Veřejné URL je `https://gregor.serveftp.org`. Desktopový klient, mobilní aplikace, WebDAV, CalDAV a CardDAV používají tuto doménu. Nginx posílá `/.well-known/carddav` a `/.well-known/caldav` na `/remote.php/dav/` a `webfinger` i `nodeinfo` na front controller. Velký upload je povolený do 16G shodně v PHP i Nginxu.

Plošný Authentik ForwardAuth se na doménu nezapíná. OIDC může přijít později jako samostatná změna.
