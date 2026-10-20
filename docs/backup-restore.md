# Záloha a obnova

Postup odpovídá dokumentaci Nextcloudu:

- https://docs.nextcloud.com/server/stable/admin_manual/maintenance/backup.html
- https://docs.nextcloud.com/server/stable/admin_manual/maintenance/restore.html

Jedna obnova potřebuje databázi, `config`, `custom_apps`, `themes` a uživatelská data ze stejného okamžiku. Jádro Nextcloudu je v připnutém image, ne v archivu.

## Dva nástroje

Age archiv v `/docker-data/backups/nextcloud-gr` je malý. Obsahuje:

- `postgresql/nextcloud.dump`, custom formát `pg_dump -Fc`
- `nextcloud/config`, `custom_apps`, `themes`
- `nextcloud/app-list.txt`
- `stack.env`
- `manifest.txt` s tagem, hlavní verzí PostgreSQL, sha256 souborů a id restic snapshotu

Uživatelský adresář se do tohoto taru nedává. `restic` ho zálohuje inkrementálně a šifrovaně. Manifest drží id snapshotu pořízeného ve stejném okně: nejdřív se zastaví cron, potom se zapne maintenance mode, potom dump, potom kopie malých stromů, potom restic. Teprve potom se maintenance vypne a cron vrátí, pokud je `--hold` vypnutý.

Archiv bez čitelného restic snapshotu není kompletní záloha. `restore.sh` před jakoukoliv změnou živých dat ověří, že repozitář jde otevřít, že snapshot v manifestu existuje a že `restic ls` jeho strom přečte. Dump, který nezačíná `PGDMP` nebo obsahuje stopu MariaDB, se nenačte. Hlavní verze PostgreSQL v manifestu musí být 18. Přepínač `--allow-version-mismatch` umí jen rozdílný tag Nextcloudu, ne jinou databázi.

## Lokální a externí záloha

Lokální restic repozitář na stejném filesystému jako data, a age archiv v `/docker-data/backups/nextcloud-gr`, jsou bod obnovy na tomto stroji. Nejsou to záloha proti ztrátě disku. Samotný soubor `.tar.gz.age` uživatelské soubory neobsahuje. Jeho zkopírování bez odpovídajícího restic snapshotu `backup.sh` neoznačí jako kompletní zálohu.

Kompletní externí záloha je age archiv (dump, config, custom apps, themes, manifest a id snapshotu) a zároveň čitelný restic snapshot na odděleném úložišti. To splní jedna ze dvou cest:

- `RESTIC_REPOSITORY` je vzdálené schéma `sftp`, `rest`, `s3`, `rclone`, `azure`, `gs`, `b2` nebo `swift`. Snapshot se ověřuje přímo v něm.
- `RESTIC_REPOSITORY` je lokální cesta a `BACKUP_EXTERNAL_DIR` je mountpoint na jiném zařízení. `backup.sh` tam snapshot přenese příkazem `restic copy` do podadresáře `restic`, ověří ho a teprve potom zkopíruje age archiv. Oba repozitáře používají stejné `RESTIC_PASSWORD`.

`BACKUP_EXTERNAL_DIR` se použije jen když je cesta sama mountpoint a mód `700`. Běžný adresář stejného jména nestačí. Prázdná hodnota u lokálního restic repozitáře znamená, že kompletní externí záloha nevznikla.

## Klíče a retence

`BACKUP_AGE_RECIPIENT` je veřejný klíč. Privátní identita se předává jen `restore.sh --identity` a musí mít mód `600` nebo `400`.

`RESTIC_PASSWORD` vznikne v `.env`. Bez offline kopie není repozitář po ztrátě disku otevřitelný. Retence je `RESTIC_KEEP_DAILY=7`, `WEEKLY=4`, `MONTHLY=6`, `YEARLY=1`. Nový snapshot má navíc vlastní tag, aby ho `forget` hned nesmazal. `BACKUP_EXTERNAL_DIR` na stejném zařízení jako data se jako oddělené úložiště nepočítá.

## Obnova

```bash
./scripts/restore.sh \
  --archive /docker-data/backups/nextcloud-gr/nextcloud-gr-CAS.tar.gz.age \
  --identity /cesta/mimo/git/age.key \
  --confirm nextcloud-gr
```

Bez `--replace-data` se nic nezmění a návratový kód je 2.

S `--replace-data` musí být zastavené kontejnery `nextcloud-gr-app` a `nextcloud-gr-cron`. PostgreSQL musí běžet a být healthy. Skript nejdřív ověří šifru, manifest, dump i restic snapshot. Pak teprve uloží rollback a začne mazat živé stromy. `PG_PASS`, `REDIS_PASSWORD` a `RESTIC_PASSWORD` se z archivu neberou, protože musí dál sedět na běžící PostgreSQL, Redis a repozitář. Obnoví se `NEXTCLOUD_ADMIN_PASSWORD` v `.env`; účinné heslo účtu je v obnovené databázi.

Když obnova selže, vrátí se předchozí soubory, heslo v `.env` a dump. Když selže i návrat, skript nesmí hlásit úspěch a vypíše cestu ke snímku. Nextcloud se v tom stavu nespouští.

Datový adresář, který není sám mountpoint, restic obnoví do sousedního adresáře a pak ho přejmenuje. Mountpoint přejmenovat nejde, proto `check-env.sh` vyžaduje adresář uvnitř disku. Po obnově dat spusťte `occ files:scan`.

Rollback snímek v `BACKUP_LOCAL_DIR/rollback.*` mažte až po kontrole, že instance naběhla.
