# Nextcloud-Gr

Nextcloud 35.0.2 v existujícím Incus kontejneru na domácím serveru. Skripty se spouštějí uvnitř toho kontejneru jako root. Repozitář kontejner, WireGuard ani Dockge nevytváří.

Veřejné jméno je `gregor.serveftp.org`. HTTPS končí na Traefiku v Infrastructure-netcup. Tento stack publikuje jen Nginx na soukromé adrese a portu z runtime `.env`.

## Tři adresáře

```text
Git checkout
/incus-dir/git/Nextcloud-Gr
        |
        v
Runtime stack
/docker-data/stacks/nextcloud-gr
        |
        v
Persistentní data
/docker-data/nextcloud-gr
/cesta/z/.env pro PostgreSQL 18
/cesta/z/.env pro uživatelská data na HDD
```

Git obsahuje Compose, `configs/`, skripty a `.env.example`. Runtime stack je to, co čte Docker Compose a Dockge, plus `.env` s oprávněním `600`. Databáze, uživatelská data a zálohy nejsou v `DEPLOY_ITEMS`, takže je `rsync --delete` nesmaže.

## Služby

PostgreSQL 18.6, Redis 8.10.2, Nextcloud `35.0.2-fpm` (PHP 8.5), Nginx 1.30.6 a cron ze stejného Nextcloud image. Caddy ani Traefik v tomto Compose nejsou. Redis, PostgreSQL a PHP-FPM nemají publikovaný port.

## Pořadí v kontejneru

```bash
./scripts/init.sh
./scripts/update-env.sh
# doplnit set_* hodnoty v /docker-data/stacks/nextcloud-gr/.env
./scripts/check-env.sh
./scripts/deploy.sh
./scripts/post-deploy.sh
./scripts/test.sh
```

`./scripts/test.sh --static` ověřuje checkout bez Dockeru a bez zápisu do `/docker-data`.

`deploy.sh` nespustí jinou verzi Nextcloudu, než jaká je zapsaná v `/docker-data/nextcloud-gr/state/installed-version`. Změna tagu patří do `./scripts/upgrade.sh`. `config.php` s `installed => true` a bez tohoto souboru není první instalace. Ověření a doplnění evidence je `./scripts/record-installed.sh --confirm nextcloud-gr`.

Podrobnosti jsou v `docs/`.
