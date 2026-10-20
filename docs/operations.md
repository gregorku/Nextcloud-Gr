# Provoz

Příkazy patří do kontejneru `10.10.10.100` a spouštějí se jako root. Z pracovního checkoutu na stanici se nenasazuje.

## init.sh

Ověří root, `git` a `rsync`. Pak:

1. vytvoří `/docker-data/authentik-netcup` přes `mkdir -p` a mód `700` na tento adresář ani na jeho podstrom nenastaví. Adresář vlastní root. Průchod pro ostatní, který u rootu s `umask 022` dává `mkdir` jako mód `755`, potřebují PostgreSQL UID `70` a Authentik UID `1000`, aby se dostaly do svých podadresářů;
2. vytvoří `/docker-data/backups/authentik-netcup` a mód `700` nastaví jen jemu. Čte a zapisuje ho root při záloze;
3. zkopíruje `DEPLOY_ITEMS` do `/docker-data/stacks/authentik-netcup` a u každé položky nahradí předchozí obsah;
4. vytvoří Docker síť `authentik-netcup`, pokud chybí;
5. nastaví vlastníka `70:70` u `postgresql` a `1000:1000` u `authentik/data`, `authentik/templates` a `authentik/certs`. `chown` mód nadřazeného `/docker-data/authentik-netcup` nemění.

`.env` v tomto kroku nevzniká. Kontejnery se nespouštějí.

`rsync --delete` se při init nepoužívá. Mazání je `rm -rf` jen na cestě `STACK_DIR/<položka>`. Cesta se před smazáním musí vejít do stacku.

## update-env.sh

Čte `.env.example` už zkopírovaný ve stacku. Poprvé z něj vytvoří `.env`, potom ho sesynchronizuje.

| Politika | Chování |
| --- | --- |
| `framework` | hodnota z `.env.example` |
| `user` | neprázdná hodnota v `.env` zůstane |
| `generated` | skutečné tajemství zůstane; `set_*` nebo prázdná hodnota se jednou vygeneruje |

Generování odpovídá dokumentaci authentik: `openssl rand -base64 36` pro `PG_PASS` a `openssl rand -base64 60` pro `AUTHENTIK_SECRET_KEY`. Hodnota se nevypisuje. Existující klíč se při další synchronizaci nemění, protože jeho výměna ruší sessions.

Před zápisem vznikne `/docker-data/stacks/authentik-netcup/.env.bak-YYYYMMDD-HHMMSS`. Nový soubor se zapisuje přes `.env.tmp`. `.env` i záloha mají mód `600`. Proměnná, která v `.env.example` už není, do nového souboru neprojde.

`openssl` musí být v kontejneru. Bez něj `update-env.sh` tajemství nevytvoří.

## check-env.sh

Odmítne chybějící nebo neznámou proměnnou, placeholder `set_*`, heslo PostgreSQL delší než 99 znaků, krátký `AUTHENTIK_SECRET_KEY`, současně zapnuté `USE_TLS` a `USE_SSL`, `BACKUP_EXTERNAL_DIR`, který míří do Gitu, stacku, dat nebo lokálních záloh, a `BACKUP_AGE_RECIPIENT`, který je soukromý klíč age. Prázdný `BACKUP_EXTERNAL_DIR` a prázdný `BACKUP_AGE_RECIPIENT` validace přijme. V `.env.example` je cíl `/backups`. Prázdný příjemce znamená, že `backup.sh` archiv nezapíše. Prázdný cíl znamená, že kopie na hostitelský adresář nevznikne.

## deploy.sh

1. zkontroluje prostředí a Docker;
2. sesynchronizuje `DEPLOY_ITEMS`;
3. ověří, že položky existují v `GIT_DIR`;
4. ověří `.env`;
5. ověří, že kontejner `dockge` běží a `DOCKGE_STACKS_DIR` je `/docker-data/stacks`;
6. spustí `docker compose config`;
7. stáhne obrazy a provede `docker compose up -d`;
8. počká, až Dockge běží.

Krok 7 je jediné místo, které stahuje obrazy a startuje stack. Tento checkout ho nespouští.

`rsync --delete` platí jen pro obsah `compose/` a `configs/` ve stacku. Soubor smazaný z těchto adresářů v Gitu se při dalším deployi smaže i ve stacku. `.env`, `.env.bak-*`, `/docker-data/authentik-netcup` a `/docker-data/backups/authentik-netcup` v cíli `rsync` nejsou. Když `rsync` selže, skript skončí a `cp` nespustí. `cp` se použije jen když příkaz `rsync` v systému není, a jen na cestu uvnitř stacku.

## reload.sh

Spustí celý `deploy.sh` a potom:

```bash
docker compose up -d --force-recreate --remove-orphans
```

`--force-recreate` vytvoří kontejnery znovu i beze změny konfigurace. `--remove-orphans` odstraní služby, které v Compose projektu už nejsou. Data v `DATA_DIR` nemaže.

`--pull` je přijato kvůli kompatibilitě a podruhé obrazy nestahuje. Stahování je v `deploy.sh`.

Po recreate následuje `post-deploy.sh` a `test.sh`.

## post-deploy.sh a test.sh

`post-deploy.sh` vyžaduje běžící PostgreSQL ve stavu healthy a úspěšné `ak healthcheck` u serveru i workeru. Kontroluje také vazbu `10.10.10.100:9000`. Neúspěšný příkaz je chyba, ne přeskočený úspěch.

`test.sh` bez argumentu dělá totéž v nasazeném kontejneru, včetně Dockge a existence Docker sítě.

`test.sh --static` je varianta pro checkout: struktura, politika `.env.example`, odmítnutí placeholderů, statické porty, dočasný test `rsync --delete`, šifrování zálohy pomocí `age`, kontrolní součty a odmítnutí neúplné obnovy. `docker compose config` vypíše, že neběžel, pokud Docker CLI chybí.

## Záloha

`./scripts/backup.sh` a `./scripts/restore.sh` jsou popsané v `docs/backup-restore.md`. Příkaz `age` musí být nainstalovaný v cílovém Debian 13 kontejneru. Prázdný `BACKUP_AGE_RECIPIENT` `backup.sh` odmítne a archiv nezapíše. Cíl `/backups` se použije jen jako připojený mountpoint. Když připojený není, záloha skončí chybou a do obyčejného adresáře nezapíše. Úspěch je ověřená šifrovaná kopie na tomto hostitelském adresáři VPS. Není to jiný disk ani přenos na jiný server. Soukromá identita pro `--identity` zůstává oddělená, mimo Git, stack, data a lokální zálohy.
