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

Uživatelský adresář se do tohoto taru nedává. `restic` ho zálohuje inkrementálně a šifrovaně. Manifest drží obě id snapshotu pořízeného ve stejném okně, pokud se liší: `restic_snapshot_id` ve zdrojovém repozitáři a `restic_external_snapshot_id` v cílovém. Pořadí je: nejdřív se zastaví cron, potom se zapne maintenance mode, potom dump, potom kopie malých stromů, potom restic. Teprve potom se maintenance vypne a cron vrátí, pokud je `--hold` vypnutý.

Archiv bez čitelného restic snapshotu není kompletní záloha. `restore.sh` před jakoukoliv změnou živých dat ověří, že repozitář jde otevřít, že snapshot v manifestu existuje a že `restic ls` jeho strom přečte. Dump, který nezačíná `PGDMP` nebo obsahuje stopu MariaDB, se nenačte. Hlavní verze PostgreSQL v manifestu musí být 18. Přepínač `--allow-version-mismatch` umí jen rozdílný tag Nextcloudu, ne jinou databázi.

## Lokální a externí záloha

Lokální restic repozitář na stejném filesystému jako data, a age archiv v `/docker-data/backups/nextcloud-gr`, jsou bod obnovy na tomto stroji. Nejsou to záloha proti ztrátě disku. Samotný soubor `.tar.gz.age` uživatelské soubory neobsahuje. Jeho zkopírování bez odpovídajícího restic snapshotu `backup.sh` neoznačí jako kompletní zálohu.

Kompletní externí záloha je age archiv (dump, config, custom apps, themes, manifest a id snapshotu) a zároveň čitelný restic snapshot na odděleném úložišti. To splní jedna ze dvou cest:

- `RESTIC_REPOSITORY` je vzdálené schéma `sftp`, `rest`, `s3`, `rclone`, `azure`, `gs`, `b2` nebo `swift`. Snapshot se ověřuje přímo v něm.
- `RESTIC_REPOSITORY` je lokální cesta a `BACKUP_EXTERNAL_DIR` je mountpoint na jiném zařízení. `backup.sh` snapshot přenese příkazem `restic copy` do podadresáře `restic`. Text příkazu `restic copy` se jako id nepoužije. Skutečné id se přečte z `snapshots --json` cílového repozitáře podle stromu, času a hostname a ověří se `cat`, `snapshots` a `ls`. Toto id může být jiné než id ve zdrojovém repozitáři. Manifest v age archivu proto má `restic_snapshot_id` a `restic_external_snapshot_id`. Teprve potom se na stejný mount zkopíruje age archiv. Na tom mountu musejí být obě části: šifrovaný archiv i restic snapshot s uživatelskými soubory.

`BACKUP_EXTERNAL_DIR` se použije jen když je cesta sama mountpoint a mód `700`. Běžný adresář stejného jména nestačí. Prázdná hodnota u lokálního restic repozitáře znamená, že kompletní externí záloha nevznikla.

## Klíče a retence

`BACKUP_AGE_RECIPIENT` je veřejný klíč. Privátní identita (`AGE-SECRET-KEY`) se předává jen `restore.sh --identity` a musí mít mód `600` nebo `400`. Nepatří do archivu, do Gitu ani jen na disk, který záloha chrání. Bez ní age archiv neotevřete, i když leží vedle dat.

`RESTIC_PASSWORD` otevírá zdrojový i externí restic repozitář. Vznikne v runtime `.env`. Další kopie musí být offline a mimo zálohované zařízení. Heslo v `.env` na stejném disku jako data po ztrátě toho disku nepomůže. `stack.env` uvnitř age archivu heslo obsahuje, ale k jeho přečtení je zase potřeba privátní age klíč uložený jinde.

K obnově tedy potřebujete tři věci, které nesmějí zůstat jen na zálohovaném disku: age archiv, privátní age klíč a `RESTIC_PASSWORD`. `PG_PASS`, `REDIS_PASSWORD` a `RESTIC_PASSWORD` v běžícím `.env` se při obnově nepřepisují, protože musejí dál sedět na běžící PostgreSQL, Redis a na repozitář, ze kterého se čte. `NEXTCLOUD_ADMIN_PASSWORD` v archivu obnovuje heslo v `.env`; účinné heslo účtu je v databázi.

Retence ve zdrojovém repozitáři je `RESTIC_KEEP_DAILY=7`, `WEEKLY=4`, `MONTHLY=6`, `YEARLY=1`. Nový snapshot má navíc vlastní tag, aby ho `forget` hned nesmazal. `BACKUP_EXTERNAL_DIR` na stejném zařízení jako data se jako oddělené úložiště nepočítá.

## Obnova

```bash
./scripts/restore.sh \
  --archive /docker-data/backups/nextcloud-gr/nextcloud-gr-CAS.tar.gz.age \
  --identity /cesta/mimo/git/age.key \
  --confirm nextcloud-gr
```

Bez `--replace-data` se nic nezmění a návratový kód je 2.

S `--replace-data` musí být zastavené kontejnery `nextcloud-gr-app` a `nextcloud-gr-cron`. PostgreSQL musí běžet a být healthy. Skript nejdřív ověří šifru, manifest a dump. Restic snapshot ověří v repozitáři z `RESTIC_REPOSITORY` a teprve potom uloží rollback. `PG_PASS`, `REDIS_PASSWORD` a `RESTIC_PASSWORD` se z archivu neberou, protože musí dál sedět na běžící PostgreSQL, Redis a repozitář. Obnoví se `NEXTCLOUD_ADMIN_PASSWORD` v `.env`; účinné heslo účtu je v obnovené databázi.

Nový manifest má `restic_snapshot_id` a může mít jiné `restic_external_snapshot_id`. Obnova použije jen to id, které v nakonfigurovaném repozitáři projde `cat`, `snapshots` a `ls`. Když jsou v jednom repozitáři obě a liší se, skript skončí chybou a nic nevybere.

## Starší manifest

Manifest zapsaný před tímto rozlišením má jen `restic_snapshot_id`. Nemá `restic_external_snapshot_id`, strom, čas snapshotu ani hostname. Pole `created_at` je čas skriptu před spuštěním resticu, ne čas snapshotu, a k hledání se nepoužívá.

- Obnova ze zdrojového repozitáře, ve kterém to původní id pořád je: skript ho ověří a použije. Jiná id v tom repozitáři neprohlíží.
- Obnova z externí kopie, ve které `restic copy` uložil snapshot pod jiným id: dohledat ho nejde. Skript nesáhne na nejnovější snapshot ani na jiného kandidáta a skončí bez změny živých dat. Takovou starší zálohu z externí kopie nemusí být možné obnovit.

Kdyby manifest přece jen obsahoval strom, přesný čas snapshotu a hostname, smí se použít jen při jediné shodě a po stejném ověření snapshotu. Víc shod nebo chybějící údaj je chyba. Dnešní ani starší archiv tato tři pole nezapisuje, takže tahle cesta pro ně neplatí.

Když obnova selže, vrátí se předchozí soubory, heslo v `.env` a dump. Když selže i návrat, skript nesmí hlásit úspěch a vypíše cestu ke snímku. Nextcloud se v tom stavu nespouští.

Datový adresář, který není sám mountpoint, restic obnoví do sousedního adresáře a pak ho přejmenuje. Mountpoint přejmenovat nejde, proto `check-env.sh` vyžaduje adresář uvnitř disku. Po obnově dat spusťte `occ files:scan`.

Rollback snímek v `BACKUP_LOCAL_DIR/rollback.*` mažte až po kontrole, že instance naběhla.
