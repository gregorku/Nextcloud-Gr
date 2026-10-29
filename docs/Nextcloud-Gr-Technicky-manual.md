# Nextcloud-Gr – Technický manuál projektu

Datum vytvoření: 29. října 2026

Zkoumaná revize: větev `main`, commit `519b4f4` ze dne 25. října 2026

Tento dokument popisuje zdrojový repozitář Nextcloud-Gr. Nevznikl z prohlídky běžícího Incus kontejneru. Na stroji, kde byl manuál sestaven, cesty `/docker-data`, `/incus-dir`, `/HDD`, `/SDD`, `/postgresql-data` a `/nextcloud-data` dne 29. října 2026 neexistují. Služby tedy na tomto stroji nebyly ověřeny jako spuštěné.

Kde se text opírá o přečtený kód, je to uvedeno jako ověřené chování. Kde jde o důsledek složení několika funkcí, je to závěr z kódu. Kde běh na cílovém serveru chybí, je to označeno jako neověřené.

Manuál neobsahuje hesla, tokeny ani obsah runtime souboru `.env`. Uvádí jen názvy proměnných a zástupné hodnoty ze šablony `.env.example`, která je v Gitu.

## 1. Účel projektu

Nextcloud-Gr je sada Docker Compose souborů, konfigurace a bash skriptů pro Nextcloud 35.0.2 v už existujícím Incus kontejneru na domácím serveru. Skripty se mají spouštět uvnitř toho kontejneru jako root. Repozitář kontejner, disková zařízení, WireGuard ani Dockge nevytváří.

Veřejné jméno v `scripts/config.sh` a v šabloně je `gregor.serveftp.org`. HTTPS má končit na Traefiku v projektu Infrastructure-netcup. Tento stack publikuje jen Nginx na adrese a portu z runtime `.env`. PostgreSQL, Redis a PHP-FPM nemají v Compose položku `ports`.

Caddy v Compose není. CrowdSec v tomto repozitáři není: v Compose, skriptech ani v dokumentaci `docs/` se jeho název nevyskytuje. Zda CrowdSec běží jinde na hostiteli nebo na VPS, z tohoto checkoutu zjistit nelze.

## 2. Tři adresáře

Projekt rozlišuje tři vrstvy. Konstanty jsou v `scripts/config.sh`.

```text
Git checkout
/incus-dir/git/Nextcloud-Gr
        |
        | init.sh kopíruje, deploy.sh synchronizuje
        v
Runtime stack
/docker-data/stacks/nextcloud-gr
        |
        v
Trvalá data
/docker-data/nextcloud-gr
cesta z POSTGRESQL_HOST_DIR
cesta z NEXTCLOUD_DATA_HOST_DIR
/docker-data/backups/nextcloud-gr
```

| Vrstva | Cesta v kódu | Co v ní je |
| --- | --- | --- |
| Git checkout | `GIT_DIR=/incus-dir/git/Nextcloud-Gr` | Compose, `configs/`, `scripts/`, `.env.example`, `docs/` |
| Runtime stack | `STACK_DIR=/docker-data/stacks/nextcloud-gr` | kopie Compose a konfigurace, `.env` s módem 600, `runtime/` |
| HTML a stav | `DATA_DIR=/docker-data/nextcloud-gr` | `html/`, `state/` |
| PostgreSQL | `POSTGRESQL_HOST_DIR` z `.env` | datový adresář clusteru, mimo `DATA_DIR` |
| Uživatelská data | `NEXTCLOUD_DATA_HOST_DIR` z `.env` | datadir Nextcloudu, mimo `DATA_DIR` |
| Lokální archivy | `BACKUP_LOCAL_DIR=/docker-data/backups/nextcloud-gr` | age archivy a rollback snímky |

`DEPLOY_ITEMS` obsahuje jen `compose.yml`, `compose`, `configs` a `.env.example`. Runtime `.env`, adresář `runtime/`, `DATA_DIR`, uživatelské soubory, PostgreSQL a `BACKUP_LOCAL_DIR` v tomto seznamu nejsou. `rsync --delete` se proto na ně neaplikuje. Platí jen uvnitř adresářových položek `compose/` a `configs/` v runtime stacku.

Skripty počítají vlastní adresář z `BASH_SOURCE`. Knihovny se tedy načítají z té kopie skriptu, která byla spuštěna. Kopírování do stacku naopak čte pevnou cestu `GIT_DIR`. Spuštění z jiného checkoutu, než je `/incus-dir/git/Nextcloud-Gr`, použije lokální knihovny a zároveň se pokusí kopírovat soubory z `GIT_DIR`. Příklady v tomto manuálu předpokládají kořen checkoutu, který je na cílovém kontejneru právě touto cestou:

```bash
./scripts/init.sh
```

Na stroji tohoto checkoutu `GIT_DIR` neexistuje. Chování kopírování tam proto nebylo spuštěno.

## 3. Struktura repozitáře

| Cesta | Úloha |
| --- | --- |
| `README.md` | krátký provozní přehled |
| `docs/` | architektura, provoz, záloha, upgrade, bezpečnost, Traefik, migrace |
| `compose.yml` | vstupní Compose soubor, jen `include` dílčích souborů |
| `compose/` | sítě a pět služeb |
| `configs/nginx/nginx.conf` | virtuální server Nginxu |
| `configs/nextcloud/hooks/10-apcu.sh` | post-installation a post-upgrade hook |
| `scripts/*.sh` | vstupní provozní skripty |
| `scripts/config.sh` | cesty, jména kontejnerů, piny verzí |
| `scripts/lib/` | sdílené funkce |
| `.env.example` | šablona runtime `.env` |
| `.gitignore` | vylučuje `.env`, zálohy `.env`, `runtime/`, archivy a dumpy |

Compose projekt se jmenuje `nextcloud-gr`. Stejné jméno používá Dockge jako název adresáře pod `/docker-data/stacks`.

## 4. Architektura služeb

Compose soubor služby nespouští sám. Spouští je `deploy.sh` přes `docker compose` v `STACK_DIR`. Následující tabulka popisuje definici v repozitáři, ne ověřený stav serveru.

| Služba | Kontejner | Image z `.env.example` | Publikovaný port | Závislost |
| --- | --- | --- | --- | --- |
| `postgresql` | `nextcloud-gr-postgresql` | `docker.io/library/postgres:18.6` | žádný | síť `nextcloud-gr` |
| `redis` | `nextcloud-gr-redis` | `docker.io/library/redis:8.10.2-alpine` | žádný | síť `nextcloud-gr` |
| `nextcloud` | `nextcloud-gr-app` | `docker.io/library/nextcloud:35.0.2-fpm` | žádný, PHP-FPM 9000 jen v síti | PostgreSQL a Redis healthy |
| `nginx` | `nextcloud-gr-nginx` | `docker.io/library/nginx:1.30.6-alpine` | `NEXTCLOUD_BACKEND_BIND:NEXTCLOUD_BACKEND_PORT` na port 80 | Nextcloud healthy |
| `cron` | `nextcloud-gr-cron` | stejný tag jako nextcloud, příkaz `/cron.sh` | žádný | nextcloud, PostgreSQL a Redis healthy |

Všechny služby mají `restart: unless-stopped`, `security_opt: no-new-privileges:true` a logování `json-file` s limitem z `LOG_MAX_SIZE` a `LOG_MAX_FILES`. Pohyblivé tagy `latest`, `stable`, `stable-fpm`, `fpm`, `production` a holé `alpine` validace runtime `.env` odmítá. Redis a Nginx musí mít přesný patch tag s příponou `-alpine`.

### 4.1 PostgreSQL

Soubor `compose/10-postgresql.yml` nastavuje `POSTGRES_USER` na pevné jméno `nc_bootstrap`, ne na `PG_USER`. Heslo je `PG_PASS`. `PGDATA` je `/var/lib/postgresql/18/docker`. Svazek hostitele je `POSTGRESQL_HOST_DIR` namountovaný na `/var/lib/postgresql`. `POSTGRES_INITDB_ARGS` je `--data-checksums`.

Healthcheck volá `pg_isready` nejdřív jako `POSTGRES_USER`, a když to selže, znovu jen s názvem databáze. Interval je 30 s, timeout 5 s, 5 pokusů, `start_period` 40 s.

`deploy.sh` po startu PostgreSQL srovná role. Initdb superuživatel má OID 10 a PostgreSQL 18 mu nedovolí odebrat `SUPERUSER`. Aplikační role `PG_USER` má být `LOGIN` bez `SUPERUSER`, `CREATEDB` a `CREATEROLE`. Nextcloud i cron mají `NC_setup_create_db_user=false` a přihlašují se jako `PG_USER`. Komentář v Compose uvádí, že superuživatelské přihlášení by vedlo k roli `oc_admin`, která pak nevidí tabulky původního vlastníka.

Když je OID 10 stále jméno `PG_USER`, deploy v jedné transakci provede `DROP ROLE IF EXISTS nc_bootstrap`, roli přejmenuje na `nc_bootstrap` a založí novou aplikační roli. `ALTER DATABASE` běží až po commitu. Jiný initdb superuživatel než `nc_bootstrap` nebo `PG_USER` deploy zastaví. Datový adresář přitom nemaže.

### 4.2 Redis

Redis nemá datový svazek. `deploy.sh` zapíše `STACK_DIR/runtime/redis.conf` a Compose ho připojí jen pro čtení z cesty `REDIS_CONFIG_FILE`. Výchozí šablona míří na `/docker-data/stacks/nextcloud-gr/runtime/redis.conf`, tedy na stejný soubor. Když se `REDIS_CONFIG_FILE` od této cesty odchýlí, Compose připojí jiný soubor, než který `deploy_render_runtime` zapsal. To je závěr z kódu.

Konfigurace váže `0.0.0.0`, zapíná `protected-mode`, poslouchá na 6379, nastavuje `requirepass`, `maxmemory 256mb`, `maxmemory-policy noeviction`, vypíná RDB i AOF. Heslo se na příkazovou řádku serveru nedává. Healthcheck volá `redis-cli` s heslem z prostředí kontejneru a hledá `PONG`.

Soubor `redis.conf` kód ukládá s módem `644`. Adresář `runtime` dostane mód `700`. Dokument `docs/security.md` uvádí mód `600`. Směrodatný je kód: zapisuje se `644`.

### 4.3 Nextcloud PHP-FPM

Služba `nextcloud` nemá vlastní entrypoint ani příkaz. Oficiální image tedy může při `php-fpm` instalovat nebo upgradovat. `NEXTCLOUD_UPDATE` u této služby nastavené není. Pojistka proti tichému upgradu je ve `deploy.sh`: jiný tag než záznam v `state/installed-version` se nespustí.

Svazky:

- `NEXTCLOUD_HTML_HOST_DIR` na `/var/www/html` (kód, `config`, `custom_apps`, `themes`)
- `NEXTCLOUD_DATA_HOST_DIR` na `/var/www/html/data`
- hook `10-apcu.sh` do `post-installation` i `post-upgrade`

`NEXTCLOUD_DATA_DIR` v prostředí je `/var/www/html/data`. Databáze se jmenuje podle `PG_DB`, uživatel podle `PG_USER`, hostitel `postgresql`. Redis je `redis:6379`.

Healthcheck otevře `127.0.0.1:9000` a vyžaduje, aby `occ status` obsahovalo `installed: true`. Samotný otevřený port tedy healthcheck nesplní. `start_period` je 180 s.

Hook zapíše do `config.php` tyto hodnoty, bez výpisu hesel:

- `memcache.local` = `\OC\Memcache\APCu`
- `memcache.distributed` = `\OC\Memcache\Redis`
- `memcache.locking` = `\OC\Memcache\Redis`

Image už obsahuje `apcu.config.php` a `redis.config.php`. Hook má stejné hodnoty dostat i do `config.php`, aby je nesla záloha konfigurace.

### 4.4 Nginx

Jediný publikovaný port je `"${NEXTCLOUD_BACKEND_BIND}:${NEXTCLOUD_BACKEND_PORT}:80"`. TLS se v tomto Nginxu nenastavuje. `server_name` v `configs/nginx/nginx.conf` je natvrdo `gregor.serveftp.org`. `client_max_body_size` je `16G`, stejně jako výchozí `PHP_UPLOAD_LIMIT`.

`fastcgi_pass` míří na upstream `nextcloud:9000`. Proměnná `HTTPS` pro FastCGI je `on` jen když `X-Forwarded-Proto` je `https`. HSTS v tomto souboru není. `docs/security.md` ho svěřuje Traefiku.

`/.well-known/carddav` a `/.well-known/caldav` vracejí 301 na `/remote.php/dav/`. `webfinger` a `nodeinfo` jdou na front controller. Skryté cesty `config`, `data`, `lib` a podobně vracejí 404.

Healthcheck stáhne `http://127.0.0.1/status.php` a hledá `"installed":true`.

Soubor `real-ip.conf` generuje `deploy.sh` z `TRUSTED_PROXIES`: `real_ip_header X-Forwarded-For`, `real_ip_recursive on` a pro každý CIDR řádek `set_real_ip_from`. Compose ho bere jako `../runtime/real-ip.conf` vůči `compose/40-nginx.yml`, tedy ze stacku.

### 4.5 Cron

Cron používá stejný image a stejné dva datové svazky. Příkaz je `/cron.sh`. Prostředí má `NEXTCLOUD_UPDATE=0`. Komentář Compose, ověřený autory vůči `docker-entrypoint.sh` dne 20. října 2026, říká, že oficiální entrypoint instaluje a upgraduje jen u `php-fpm` nebo Apache, případně při `NEXTCLOUD_UPDATE=1`. Cron tedy upgrade nespouští.

Healthcheck čte `/proc/1/cmdline`. PID 1 musí být `busybox crond` a nesmí to být ještě `cron.sh`. Současně `occ status` musí hlásit `installed: true`. Obraz nemá `ps`. Starší kontrola přes proměnné shellu v Compose souboru byla prázdná, protože Compose proměnné interpoluje dřív. To je vysvětlení v komentáři souboru `compose/50-cron.yml`.

Cron nedostává administrátorské proměnné Nextcloudu ani `TRUSTED_PROXIES`. SMTP proměnné dostává, když jsou v `.env`.

### 4.6 Pořadí startu v deploy.sh

`deploy_compose` nedělá jedno `compose up` nad celým souborem jako první krok. Pořadí v kódu je:

1. `compose pull`
2. start jen služby `postgresql`, čekání na health, srovnání rolí
3. příprava nedokončené instalace, která může zastavit nextcloud, cron a nginx
4. start `redis` a `nextcloud`
5. po otevření portu 9000 jednou `maintenance:install`, pokud `occ` hlásí `installed: false`
6. start celého Compose, tedy i nginx a cron
7. kontrola běžící instalace a zápis stavových souborů

`depends_on` v Compose zůstává v platnosti pro jednotlivé `up`.

## 5. Síť a vnější infrastruktura

Compose síť `nextcloud-gr` je `external: true`. Compose ji nevytváří. Vytváří ji `deploy_ensure_network` příkazem `docker network create --driver bridge` se subnetem a bránou z `.env`. Když síť už existuje s jiným subnetem nebo jinou bránou, deploy skončí a síť nemění.

Kontejnery nemají pevné IP. Jména v síti jsou `postgresql`, `redis`, `nextcloud` a `nginx`. Cron je ve stejné síti.

Veřejná cesta podle `docs/architecture.md`:

```text
Internet
  -> veřejná IP VPS
  -> HAProxy
  -> Infrastructure-netcup / Traefik
  -> WireGuard
  -> Nginx v Incus kontejneru
```

DNS, HAProxy, firewall VPS, WireGuard a soubor Traefiku do tohoto repozitáře nepatří. `docs/traefik-integration.md` popisuje smlouvu: schéma mezi Traefikem a Nginxem je HTTP, TLS drží Traefik, `TRUSTED_PROXIES` má být CIDR, odkud Traefik přichází. Ukázkový router v tom dokumentu je vzor a do tohoto Compose se nezapisuje.

`deploy_restart_services` Traefik nerestartuje. Vypíše, že lokální statický reverse proxy restart nepotřebuje, a vrátí úspěch.

`TRUSTED_PROXIES` je seznam CIDR oddělený mezerami. Čárky validace odmítá. `OVERWRITEPROTOCOL` musí být `https`. `OVERWRITEHOST` a `OVERWRITECLIURL` jsou ve výchozí šabloně `gregor.serveftp.org` a `https://gregor.serveftp.org`.

Dockge je předpoklad nasazení, ne součást Compose. Konstanty: kontejner `dockge`, obraz `louislam/dockge:latest`, port `5001`, data `/docker-data/dockge`. `deploy_dockge` jen ověří, že kontejner běží a že `DOCKGE_STACKS_DIR` je `/docker-data/stacks`. Dockge neinstaluje, nezastavuje a nemění.

Komentář v `compose/00-networks.yml` uvádí rozsahy, kterým se má adresace vyhnout: `192.168.12.0/24` jako LAN přes Incus `br0`, `172.17.0.0/16` jako výchozí Docker bridge v kontejneru a `10.10.10.0/24` jako `incusbr0`. Tyto rozsahy jsou text komentáře. Z tohoto checkoutu nebyly na síťových rozhraních přeměřeny.

## 6. Persistentní data a stav

`/docker-data` musí být přímo mountpoint. `init.sh` i `deploy.sh` ho odmítnou vytvořit na kořenovém filesystému kontejneru.

PostgreSQL a datadir Nextcloudu musí ležet v adresáři uvnitř už připojeného disku, ne na kořeni a ne na samotném mountpointu. Chybějící rodič se nevytváří. Prázdný listový adresář `deploy.sh` vytvoří a prázdnému nastaví vlastníka. PostgreSQL očekává uid `999`, Nextcloud uid `33`. Neprázdný adresář se rekurzivně `chown -R` nepřepisuje. Vlastník smí být očekávaný uid nebo root. Jiný uid deploy zastaví.

Uvnitř kontejneru jsou to uid v namespace kontejneru. Jak je uvidí neprivilegovaný Incus na hostiteli, z tohoto checkoutu ověřeno není.

| Účel | Cesta | Mód po přípravě |
| --- | --- | --- |
| HTML | `/docker-data/nextcloud-gr/html` | u prázdného adresáře vlastník `33:33` |
| Stav | `/docker-data/nextcloud-gr/state` | adresář `700` |
| `installed-version` | `state/installed-version` | soubor `600`, obsah je tag |
| `postgres-major` | `state/postgres-major` | soubor `600` |
| `upgrade.lock` | `state/upgrade.lock` | vzniká v `upgrade.sh` |
| Age archiv | `/docker-data/backups/nextcloud-gr/nextcloud-gr-YYYYMMDD-HHMMSS.tar.gz.age` | adresář `700` |
| Restic | `RESTIC_REPOSITORY` | heslo `RESTIC_PASSWORD` |

Zápis stavu je atomický: dočasný soubor ve stejném adresáři a `mv`. `postgres-major` se zapisuje dřív než `installed-version`. Když přejmenování verze selže, předchozí soubor hlavní verze se vrací. Prázdný `installed-version` deploy odmítne a soubor nenahrazuje.

Rozhodnutí verze před startem:

| Stav na disku | Rozhodnutí `deploy_version_decision` |
| --- | --- |
| `installed-version` souhlasí s `NEXTCLOUD_TAG` | `unchanged`, deploy může pokračovat |
| soubor existuje a tag se liší | chyba, odkaz na `upgrade.sh` |
| není soubor a není `config.php` | `first-install` |
| `config.php` existuje a nemá `installed => true` | `unfinished` |
| `config.php` má `installed => true` a soubor verze chybí | `recover`, není to první instalace |

`recover` pokračuje jen když `version.php`, cluster PostgreSQL a u běžícího stacku i `occ` souhlasí s pinem. Evidence se zapíše až po zdravém cronu. Nesoulad evidenci nepřepíše.

`upgrade.lock` s obsahem deploy zastaví. Prázdný soubor zámku se ignoruje. Text zámku se vrací jako chybová zpráva.

Starší instalace na fyzickém hostiteli je v `config.sh` jen jako zakázaný cíl cest:

- `/docker/nextcloud/nextcloud_gregor/nextcloud_app`
- `/HDD/data-raid-HDD/Nextcloud-data/data-Gregor`
- `/SDD/nvme-1T-btrf/nextcloud_gregor/mariadb/db_data`
- `/docker/nextcloud/nextcloud_gregor/redis/data`

`NEXTCLOUD_SOURCE_DATA_DIR` je volitelná informace pro migraci. Compose ji nemountuje. Prázdná hodnota je platná. Když je vyplněná, nesmí to být adresář MariaDB, starého Redisu ani staré aplikace a nesmí splývat s novým datadirem.

`docs/migration-from-current.md` migraci nespouští. Popisuje ruční cutover. Přímý převod MariaDB do PostgreSQL se v projektu nedělá. `restore.sh` dump bez hlavičky `PGDMP` odmítne.

## 7. Konfigurace prostředí

Runtime soubor je `/docker-data/stacks/nextcloud-gr/.env`. Šablona v Gitu je `.env.example`. Do stacku ji kopíruje `init.sh`. `update-env.sh` čte šablonu ze stacku, ne z Gitu přímo. Bez předchozího `init.sh` synchronizace skončí, protože šablona ve stacku chybí.

Politika v `scripts/lib/env/policy.sh`:

| Politika | Chování při `update-env.sh` |
| --- | --- |
| `framework` | hodnota se vždy vezme z `.env.example` |
| `user` | neprázdná hodnota v `.env` zůstane, prázdná se doplní ze šablony |
| `generated` | skutečné tajemství zůstane; chybějící nebo `set_*` se vygeneruje jednou |

Framework jsou mimo jiné jména obrazů, `NEXTCLOUD_TAG`, `NEXTCLOUD_DOMAIN`, cesty `DATA_DIR`, HTML a `BACKUP_LOCAL_DIR`, `PG_DB`, `PG_USER`, PHP limity, retence resticu a `UPGRADE_MIN_FREE_MB`.

User jsou mimo jiné `POSTGRESQL_HOST_DIR`, `NEXTCLOUD_DATA_HOST_DIR`, `NEXTCLOUD_BACKEND_BIND`, port, subnet, brána, `TRUSTED_PROXIES`, `NEXTCLOUD_ADMIN_USER`, `BACKUP_EXTERNAL_DIR`, `BACKUP_AGE_RECIPIENT`, `RESTIC_REPOSITORY` a SMTP.

Generated jsou `PG_PASS`, `REDIS_PASSWORD`, `NEXTCLOUD_ADMIN_PASSWORD` a `RESTIC_PASSWORD`. Generátor volá `openssl rand -base64`. Pro databázi, Redis a restic je to 36 bajtů, pro heslo administrátora 24 bajtů. Hodnota se do logu nepíše. Existující heslo se nerotuje.

Zápis jde přes `STACK_DIR/.env.tmp` a předchozí soubor se zkopíruje jako `.env.bak-YYYYMMDD-HHMMSS`. Mód `.env`, dočasného souboru i zálohy je `600`. Proměnné, které ze šablony zmizely, se do nového souboru nepřenášejí. Komentáře a pořadí se berou ze šablony.

`check-env.sh` i `deploy.sh` volají `env_validate`. Ta vyžaduje všechny klíče politiky, zakazuje neznámé klíče a v režimu `runtime` odmítá hodnotu začínající `set_`. Soubor nemění.

Vybraná pravidla runtime režimu, ověřená v `scripts/lib/env/validate.sh`:

- `COMPOSE_PROJECT_NAME` musí být `nextcloud-gr`.
- `DATA_DIR`, HTML, `BACKUP_LOCAL_DIR` a `NEXTCLOUD_DOMAIN` musí odpovídat konstantám v `config.sh`.
- `NEXTCLOUD_BACKEND_BIND` musí být IPv4 v RFC1918 nebo v CGNAT `100.64.0.0/10`. `0.0.0.0` a `127.0.0.0/8` jsou odmítnuté.
- Port je 1 až 65535 a nesmí to být 5432, 6379, 9000 ani 5001.
- `NEXTCLOUD_TAG` musí odpovídat `X.Y.Z-fpm`.
- `POSTGRES_IMAGE` musí být `docker.io/library/postgres:18.x`.
- Subnet je síťová adresa, prefix 8 až 28, brána leží uvnitř a není to adresa sítě.
- `PG_PASS` má 16 až 99 znaků. Ostatní generovaná hesla mají aspoň 16 znaků.
- `NEXTCLOUD_ADMIN_USER` je 1 až 64 znaků ze sady písmen, číslic, tečky, podtržítka a pomlčky.
- PostgreSQL a data Nextcloudu jsou absolutní cesty bez `..`, navzájem různé a mimo Git, stack, HTML data a lokální age zálohy.
- `RESTIC_REPOSITORY` je absolutní cesta, nebo schéma `sftp`, `rest`, `s3`, `rclone`, `azure`, `gs`, `b2` či `swift`.
- Prázdné smějí být `BACKUP_EXTERNAL_DIR`, `BACKUP_AGE_RECIPIENT`, `NEXTCLOUD_SOURCE_DATA_DIR` a SMTP, dokud není `SMTP_HOST`. Když `SMTP_HOST` je, jsou povinné jméno, heslo, odesílatel a doména. `SMTP_SECURE` smí být `tls`, `ssl` nebo prázdné.
- `UPGRADE_MIN_FREE_MB` je celé číslo aspoň 1024. Šablona má 5120.
- `BACKUP_AGE_RECIPIENT` smí být veřejný `age1…` nebo veřejný klíč `ssh-ed25519` či `ssh-rsa`. Řetězec `AGE-SECRET-KEY-` je odmítnut.

Režim `example`, který volá `test_env_example`, vyžaduje prefix `set_` u těchto klíčů: `NEXTCLOUD_BACKEND_BIND`, `TRUSTED_PROXIES`, `DOCKER_NETWORK_SUBNET`, `DOCKER_NETWORK_GATEWAY`, `POSTGRESQL_HOST_DIR`, `NEXTCLOUD_DATA_HOST_DIR`, `PG_PASS`, `REDIS_PASSWORD`, `NEXTCLOUD_ADMIN_USER`, `NEXTCLOUD_ADMIN_PASSWORD`, `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`.

Aktuální `.env.example` prefix `set_` má u `PG_PASS`, `REDIS_PASSWORD`, `NEXTCLOUD_ADMIN_PASSWORD` a `RESTIC_PASSWORD`. U ostatních jmenovaných klíčů jsou v souboru konkrétní hodnoty, například bind `192.168.12.232`, `TRUSTED_PROXIES=10.110.100.1/32`, subnet `172.18.0.0/24`, brána `172.18.0.1`, cesty `/postgresql-data/data` a `/nextcloud-data/data`, uživatel `ncadmin` a restic pod `/docker-data/backups/nextcloud-gr/restic`.

Dne 29. října 2026 byl v tomto checkoutu spuštěn `./scripts/test.sh --static`. Skončil návratovým kódem 1 hláškou `Example value for DOCKER_NETWORK_GATEWAY is not a placeholder.` Další statické testy v tom běhu neproběhly. Pořadí klíče, který selže první, určuje pořadí asociativního pole v Bash. Z obsahu souboru plyne, že stejné pravidlo nesplňují ani další klíče bez prefixu `set_`.

Komentáře v `.env.example` a v `compose/00-networks.yml` pořád mluví o zástupných `set_` hodnotách. Bind `192.168.12.232` leží v rozsahu `192.168.12.0/24`, který komentář sítě uvádí jako rozsah, jemuž se má adresace vyhnout. Rozpor je mezi komentářem a hodnotou v šabloně. Validace runtime takovou adresu jako RFC1918 přijme. Zda je v cílovém kontejneru volná, ověřeno není.

## 8. Přehled skriptů

Všechny vstupní skripty kromě `test.sh --static` a `shellcheck.sh` vyžadují root, příkaz `git` a příkaz `rsync`. To dělá `check_environment`. Skripty, které sahají na Docker, navíc vyžadují klienta `docker` a běžící démon. `set -Eeuo pipefail` je zapnuté. `fail` vypíše řádek `[FAIL]` na stderr a skončí kódem 1.

| Skript | Argumenty, které kód přijímá | Docker | Mění data |
| --- | --- | --- | --- |
| `scripts/init.sh` | žádné, nebo `--help` | ano, démon musí běžet | kopie do stacku, adresáře na `/docker-data` |
| `scripts/update-env.sh` | žádné, nebo `--help` | ne | vytváří a přepisuje `.env` a `.env.bak-*` |
| `scripts/check-env.sh` | žádné, nebo `--help` | ne | nemění `.env` |
| `scripts/deploy.sh` | žádné, nebo `--help` | ano | stack, síť, runtime soubory, kontejnery, role v PostgreSQL, případně instalace |
| `scripts/post-deploy.sh` | žádné, nebo `--help` | ano | stavové soubory až po úspěšných kontrolách |
| `scripts/test.sh` | žádné, `--static`, `--help` | v runtime režimu ano | `--static` píše do dočasného adresáře |
| `scripts/reload.sh` | žádné, `--pull`, `--help` | ano | volá deploy a znovu vytváří kontejnery |
| `scripts/upgrade.sh` | `--target`, `--confirm`, `--help` | ano | záloha, zámek, nový kontejner Nextcloudu |
| `scripts/backup.sh` | žádné, `--hold`, `--help` | ano | archiv, restic, maintenance, cron |
| `scripts/restore.sh` | `--archive`, `--identity`, `--confirm`, volitelně `--replace-data` a `--allow-version-mismatch` | při `--replace-data` ano | bez přepínače nic trvalého nepřepisuje |
| `scripts/reset-test.sh` | `--confirm nextcloud-gr` | ano | maže obsah čtyř adresářů |
| `scripts/record-installed.sh` | `--confirm nextcloud-gr` | ano | může zapsat stav a spustit shodné obrazy |
| `scripts/shellcheck.sh` | žádné | ne | nemění projekt |

`--pull` u `reload.sh` je přijaté a druhé stahování nespouští. Image stáhne `deploy.sh`.

## 9. Mapa závislostí

### 9.1 Volající a volaný

| Volající | Volaný | Účel |
| --- | --- | --- |
| `init.sh` | `check_environment`, `require_docker`, `require_docker_daemon` | root, git, rsync, Docker |
| `init.sh` | `init_directories` | mount `/docker-data`, adresáře dat a záloh |
| `init.sh` | `init_stack` → `sync_replace_item` | první kopie `DEPLOY_ITEMS`, bez `rsync --delete` |
| `update-env.sh` | `env_sync` | srovnání `.env` se šablonou ve stacku |
| `check-env.sh` | `env_validate` | kontrola runtime `.env` |
| `deploy.sh` | `deploy_sync_stack` | `rsync -a --delete` jen v `compose/` a `configs/` |
| `deploy.sh` | `deploy_check_env` | znovu `env_validate` |
| `deploy.sh` | `deploy_assert_same_version` | pojistka tagu, PostgreSQL majoru a zámku |
| `deploy.sh` | `deploy_prepare_storage`, `deploy_ensure_network`, `deploy_render_runtime` | disky, síť, `redis.conf`, `real-ip.conf` |
| `deploy.sh` | `deploy_dockge`, `deploy_validate_compose`, `deploy_compose` | Dockge, `compose config`, start |
| `deploy.sh` | `deploy_restart_services` | prázdný krok, Traefik se nerestartuje |
| `deploy.sh` | `deploy_wait_dockge` | čekání na kontejner Dockge, nejvýše 30 sekund |
| `reload.sh` | `deploy.sh`, `compose_reload`, `post-deploy.sh`, `test.sh` | nasazení a nové kontejnery |
| `upgrade.sh` | `upgrade_run_sequence` | cron, aplikace, `backup.sh --hold`, nový app kontejner |
| `backup.sh` | `backup_quiesce_writers`, `backup_dump_postgresql`, `backup_restic_snapshot_dir` | klidový bod, dump, snapshot |
| `restore.sh` | `backup_decrypt_file`, `restore_perform` | dešifrování a při `--replace-data` přepis |
| `test.sh` | knihovny v `scripts/lib/tests/` | statické, nebo runtime kontroly |
| `record-installed.sh` | `record_installed_run` | doplnění evidence bez zbytku deploye |
| `reset-test.sh` | `reset_test_instance` | vyprázdnění testovací instance |

`deploy.sh` `reset-test.sh` nevolá. `upgrade.sh` při chybě starý image znovu nespouští.

### 9.2 Běžný postup

```text
init.sh
  zkontroluje root a Docker
  vyžaduje mountpoint /docker-data
  zkopíruje compose.yml, compose/, configs/, .env.example
        |
        v
update-env.sh
  vytvoří .env, doplní framework, zachová user hodnoty
  vygeneruje chybějící hesla
        |
        v
správce doplní zbylé set_* a provozní cesty
        |
        v
check-env.sh
  env_validate, soubor nemění
        |
        v
deploy.sh
  sync stacku, verze, disky, síť, runtime soubory
  PostgreSQL, role, instalace, nginx, cron, stav
        |
        v
post-deploy.sh
  health, occ, status.php, zápis stavu
        |
        v
test.sh
  projekt, .env, Compose, Docker, Dockge, síť, port
```

### 9.3 Upgrade

```text
změna NEXTCLOUD_TAG v Gitu
        |
        v
update-env.sh a check-env.sh
        |
        v
upgrade.sh --target STEJNY_TAG --confirm nextcloud-gr
  krok verze, matice PHP, volné místo, health
  zámek state/upgrade.lock
  zastavení cronu
  kontrola max-version v custom_apps
  backup.sh --hold
  force-recreate jen služby nextcloud
  occ, needsDbUpgrade, status.php
  force-recreate cronu
  vypnutí maintenance
  přepis installed-version a smazání zámku
```

Při chybě zámek zůstane, cron se znovu zastaví a předchozí image se nespustí. `deploy.sh` zámek respektuje.

### 9.4 Záloha a obnova

```text
backup.sh
  zastaví cron, zapne maintenance
  pg_dump -Fc
  kopie config, custom_apps, themes, app-list, stack.env
  restic snapshot datadiru
  manifest a age archiv
  volitelně restic copy a kopie archivu na mount
  vypne maintenance a vrátí cron
        |
        v
restore.sh bez --replace-data
  dešifruje, ověří manifest, dump a snapshot
  nic živého nepřepíše, návratový kód 2
        |
        v
restore.sh --replace-data
  app a cron musejí být zastavené
  PostgreSQL musí být healthy
  rollback snímek, přepis souborů, hesla administrátora v .env,
  pg_restore a restic restore
```

## 10. Sdílené knihovny

`scripts/lib/env/load.sh` načte konstanty, pomocné funkce, parser, čtení, politiku, generátor, zápis, synchronizaci a validaci.

`scripts/lib/checks/load.sh` načte kontroly Dockeru, filesystému, Compose a Gitu.

| Knihovna | Funkce, které vstupní skripty skutečně používají |
| --- | --- |
| `lib/common.sh` | `require_root`, `require_command`, `check_environment` |
| `lib/logging.sh` | `info`, `ok`, `warn`, `fail`, `print_header`, `print_section`, `print_footer` |
| `lib/filesystem.sh` | `ensure_directory`, `require_directory` |
| `lib/mount.sh` | mountpoint `/docker-data`, listový adresář na cizím disku |
| `lib/docker.sh` | existence kontejneru, `docker exec`, klienti PostgreSQL |
| `lib/docker-compose.sh` | `compose_cmd` v `STACK_DIR` s `--env-file .env` |
| `lib/deploy/stack.sh` | pojistky cest a synchronizace |
| `lib/deploy/compose.sh` | role PostgreSQL, `maintenance:install`, start |
| `lib/deploy/version-guard.sh` | pojistka verze a zápis ověřené evidence |
| `lib/upgrade/version.sh` | povolený krok, rozhodnutí o evidenci a majoru |
| `lib/upgrade/php.sh` | matice PHP jen pro Nextcloud 35: 8.3, 8.4 a 8.5 |
| `lib/upgrade/apps.sh` | `max-version` zapnutých custom aplikací |
| `lib/backup/*.sh` | šifrování age, dump, restic, obnova |
| `lib/nextcloud/occ.sh` | `occ` jako `www-data` v `nextcloud-gr-app` |

`upgrade_step_allowed` povolí novější minor nebo patch stejné hlavní verze, nebo přesně následující hlavní verzi. Downgrade vrací chybu. Samotný číselný krok nestačí. `upgrade_php_is_supported` pro neznámou hlavní verzi, včetně 36, vrací kód 2 a `upgrade.sh` skončí. Matice byla podle komentáře zkontrolována 20. října 2026 proti dokumentaci Nextcloudu 35.

`nextcloud_occ` spouští `docker exec -u www-data nextcloud-gr-app php occ`. `nextcloud_maintenance` přijímá jen `on` a `off`.

V repozitáři jsou i funkce, u kterých nebyl nalezen volající: `run_step`, `git_is_clean`, `git_current_branch`, `git_current_revision`, `docker_http_headers`, `ensure_directory_owner`, `remove_directory`, `compose_down`, `compose_logs`. `compose_restart` je definovaný a vstupní skripty ho nevolají. Komentáře u Compose pomocníka pořád zmiňují Prometheus. Komentář u `docker_http_headers` mluví o certifikátech Traefiku. V tomto stacku se ta funkce nespouští.

Dvě definice stejného jména se přepisují podle pořadí `source`. `backup_file` je v `lib/filesystem.sh` i v `lib/env/writer.sh`. Verze ve writeru nastavuje mód `600` a používá ji `update-env.sh`. `docker_container_running` je v `lib/docker.sh` (`docker ps`) i v `lib/checks/docker.sh` (`docker inspect`). V `deploy.sh` se později načte verze z `checks/docker.sh`.

## 11. init.sh

1. Účel. Připravit runtime stack v existujícím Incus kontejneru.
2. Kdy. Jednou před `update-env.sh`, a znovu když je potřeba znovu položit soubory stacku bez startu Compose. Běžná aktualizace souborů patří do `deploy.sh`, který synchronizuje s `--delete` uvnitř `compose/` a `configs/`.
3. Spuštění. Jako root, z kořene checkoutu na cílovém kontejneru: `./scripts/init.sh`. Nápověda je `./scripts/init.sh --help`. Jiný argument skončí chybou.
4. Parametry. Žádné povinné. Proměnné bere z `config.sh`, ne z `.env`. Síťový rozsah ještě nezná a síť nevytváří.
5. Závislosti. `config.sh`, `common.sh`, `logging.sh`, `filesystem.sh`, `docker.sh`, `git.sh`, `mount.sh`, `checks/load.sh`, `deploy/stack.sh`, `init/directories.sh`, `init/stack.sh`, `init/summary.sh`. Programy: bash, git, rsync, docker, findmnt.
6. Mění. Vytvoří `DATA_DIR`, `state` a `BACKUP_LOCAL_DIR` s módem `700` u stavu a záloh. Adresář `STACK_DIR` naplní kopií `DEPLOY_ITEMS`. `sync_replace_item` u každé položky udělá `rm -rf` cíle uvnitř stacku a `cp -a`. Cíl musí být přímý potomek stacku.
7. Destruktivní operace. Smaže předchozí `compose.yml`, `compose/`, `configs/` a `.env.example` ve stacku a nahradí je kopií z `GIT_DIR`. `.env`, `runtime/`, data a zálohy tímto mazáním neprocházejí, protože nejsou v `DEPLOY_ITEMS`. PostgreSQL a datadir Nextcloudu nevytváří.
8. Chyby. Chybí root, git, rsync, Docker nebo démon. `/docker-data` není mountpoint. Zdroj v `GIT_DIR` chybí. Cesta stacku nesplňuje pojistky `assert_sync_paths`. Neznámý argument.
9. Výstup. Hlavička `Nextcloud-Gr initialization`, řádky `[ OK ]` a text dalších kroků. Návrat 0 při dokončení `init_summary`.
10. Další krok. `./scripts/update-env.sh`, potom ruční doplnění `set_*`, potom `./scripts/check-env.sh` a `./scripts/deploy.sh`.

## 12. update-env.sh

1. Účel. Vytvořit nebo srovnat runtime `.env` se šablonou ve stacku.
2. Kdy. Po `init.sh` a znovu po změně framework hodnot v šabloně, včetně `NEXTCLOUD_TAG`. Samotná změna tagu upgrade nespustí.
3. Spuštění. `./scripts/update-env.sh` jako root. Docker nepotřebuje.
4. Parametry. Žádné. Musí existovat `/docker-data/stacks/nextcloud-gr/.env.example`. OpenSSL je potřeba jen když se generuje tajemství.
5. Závislosti. `env/load.sh` a tedy parser, politika, generátor, writer a sync.
6. Mění. Vytvoří `.env`, když chybí. Přepíše ho přes dočasný soubor. Starý soubor uloží jako `.env.bak-YYYYMMDD-HHMMSS`. Mód je `600`.
7. Destruktivní operace. Framework hodnoty v `.env` se nahradí šablonou. User hodnota se nepřepíše, když je neprázdná. Hesla se nerotují. Zálohy `.env` obsahují tajemství. `.gitignore` vylučuje `.env` i `.env.bak-*`. Do Gitu se z tohoto skriptu nezapisují.
8. Chyby. Chybí šablona, root, git, rsync nebo openssl při generování. Neznámá politika. Neznámý argument. Rozdíl user hodnoty se vypíše jen když klíč není citlivý. Citlivé jsou klíče s `PASSWORD`, `SECRET` nebo `PG_PASS`.
9. Výstup. Hlavička `Updating .env`, informace o generování bez samotné hodnoty, počet odlišných user proměnných a `".env ready."` Varování, že zbylé `set_*` je nutné nahradit před `deploy.sh`.
10. Další krok. Ruční úprava zbylých zástupných hodnot a `./scripts/check-env.sh`.

## 13. check-env.sh

1. Účel. Ověřit runtime `.env` bez startu kontejnerů a bez zápisu.
2. Kdy. Po doplnění `.env` a před `deploy.sh`. Lze ho opakovat.
3. Spuštění. `./scripts/check-env.sh` jako root.
4. Parametry. Žádné. Čte `ENV_FILE` ze `config.sh`.
5. Závislosti. `env_validate` a pravidla v kapitole 7.
6. Mění. Nic v `.env`. Vytváří jen výstup na terminál.
7. Destruktivní operace. Žádné.
8. Chyby. Chybějící proměnná, neznámá proměnná, hodnota `set_*`, špatná adresa, CIDR, port nebo cesta, heslo PostgreSQL mimo 16 až 99 znaků. Nápověda skriptu říká, že projektová hodnota `BACKUP_EXTERNAL_DIR` je `/backups`. V `config.sh` ani v `.env.example` tahle cesta není. Šablona má prázdnou hodnotu a `backup.sh` neprázdnou cestu přijme jen jako mountpoint s dalšími kontrolami. Nápověda je v této větě zastaralá. Směrodatná je validace a `backup.sh`.
9. Výstup. `Environment configuration OK.` a návrat 0, jinak `[FAIL]` a návrat 1.
10. Další krok. `./scripts/deploy.sh`.

## 14. deploy.sh

1. Účel. Srovnat runtime stack s `GIT_DIR` a spustit ho, když pin Nextcloudu a hlavní verze PostgreSQL odpovídají tomu, co už je na disku, nebo když jde o první či nedokončenou instalaci.
2. Kdy. První instalace a opakovaný deploy beze změny verze: úprava Nginxu, limitů a ostatních framework hodnot. Změna tagu sem nepatří.
3. Spuštění. `./scripts/deploy.sh` jako root v kontejneru, kde běží Docker a Dockge. Pracovní adresář Compose je vždy `STACK_DIR`, protože `compose_cmd` se do něj přepne.
4. Parametry. Žádné. Čte runtime `.env`.
5. Závislosti. Pořadí ve skriptu: prostředí, Docker, synchronizace, ověření `DEPLOY_ITEMS` v Gitu, validace `.env`, pojistka verze, disky, síť, runtime soubory, Dockge, `docker compose config`, `deploy_compose`, prázdný restart proxy, čekání na Dockge, souhrn.
6. Mění. Soubory `compose/` a `configs/` ve stacku. Soubor `compose.yml` a `.env.example` se kopírují bez `--delete`. Vznikne síť, když chybí. Vzniknou `runtime/redis.conf` a `runtime/real-ip.conf`. Vzniknou prázdné datové adresáře a jejich vlastník. V PostgreSQL mohou vzniknout nebo se změnit role a vlastníci objektů. Při první instalaci vznikne `config.php`, účet administrátora a jeho domovský adresář. Po úspěchu vzniknou stavové soubory. Stáhnou se připnuté image a vzniknou kontejnery.
7. Destruktivní a nevratné operace.

> Riziko. `rsync -a --delete` maže v cílových adresářích `compose/` a `configs/` soubory, které v Gitu už nejsou. Když rsync selže, skript neskočí na `cp`. Když rsync v systému není, adresářový cíl se smaže přes `rm -rf` a zkopíruje se `cp -a`. Prázdný zdrojový adresář se odmítne, aby `--delete` nevyprázdnil cíl.

> Riziko. Když je OID 10 stále role `PG_USER`, deploy provede `DROP ROLE IF EXISTS nc_bootstrap` a roli přejmenuje. Maže se jen role, která není initdb superuživatel. Řádky a soubory datadiru tento krok nemaže.

> Riziko. Nedokončená instalace může přejmenovat adresář `NEXTCLOUD_DATA_HOST_DIR/<admin>` na `.incomplete-<uživatel>-<čas>` ve stejném datadiru. Stane se to jen když Nextcloud není nainstalovaný a účet v PostgreSQL neexistuje. Starší `.incomplete-*` se nemaže. Hotový administrátorský domov se nepřejmenuje. Když účet v databázi je a Nextcloud přesto nainstalovaný není, deploy nic nemaže a skončí.

`maintenance:install` se spustí jednou, až když port 9000 poslouchá a `occ` hlásí `installed: false`. Čeká se nejvýše 150 intervalů po 2 sekundách. Entrypoint image instalaci po vzniku `version.php` sám neopakuje. Deploy proto nenechává deset opakování entrypointu, která by z prvního domovského adresáře udělala trvalou překážku `createUser`.

Úspěch instalace vyžaduje `occ` s `installed: true` a `versionstring` shodným s tagem, `installed => true` v `config.php`, `datadirectory` `/var/www/html/data`, účet v PostgreSQL, existující domovský adresář, zdravý cron a `status.php` s `"installed":true` a `"maintenance":false`. Pak se zapíší trusted domains a spustí hook `10-apcu.sh`.

8. Chyby. Neplatné `.env`, zámek upgradu, jiný tag, nečitelný nebo vícenásobný `PG_VERSION`, jiný major PostgreSQL, chybějící mount, špatný vlastník neprázdného adresáře, síť s jiným subnetem, Dockge neběží nebo má jiný `DOCKGE_STACKS_DIR`, PostgreSQL není healthy, `maintenance:install` selže, cron není healthy. Při selhání instalace se stavové soubory nezapíšou. Datové adresáře se jako celek nemažou.
9. Výstup. Sekce pro synchronizaci, verzi, úložiště, síť, runtime, Dockge a start. Závěr `Deployment completed.` Hesla se do logu skriptu nezapisují. `docker inspect` u kontejnerů Nextcloudu a Redisu heslo z prostředí uvidí. To `docs/security.md` uvádí jako hranici návrhu.
10. Další krok. `./scripts/post-deploy.sh` a `./scripts/test.sh`. Opakovaný deploy stejné verze je dovolený.

`deploy_wait_dockge` po startu čeká až 30 sekund, než `dockge` běží. Když se v okně neobjeví, deploy skončí chybou. Před startem Compose už `deploy_dockge` běh Dockge vyžaduje, takže druhé čekání pokrývá pád během deploye.

## 15. post-deploy.sh

1. Účel. Počkat na healthchecky a zapsat stav, teprve když běžící instance souhlasí s pinem.
2. Kdy. Po `deploy.sh`. `reload.sh` ho volá sám.
3. Spuštění. `./scripts/post-deploy.sh` jako root. Potřebuje `curl`.
4. Parametry. Žádné. Čte `.env` a běžící kontejnery.
5. Závislosti. `post_deploy_checks`, `occ`, `state_write_installed`, `findmnt` se tu přímo nevolá. Čekání je 24 pokusů po 15 sekundách, pokud test nepřepíše `POST_DEPLOY_HEALTH_ATTEMPTS` a `POST_DEPLOY_HEALTH_DELAY`.
6. Mění. Jen `installed-version` a `postgres-major`, a jen po všech kontrolách. Selhání předchozí soubory ponechá.
7. Destruktivní operace. Stavové soubory se přepíšou novou hodnotou pinu. Jiné datové stromy nemění.
8. Chyby. Zámek upgradu, kontejner neběží, health není `healthy`, image nesouhlasí, `occ` nehlásí instalaci, `versionstring` se liší, `needsDbUpgrade` není false, maintenance není false, `memcache.local` neobsahuje APCu, `status.php` není dosažitelný nebo hlásí údržbu či nutnost upgradu, port Nginxu není navázaný na bind adresu, je publikovaný port 5432, 6379 nebo 9000, major PostgreSQL v procesu, v image a v `PG_VERSION` se rozcházejí.
9. Výstup. `Post deployment completed.` a nápověda na `./scripts/test.sh`.
10. Další krok. `./scripts/test.sh`. Nedokončená první instalace stav nedostane. Nejdřív musí doběhnout instalace.

## 16. test.sh a shellcheck.sh

### 16.1 test.sh

1. Účel. Ověřit buď checkout, nebo nasazený stack.
2. Kdy. `--static` kdykoli na checkoutu. Bez argumentu po nasazení, v kontejneru.
3. Spuštění. `./scripts/test.sh` nebo `./scripts/test.sh --static`.
4. Parametry. `--static` nevolá `check_environment`. Nepotřebuje root a nezapisuje do `/docker-data`. Runtime režim root, Docker, Dockge a běžící stack vyžaduje. Proměnná `RESTORE_SKIP_USER_DATA=yes` se nastavuje jen ve statickém režimu, aby testy obnovy nehrály uživatelská data.
5. Závislosti. Runtime: `test_project`, `test_stack`, `test_environment`, `test_compose`, `test_docker`, `test_dockge`, `test_networks`, `test_backend_security`. Staticky: rozložení repozitáře, šablona `.env`, odmítnutí `set_*`, vazby portů, pojistky synchronizace, módy skriptů, matice PHP, záloha a obnova. Statický režim načítá i knihovny upgradu a zálohy.
6. Mění. Statické testy používají `mktemp`. Runtime testy mají číst a kontejnery nespouštět. `test_project` kontroluje `DEPLOY_ITEMS` v `GIT_DIR`. `test_stack` kontroluje stack. `test_environment` volá `env_validate`. `test_compose` spustí `docker compose config`. `test_networks` vyžaduje existující síť `nextcloud-gr`. `test_backend_security` vyžaduje publikovaný port na bind adrese a zakazuje publikování 5432, 6379 a 9000.
7. Destruktivní operace. Vstupní skript data nemaže. Statické testy zálohy pracují v dočasném adresáři. Jejich plný průběh na této revizi neproběhl, protože běh skončil na šabloně `.env`.
8. Chyby. První selhání díky `set -e` běh ukončí. Ověřené selhání této revize je popsané v kapitole 7.
9. Výstup. Sekce a `[ OK ]`, nebo `[FAIL]`.
10. Další krok. Po runtime úspěchu je stack podle těchto kontrol připravený k použití. Veřejný TLS pořád závisí na Traefiku mimo tento repozitář.

### 16.2 shellcheck.sh

Spouští `shellcheck -x -e SC1091 -e SC2034` na všechny `scripts/**/*.sh`. Root nevyžaduje. ShellCheck na tomto stroji při psaní manuálu nebyl spouštěn. Návratový kód tedy není ověřený. Skript nic nezapisuje.

## 17. reload.sh

1. Účel. Zopakovat deploy a poté kontejnery znovu vytvořit i když se Compose soubor nezměnil.
2. Kdy. Obnova kontejnerů ze stejného pinu. Změna verze sem nepatří, protože vnitřní `deploy.sh` jiný tag odmítne.
3. Spuštění. `./scripts/reload.sh` nebo `./scripts/reload.sh --pull`.
4. Parametry. `--pull` jen vypíše, že stahování už dělá deploy. Žádné další proměnné.
5. Závislosti. `deploy.sh`, `compose_reload`, `post-deploy.sh`, `test.sh`. `compose_reload` je `docker compose up -d --force-recreate --remove-orphans` v `STACK_DIR`.
6. Mění. Vše, co změní `deploy.sh`, a navíc nové kontejnery. `--remove-orphans` odstraní služby, které v Compose projektu už nejsou. Data v `DATA_DIR` komentář skriptu výslovně nemaže.
7. Destruktivní operace. Nové kontejnery nahradí staré. Služba, která z Compose zmizela, se jako kontejner projektu odstraní. Trvalé svazky hostitele tímto příkazem skript nemaže. Platí pojistky deploye, včetně přejmenování osiřelého domova administrátora.
8. Chyby. Cokoli, čím skončí deploy, post-deploy nebo test. Částečný úspěch je možný: když deploy projde a pád nastane až při recreate, stack už deploy změnil. Transakce přes všechny čtyři kroky v kódu není.
9. Výstup. Hlášky deploye, `Containers recreated.` a výsledek post-deploy a testů. Závěr `Reload finished.`
10. Další krok. Podle výstupu testu. Samostatný `post-deploy.sh` už reload volá sám.

## 18. upgrade.sh

1. Účel. Vyměnit obraz Nextcloudu o povolený krok. `deploy.sh` to nedělá.
2. Kdy. Po změně `NEXTCLOUD_TAG` v Gitu, `update-env.sh` a `check-env.sh`.
3. Spuštění.

```bash
./scripts/upgrade.sh --target X.Y.Z-fpm --confirm nextcloud-gr
```

Cíl musí být shodný s `NEXTCLOUD_TAG` v runtime `.env`. `--confirm` musí být přesně `nextcloud-gr`.

4. Parametry. Povinné `--target` a `--confirm`. `UPGRADE_MIN_FREE_MB` z `.env`. Potřebuje `curl` a `flock` v `PATH`. `flock` se v přečteném těle `upgrade.sh` po `require_command flock` dál nevolá. Zámku souboru přes `flock` tedy tento skript nevyužívá. Stav drží `upgrade.lock`.
5. Závislosti. `upgrade_step_allowed`, `deploy_postgres_major_decision`, `docker pull`, `docker run --rm --entrypoint php` pro `PHP_VERSION`, `upgrade_php_is_supported`, `upgrade_run_sequence`, a ta volá `backup.sh --hold`.
6. Mění. Stáhne cílový image. Zapíše zámek. Zastaví cron. Vytvoří zálohu. Znovu vytvoří jen službu `nextcloud` bez závislostí (`--no-deps --force-recreate`). Po ověření stejně znovu vytvoří cron. Vypne maintenance. Přepíše `installed-version` a smaže zámek. Hlavní verzi PostgreSQL nemění. Když není rozhodnutí `unchanged`, upgrade skončí dřív.
7. Destruktivní operace.

> Riziko. Záloha s `--hold` nechá po úspěchu zapnutou maintenance a zastavený cron. To je záměr, aby během výměny image nikdo nezapisoval. Selhání zálohy cron a maintenance vrací, protože obsluha `EXIT` v `backup.sh` při neúspěchu klidový režim ruší.

> Riziko. Po rekreaci kontejneru může entrypoint migrovat databázi. Když ověření selže, skript starý image nespustí. Částečně migrovaná databáze se starým kódem nesmí naběhnout. Zámek zůstane. `deploy.sh` ho nepřeskočí.

Aplikace třetích stran: zapnuté custom aplikace bez čitelného `max-version`, nebo s major nižším než cíl, upgrade zastaví ještě před výměnou image. Zabudované aplikace se posuzují z image, ne ze starého stromu. Skript nerozlišuje, jestli image stihl změnit schéma.

8. Chyby. Cíl se liší od `.env`. Chybí `installed-version`. Krok verze není povolený. Neznámá matice PHP nebo PHP mimo ni. Málo místa na datech, databázi nebo zálohách. Některý z pěti kontejnerů neběží. PostgreSQL není healthy. Zámek už existuje. `occ app:list` selže. Záloha selže. Do 120 pokusů po 15 sekundách `occ` nesouhlasí, PostgreSQL není healthy, nebo `status.php` nehlásí instalaci bez `needsDbUpgrade`.
9. Výstup. Při úspěchu `Upgrade to <tag> completed.` Při chybě zámek obsahuje `failed`, zdrojový a cílový tag a větu, že se předchozí image nemá spouštět.
10. Další krok. Po úspěchu zkontrolovat aplikace a klienty. Po chybě obnova podle kapitoly 21 ze zálohy vytvořené s `--hold`. Zámek smazat až po obnově nebo po vědomém rozhodnutí. To je provozní pravidlo z `docs/upgrade.md` a z textu, který skript do zámku zapisuje.

Volné místo se měří `df -Pm` a porovnává s `UPGRADE_MIN_FREE_MB`. Šablona chce 5120 MiB na každém ze tří filesystémů.

## 19. backup.sh

1. Účel. Jeden obnovitelný bod: dump PostgreSQL, malé stromy Nextcloudu a restic snapshot uživatelských dat pořízený ve stejném okně.
2. Kdy. Ručně před rizikovou změnou a automaticky z `upgrade.sh --hold`.
3. Spuštění. `./scripts/backup.sh` nebo `./scripts/backup.sh --hold` jako root.
4. Parametry. `BACKUP_AGE_RECIPIENT` musí být veřejný příjemce. Prázdný příjemce zálohu nenechá. `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, retence `RESTIC_KEEP_*`, volitelně `BACKUP_EXTERNAL_DIR`. Programy `age` a `restic` musejí být v `PATH`.
5. Závislosti. `backup_quiesce_writers`, `backup_dump_postgresql`, kopie stromů, `occ app:list`, restic, manifest, `backup_store_encrypted_stage`, `restic forget`.
6. Mění. Zastaví cron, pokud běžel. Zapne maintenance. Vytvoří dočasný stage s módem `700` a soubory `600`. Zapíše archiv `nextcloud-gr-<UTC razítko>.tar.gz.age` a soubor `.sha256`. Může založit restic repozitář příkazem `restic init`, když `snapshots` selže. Může na externí mount vytvořit adresář `restic` s módem `700` a spustit `restic copy`. Nový snapshot má tagy `nextcloud-gr` a `backup-<razítko>`.
7. Destruktivní operace.

> Riziko. `restic forget` ve zdrojovém repozitáři maže snapshoty mimo retenci. Nový snapshot drží `--keep-tag backup-<razítko>`, aby ho forget hned nesmazal. Selhání forgetu je varování. Nový snapshot zůstane a skript kvůli tomu sám neskončí chybou, pokud ostatní kroky prošly.

Uživatelské soubory v age archivu nejsou. Archiv obsahuje `postgresql/nextcloud.dump` (`pg_dump -Fc --no-owner --no-acl`), `nextcloud/config`, `custom_apps`, `themes`, `app-list.txt`, `stack.env` a `manifest.txt`. `stack.env` je kopie runtime `.env`, tedy obsahuje hesla. K přečtení je potřeba privátní age klíč, který do archivu nepatří.

Dump, který není custom formát PostgreSQL, se nearchivuje. Hlavní verze serveru se čte příkazem `SHOW server_version` a musí být `18`.

Pořadí klidového režimu: nejdřív cron, potom maintenance. PostgreSQL běží dál, aby šel udělat dump. Když cron před zálohou neběžel, záloha ho na konci nespustí.

8. Chyby. Neplatné `.env`, chybí adresáře `config`, `custom_apps`, `themes` nebo datadir, PostgreSQL není healthy, age chybí, restic nevrátí čitelné id, snapshot nejde ověřit, externí cesta není mountpoint, kopie na jiné zařízení nedá ověřené id. Neúspěšný archiv se maže. Dočasný stage se maže v `EXIT`. Signály TERM, INT a HUP končí kódy 143, 130 a 129. Když se po úspěšném archivu nepodaří vrátit maintenance nebo cron, návrat je 1 a archiv už na disku je.
9. Výstup. `Complete external backup` když je restic vzdálený, nebo když je lokální a snapshot byl ověřený na jiném zařízení. Jinak varování, že jde jen o lokální bod obnovy. Lokální restic na stejném disku jako data není záloha proti ztrátě disku. Stejné zařízení u `BACKUP_EXTERNAL_DIR` a datadiru se jako oddělené úložiště nepočítá. Archiv se v tom případě jako kompletní externí záloha neoznačí.

Vzdálené schéma (`sftp`, `rest`, `s3`, `rclone`, `azure`, `gs`, `b2`, `swift`) se bere jako externí kopie uživatelských dat. Age archiv s dumpem na tom vzdáleném repozitáři není. Když je zároveň `BACKUP_EXTERNAL_DIR`, archiv se na ten mount zkopíruje. Když není, skript varuje, že dump zůstává lokálně.

`created_at` v manifestu je čas před spuštěním resticu, ne čas snapshotu. Pole `restic_snapshot_id` a volitelně `restic_external_snapshot_id` drží id. Manifest také obsahuje sha256 souborů stage.

10. Další krok. Privátní age klíč a další kopii `RESTIC_PASSWORD` uložit mimo zálohovaný disk. Ověřit obnovu nejdřív bez `--replace-data`.

`--hold` po úspěchu maintenance a cron nevrací. To používá upgrade. Příznak `BACKUP_QUIESCE_HOLD_READY` se nastaví až po dokončení archivu.

## 20. restore.sh

1. Účel. Ověřit archiv a volitelně jím přepsat tuto instanci.
2. Kdy. Nácvik obnovy, nebo návrat po chybě upgradu či poškození dat.
3. Spuštění. Jako root.

```bash
./scripts/restore.sh \
  --archive /docker-data/backups/nextcloud-gr/nextcloud-gr-CAS.tar.gz.age \
  --identity /cesta/mimo/git/age.key \
  --confirm nextcloud-gr
```

Přepis:

```bash
./scripts/restore.sh \
  --archive /docker-data/backups/nextcloud-gr/nextcloud-gr-CAS.tar.gz.age \
  --identity /cesta/mimo/git/age.key \
  --confirm nextcloud-gr \
  --replace-data
```

`CAS` v příkladu nahraďte skutečným razítkem souboru. Skript sám nejnovější archiv nehledá.

4. Parametry. Povinné `--archive`, `--identity` a `--confirm` s hodnotou `nextcloud-gr`. Identita musí mít mód `600` nebo `400`. `--allow-version-mismatch` dovolí jiný tag Nextcloudu. Jiný major PostgreSQL v manifestu než `18` zůstane odmítnutý. MariaDB dump zůstane odmítnutý.
5. Závislosti. `age`, při přepisu také Docker, zdravý PostgreSQL, restic a knihovna `backup/apply.sh`. Dešifrování čte identitu tak, aby nebyla argumentem procesu. Přesná podoba příkazu `age -d` je v `backup_decrypt_file`. Tento manuál příkaz znovu nesestavuje do provozního návodu.
6. Mění. Bez `--replace-data` se živá data nezmění. Dočasný dešifrovaný strom se na konci maže. S `--replace-data` se přepíšou `config`, `custom_apps` a `themes`, v `.env` jen `NEXTCLOUD_ADMIN_PASSWORD`, databáze přes `pg_restore --clean --if-exists --no-owner --no-acl --single-transaction` a datadir přes restic. `PG_PASS`, `REDIS_PASSWORD` a `RESTIC_PASSWORD` se z archivu neberou. Účinné heslo účtu je v obnovené databázi. Před přepisem vznikne rollback v `BACKUP_LOCAL_DIR/rollback.*`. Po ověřeném úspěchu ho skript smaže. Když smazání selže, úspěch se nehlásí.
7. Destruktivní operace.

> Riziko. `--replace-data` přepíše konfiguraci, aplikace, motivy, databázi a uživatelská data. `pg_restore --clean` zahazuje objekty, které v dumpu jsou, a znovu je vytváří. Restic u adresáře, který není mountpoint, obnoví vedlejší adresář a pak ho přejmenuje. Mountpoint přejmenovat nejde. Proto validace chce adresář uvnitř disku. Obnova do mountpointu by byla na místě a bez výměny adresáře.

> Riziko. Před `--replace-data` musejí být zastavené `nextcloud-gr-app` a `nextcloud-gr-cron`. PostgreSQL musí běžet a být healthy. Skript je sám nezastavuje. Když po začátku přepisu obnova selže, vrátí soubory, heslo administrátora v `.env` a dump. Když selže i návrat, vypíše cestu ke snímku a nesmí hlásit úspěch. Nextcloud se v tom stavu nemá spouštět.

Výběr snapshotu: ověří se id `restic_snapshot_id` a případně `restic_external_snapshot_id` v repozitáři z `RESTIC_REPOSITORY`. Použije se jen id, které projde kontrolou v nakonfigurovaném repozitáři. Když jsou v jednom repozitáři obě a výběr je nejednoznačný, skript skončí a nic nevybere. Starší manifest bez externího id a bez stromu, času a hostname se nedohledává přes nejnovější snapshot. `created_at` se k hledání nepoužívá. Když by manifest přece jen obsahoval strom, přesný čas a hostname, smí se použít jen jediná shoda. Dnešní archiv tato tři pole nezapisuje. Tahle větev se ho netýká. To je chování `restore.sh` a shoduje se s `docs/backup-restore.md`.

8. Chyby. Špatné `--confirm`, nečitelná identita, dešifrování, špatné módy, manifest, verze, major, nečitelný snapshot. Návrat 2 znamená ověřený archiv bez zápisu. Návrat 1 je chyba. Signály mají stejné kódy jako záloha.
9. Výstup. Bez přepisu varování a kód 2. S přepisem věta, že heslo administrátora bylo obnoveno a tři provozní hesla zůstala. Připomínka spustit stack jen s tagem z manifestu a spustit `occ files:scan`. Samotný `restore.sh` `files:scan` nespouští.
10. Další krok. Spustit stack stejným tagem, pak v kontejneru `nextcloud-gr-app` jako `www-data` scan souborů. Přesné příkazy scanu jsou v `docs/migration-from-current.md` jako `php occ files:scan --all`. V úspěšné hlášce `restore.sh` je jen obecná věta `occ files:scan`. Rollback adresář po úspěchu skript maže. Když ho nestihne smazat, nebo když obnova selhala a snímek zůstal, mažte ho až po kontrole, že instance naběhla. To doporučuje `docs/backup-restore.md`.

`chown -R 33:33` se při přepisu jako root aplikuje na obnovené `config`, `custom_apps` a `themes`. Na celý datadir uživatelských souborů tenhle `chown` v `restore_replace_files` není.

## 21. reset-test.sh a record-installed.sh

### 21.1 reset-test.sh

1. Účel. Vyprázdnit testovací instanci, aby další `deploy.sh` mohl instalovat znovu.
2. Kdy. Jen u testovací instance. Do běžného deploye nepatří.
3. Spuštění.

```bash
./scripts/reset-test.sh --confirm nextcloud-gr
```

Jiný tvar, včetně chybějícího argumentu, skončí dřív a nic nesmaže.

4. Parametry. `--confirm` musí být přesně `nextcloud-gr`. Cesty bere z runtime `.env` a z `config.sh`.
5. Závislosti. Docker, mount, `reset_test_instance`.
6. Mění. Zastaví stack a smaže potomky čtyř adresářů. Rodiče ponechá.
7. Destruktivní operace.

> Riziko. Maže se obsah `NEXTCLOUD_HTML_HOST_DIR` (kód a `config.php`), `/docker-data/nextcloud-gr/state`, `NEXTCLOUD_DATA_HOST_DIR` a `POSTGRESQL_HOST_DIR`. Každý adresář musí existovat, nesmí to být mountpoint a musí ležet uvnitř jiného mountu. Když kontejner existuje, jeho mount na tom místě musí ukazovat na stejnou cestu. Mazání je `rm -rf` na potomky, včetně skrytých jmen.

Ponechá `.env`, `/docker-data/backups/nextcloud-gr`, Dockge, síť `nextcloud-gr` a `runtime/redis.conf`. Redis datový svazek nemá.

8. Chyby. Špatné potvrzení, adresář je mountpoint, mount kontejneru nesedí, cesty splývají se zakázaným stromem. V tom případě k mazání daného adresáře nedojde.
9. Výstup. `Test reset completed.` a další krok `./scripts/deploy.sh`.
10. Další krok. `./scripts/deploy.sh` a `./scripts/post-deploy.sh`.

### 21.2 record-installed.sh

1. Účel. Zapsat `installed-version` a `postgres-major` u instalace, která už má `config.php`, bez zbytku `deploy.sh`.
2. Kdy. Když správce nechce pouštět synchronizaci, síť a render. `deploy.sh` umí stejnou evidenci zapsat sám, když kód, `occ` a PostgreSQL souhlasí s pinem.
3. Spuštění. `./scripts/record-installed.sh --confirm nextcloud-gr`
4. Parametry. `--confirm` je povinné a musí být `nextcloud-gr`. `.env` se validuje.
5. Závislosti. `record_installed_run`, `occ`, post-deploy kontroly, `curl`.
6. Mění. Může spustit připnuté image, když kontejnery neběží a `version.php` i `PG_VERSION` už pinu odpovídají. Jiný tag nebo jiný major nespustí. Stav zapíšou post-deploy kontroly až po shodě.
7. Destruktivní operace. Přepis stavových souborů. Datadir a cluster nemaže. Hesla nerotuje.
8. Chyby. Chybí `--confirm`, neplatné `.env`, verze nejde přečíst, víc souborů `PG_VERSION`, nečitelný cluster, zámek, neshoda obrazu nebo `occ`. Evidence se nezapíše a existující se nepřepíše.
9. Výstup. `Installed version recorded.`
10. Další krok. `./scripts/post-deploy.sh`, pokud ještě neproběhl uvnitř tohoto příkazu. Skript post-deploy kontroly používá pro zápis. Samostatný health přehled po něm dává smysl, když se mají znovu vidět stejné kontroly.

Přesná rozhodovací tabulka je ve funkci `record_installed_from_facts`. Tento manuál ji neopisuje větev po větvi. Směrodatné je, že verzi nehádá.

## 22. Provozní postupy

Postupy používají jen argumenty, které skripty mají. Cílové cesty `/incus-dir` a `/docker-data` na stroji tohoto manuálu nejsou. Příkazy jsou určené pro root v Incus kontejneru poté, co správce mimo tento repozitář připojí disky a nainstaluje Docker a Dockge.

### 22.1 Před první inicializací

V kontejneru mají být vidět mounty. Dokument `docs/operations.md` doporučuje:

```bash
findmnt /docker-data
findmnt -T /cesta/k/rodici/postgresql
findmnt -T /cesta/k/rodici/nextcloud-data
```

`/cesta/k/rodici` je popis z dokumentace, ne argument skriptu. Skutečné cesty se zapíšou do `.env`. `/docker-data` musí být mountpoint. Rodič PostgreSQL a rodič datadiru musí být na jiném než kořenovém filesystému. Listový adresář nesmí být sám mountpoint.

Doporučené rozdělení disků je v `docs/operations.md`: `/docker-data` na SSD nebo NVMe, PostgreSQL na rychlém disku, nový datadir na HDD RAID, starý zdroj jen pro čtení a jen po dobu kopie. To je provozní doporučení dokumentu, ne kontrola, kterou by `init.sh` uměl vynutit nad rámec mountpointu.

### 22.2 První inicializace

```bash
./scripts/init.sh
```

Vytvoří adresáře na `/docker-data` a zkopíruje Compose a konfiguraci do `/docker-data/stacks/nextcloud-gr`. Síť Dockeru nevytvoří. Hesla nezapisuje.

### 22.3 Doplnění a kontrola .env

```bash
./scripts/update-env.sh
```

Skript založí `/docker-data/stacks/nextcloud-gr/.env` a vygeneruje hesla, která jsou ještě `set_*`. Do terminálu je nevypíše. Správce potom v souboru nahradí zbylé zástupné a provozní hodnoty. Musejí přestat začínat na `set_`. Typicky jde o bind adresu, `TRUSTED_PROXIES`, subnet, bránu, cesty PostgreSQL a datadiru, jméno administrátora, restic repozitář a veřejného age příjemce, pokud mají v daném souboru pořád prefix `set_`.

V aktuální šabloně už řada těchto polí prefix nemá. `update-env.sh` user hodnoty ze šablony převezme, když v `.env` ještě nejsou. `check-env.sh` je pak posoudí jako runtime. Konkrétní adresy ze šablony tedy mohou kontrolou projít, i když statický test šablony selhává. Zda nekolidují s LAN, WireGuardem a Incusem, musí rozhodnout správce. Skript kolizi s těmi sítěmi neměří.

```bash
./scripts/check-env.sh
```

Soubor nemění. Úspěch je `Environment configuration OK.`

Hesla `PG_PASS`, `REDIS_PASSWORD`, `NEXTCLOUD_ADMIN_PASSWORD` a `RESTIC_PASSWORD` se z logu neopisují. Další kopie `RESTIC_PASSWORD` má být offline. Veřejný `BACKUP_AGE_RECIPIENT` do `.env` patří. Privátní `AGE-SECRET-KEY` do `.env` nepatří.

SMTP se nastaví buď v `.env`, nebo později v rozhraní Nextcloudu. Komentář šablony říká, že dokud jsou proměnné nastavené, image nastavení v UI přepíše.

### 22.4 Nasazení

```bash
./scripts/deploy.sh
```

Srovná stack, odmítne cizí verzi, připraví disky, vytvoří síť, zapíše runtime soubory, ověří Dockge a spustí služby v pořadí z kapitoly 4.6. První instalace nemá `config.php` ani `installed-version`. Deploy ji smí založit. Instance s `installed => true` a bez evidence se znovu neinstaluje.

### 22.5 Kontrola po nasazení

```bash
./scripts/post-deploy.sh
./scripts/test.sh
```

Post-deploy zapíše stav až když health, `occ`, APCu, `status.php` a nepublikované porty databází souhlasí. Test v runtime režimu znovu projde projekt, stack, `.env`, Compose, Docker, Dockge, síť a vazbu portu.

Veřejné URL pro klienty je `https://gregor.serveftp.org`. Desktop, mobil, WebDAV, CalDAV a CardDAV používají tuto doménu. Plošný Authentik ForwardAuth se podle `docs/operations.md` a `docs/traefik-integration.md` na doménu nezapíná. V tomto repozitáři ForwardAuth není.

### 22.6 Aktualizace beze změny verze

```bash
./scripts/update-env.sh
./scripts/check-env.sh
./scripts/deploy.sh
```

Když se v šabloně změnil `NEXTCLOUD_TAG`, `update-env.sh` ho přenese a `deploy.sh` skončí chybou s odkazem na `upgrade.sh`. Opakovaný deploy stejného tagu je způsob, jak nasadit změnu Nginxu nebo limitů.

```bash
./scripts/reload.sh
```

Udělá deploy a ještě `--force-recreate --remove-orphans`, potom post-deploy a test.

### 22.7 Upgrade verze

1. V Gitu změnit `NEXTCLOUD_TAG` na přesný `X.Y.Z-fpm`.
2. `./scripts/update-env.sh`
3. `./scripts/check-env.sh`
4. `./scripts/upgrade.sh --target X.Y.Z-fpm --confirm nextcloud-gr`

Cíl a pin v `.env` musejí být stejné. Z `35.0.2-fpm` kód dovolí novější `35.x.y-fpm` nebo hlavní verzi 36, ale matice PHP verzi 36 nezná, takže ji `upgrade.sh` odmítne, dokud se `scripts/lib/upgrade/php.sh` nerozšíří.

### 22.8 Záloha

```bash
./scripts/backup.sh
```

Nejdřív zastaví cron a zapne maintenance. Po úspěchu je vrátí, pokud nebyl použit `--hold`. Výsledek je age archiv v `/docker-data/backups/nextcloud-gr` a restic snapshot. Kompletní externí záloha vyžaduje čitelný snapshot na odděleném úložišti a age archiv. Samotný `.tar.gz.age` uživatelské soubory neobsahuje.

### 22.9 Obnova

Nejdřív ověření:

```bash
./scripts/restore.sh \
  --archive /docker-data/backups/nextcloud-gr/nextcloud-gr-CAS.tar.gz.age \
  --identity /cesta/mimo/git/age.key \
  --confirm nextcloud-gr
```

Návrat 2 a věta, že se data nezměnila, znamená ověřený archiv.

Přepis až po zastavení `nextcloud-gr-app` a `nextcloud-gr-cron`, s běžícím healthy PostgreSQL:

```bash
./scripts/restore.sh \
  --archive /docker-data/backups/nextcloud-gr/nextcloud-gr-CAS.tar.gz.age \
  --identity /cesta/mimo/git/age.key \
  --confirm nextcloud-gr \
  --replace-data
```

Po úspěchu scan souborů skript sám nespustí. Má se spustit v kontejneru aplikace, až stack běží s tagem z manifestu. Dokument migrace uvádí:

```bash
php occ files:scan --all
```

jako uživatel `www-data`. Přesná obálka `docker exec` v `restore.sh` není. Knihovna `nextcloud_occ` používá:

```bash
docker exec -u www-data nextcloud-gr-app php occ
```

Doplnění `--all` je tedy provozní příkaz složený z této obálky a z dokumentu migrace. `restore.sh` ho nevolá.

### 22.10 Časté chyby

| Hláška nebo stav | Co kód dělá |
| --- | --- |
| `Example value for … is not a placeholder` | statický test šablony; runtime `.env` to samo nezmění |
| `Placeholder is not usable in production` | v `.env` zůstalo `set_*` |
| `Installed Nextcloud tag is … deploy.sh will not upgrade` | tag se liší od `installed-version`; patří sem `upgrade.sh` |
| `Upgrade lock already exists` nebo text zámku | `deploy.sh` ani další upgrade nepokračují, dokud se zámek neodstraní po rozhodnutí |
| `DOCKER network … already uses` | existující síť má jiný subnet nebo bránu; deploy ji nepřepisuje |
| `Dockge is not running` | projekt Dockge neinstaluje |
| `/docker-data is not a mountpoint` | init ani deploy adresář na kořenovém disku nevytvoří |
| `PostgreSQL did not become healthy` | Nextcloud se nespustí, datadir se nemaže |
| `Login is invalid because files already exist for this user` | v datadiru už je adresář se jménem administrátora; deploy ho přejmenuje jen když účet v databázi není |
| `maintenance:install failed` | stav se nezapíše, datové adresáře se nemažou |
| `occ status installed is false` u post-deploy | instalace ještě neskončila |
| `Restic repository … does not contain a verified snapshot` | obnova nic nepřepíše |
| návrat 2 u `restore.sh` | archiv je ověřený, přepis vyžaduje `--replace-data` |
| `Refusing reset` | chybí přesné `--confirm nextcloud-gr` |

Log kontejneru `nextcloud-gr-app` je zdroj hlášky entrypointu. Skripty do něj hesla nepřidávají. `docker logs` může ukázat to, co do stdout zapíše samotný image.

## 23. Bezpečnost

Ověřené vlastnosti Compose a validace:

- Porty 5432, 6379 a 9000 nemají `ports`.
- Nginx se váže na adresu z `.env`. `0.0.0.0` a loopback validace odmítá.
- Docker socket se v Compose nemountuje.
- Redis má heslo v souboru, ne v `command`. Politika je `noeviction`.
- `no-new-privileges` je u všech pěti služeb. Oficiální image Nextcloudu a PostgreSQL startují jako root a klesnou na svého uživatele. Komentář bezpečnosti říká, že `no-new-privileges` ten pokles dovoluje.
- Runtime `.env` má mód `600`.

`stack.env` uvnitř age archivu hesla obsahuje. Bez privátního age klíče uloženého jinde archiv neotevřete. `RESTIC_PASSWORD` otevírá zdrojový i externí restic repozitář. Heslo v `.env` na stejném disku jako data po ztrátě toho disku k repozitáři nestačí.

Obnova tří věcí, které nemají zůstat jen na zálohovaném disku: age archiv, privátní age klíč a `RESTIC_PASSWORD`. To je závěr shodný s `docs/backup-restore.md` a s tím, co archiv skutečně obsahuje.

MariaDB adresář ze staré instalace validace odmítne jako `POSTGRESQL_HOST_DIR` i jako `NEXTCLOUD_DATA_HOST_DIR`.

## 24. Rozpory dokumentace a kódu

Směrodatný je kód revize `519b4f4`. Dokumentace se má číst s těmito rozdíly.

| Místo | Text dokumentace nebo komentáře | Kód nebo soubor |
| --- | --- | --- |
| `docs/architecture.md` | bind je zástupce `set_backend_bind_address` | `.env.example` má `192.168.12.232`; řetězec `set_backend_bind_address` v šabloně není |
| `compose/00-networks.yml` | šablona obsahuje jen zástupné hodnoty a `192.168.12.0/24` se má vyhnout | šablona má konkrétní subnet i bind uvnitř uvedeného LAN rozsahu |
| `docs/security.md` | `runtime/redis.conf` má mód `600` | `render_redis_conf` nastavuje `644`; adresář `runtime` má `700` |
| nápověda `check-env.sh` | projektová hodnota `BACKUP_EXTERNAL_DIR` je `/backups` | šablona je prázdná; konstanta záloh je `/docker-data/backups/nextcloud-gr` |
| `lib/env/writer.sh` | komentář zmiňuje `AUTHENTIK_SECRET_KEY` | v `ENV_POLICY` takový klíč není |
| `lib/docker-compose.sh` | příklady s Prometheus | v Compose Prometheus není a funkce `compose_down` ani `compose_logs` nemají volajícího |
| `lib/checks/docker.sh` | komentář o certifikátech Traefiku | `docker_http_headers` nemá volajícího; TLS v tomto Nginxu není |
| `docs/operations.md` | reset uvádí příklady `/nextcloud-data/data` a `/postgresql-data/data` | to jsou hodnoty aktuální šablony, ne natvrdo zapsané cesty v `reset-test.sh`; skript čte `.env` |

`README.md` a `docs/operations.md` v pořadí init, update-env, check-env, deploy, post-deploy a test s kódem souhlasí. Pojistka verze v `deploy.sh` s `docs/upgrade.md` souhlasí. Rozdělení age archivu a resticu s `docs/backup-restore.md` souhlasí v tom, co bylo v `backup.sh` a `restore.sh` přečteno.

## 25. Omezení a neověřené skutečnosti

- Nasazení, obnova, upgrade, reset a záloha nebyly spuštěny. Že služby běží, se netvrdí.
- Cesty `/docker-data`, `/incus-dir`, `/HDD`, `/SDD`, `/postgresql-data` a `/nextcloud-data` na stroji sestavení manuálu nejsou.
- `./scripts/test.sh --static` skončil na první kontrole šablony. Testy matice PHP, zálohy, obnovy, pojistek synchronizace a portů v tom běhu neproběhly. Jejich kód byl zčásti přečten, výsledek testu ne.
- `shellcheck.sh` nebyl spuštěn.
- WireGuard, LAN, Incus bridge a skutečná adresa Traefiku nebyly z tohoto checkoutu změřeny. Komentované rozsahy v `compose/00-networks.yml` jsou text, ne výstup `ip route`.
- Filesystém, vlastník uid a posun id neprivilegovaného Incusu ověřeny nebyly.
- Zda je Dockge v cílovém kontejneru nainstalovaný, ověřeno není. Kód ho vyžaduje a neinstaluje.
- Zda jsou na cíli programy `age`, `restic`, `openssl`, `findmnt`, `curl` a `flock`, ověřeno není.
- Chování oficiálního entrypointu Nextcloudu je převzaté z komentářů Compose, které odkazují na kontrolu 20. října 2026. Entrypoint image se v tomto úkolu znovu nestahoval.
- Funkce `record_installed_from_facts`, střed `lib/upgrade/version.sh` a velká část `scripts/lib/tests/backup.sh` nebyly řádek po řádku opsány do tohoto textu. Popis `record-installed.sh` proto zůstává na úrovni vstupu, pojistek a toho, že verzi nehádá.
- `backup_decrypt_file` nebyl do návodu rozepsán jako ruční příkaz `age`. Dešifrování má dělat `restore.sh`.
- CrowdSec v repozitáři není. Jeho přítomnost mimo repozitář je neověřená.
- Kolize subnetu `172.18.0.0/24` s jinými sítěmi cílového hostitele je neověřená. Validace kontroluje tvar a RFC1918, ne obsazenost.
- Ruční migrace souborů, kalendářů a kontaktů je postup v `docs/migration-from-current.md`. Žádný skript v `scripts/` ji nespouští. `rsync` uživatelských dat mimo `DEPLOY_ITEMS` projektový skript nedělá.
- Tento manuál provozní konfiguraci nemění a commit ani push neprovádí.

## 26. Co bylo při sestavení procházeno

Přečtené celé soubory: `README.md`, sedm dokumentů v `docs/`, `.env.example`, `.gitignore`, `compose.yml`, všech pět souborů v `compose/`, `configs/nginx/nginx.conf`, `configs/nextcloud/hooks/10-apcu.sh`, `scripts/config.sh` a vstupní skripty `init.sh`, `update-env.sh`, `check-env.sh`, `deploy.sh`, `post-deploy.sh`, `reload.sh`, `test.sh`, `shellcheck.sh`, `record-installed.sh`, `reset-test.sh`, `backup.sh`, `restore.sh`, `upgrade.sh`.

Přečtené knihovny, na kterých popis chování stojí: prostředí (`policy`, `validate`, `sync`, `generate`, `writer`, `helpers`, `constants`, `load`), init, mount, deploy stack, storage, render, version-guard, compose od čekání na PostgreSQL po `deploy_compose`, post-deploy checks, upgrade sequence a matice PHP, backup runtime, postgres dump, začátek restic, šifrování až po uložení archivu, obnova hesla a přepis stromů, Dockge, reset v rozsahu pojistek mazání, occ, logging, common, kontroly a runtime testy.

Historie Gitu byla použita jen jako kontext posledních commitů na `main`. Poslední je `519b4f4` s předmětem `/nextcloud-data/test`. Z předmětů je vidět řada oprav instalace, cronu, rolí PostgreSQL a cest v `.env`. Předměty samy o sobě chování nedokazují. Důkaz je aktuální text souborů.

Spuštěno bylo jen `./scripts/test.sh --static`. Skončilo chybou popsanou v kapitole 7. Jiný skript projektu se nespouštěl.
