# Záloha a obnovení

## Šifrování

Trvalý archiv je soubor `tar.gz.age`. Šifruje ho [age](https://github.com/FiloSottile/age) pro veřejného příjemce `BACKUP_AGE_RECIPIENT` v runtime `.env`. Příjemce je `age1…` nebo veřejný SSH klíč.

Příkaz `age` musí být nainstalovaný v cílovém Debian 13 kontejneru. Statický test na pracovní stanici přítomnost `age` v tom kontejneru neověřuje.

Soukromý klíč (`AGE-SECRET-KEY-…`) se neukládá do Gitu, do archivu, do stacku, do `DATA_DIR` ani do lokálního adresáře záloh. V okamžiku obnovy musí být soubor identity bezpečně dostupný mimo tato místa a předá se jen jako `--identity`. Mód souboru je `600` nebo `400`. `age` ho čte přes deskriptor souboru, ne jako argument příkazu.

Když je `BACKUP_AGE_RECIPIENT` prázdný, nebo když v kontejneru není příkaz `age`, `backup.sh` archiv nezapíše a tento běh není bezpečná externí záloha.

## Dočasný plaintext

Před šifrováním vznikne v `mktemp -d` (mód `700`) staging adresář. V něm jsou:

- `postgresql/authentik.dump`, založený přes `install -m 600` a teprve potom plněný výstupem `pg_dump`;
- kopie `authentik/data`, `authentik/templates` a `authentik/certs`, každý soubor založený jako `600`;
- `stack.env`, kopie runtime `.env` přes `install -m 600`;
- `manifest.txt`, založený jako `600`.

`umask 077` je nastavený na začátku `backup.sh` a `restore.sh`. Skript po sestavení stromu mód zkontroluje a při jiném módu archiv nezapíše. Pozdější `chmod` tuto kontrolu nenahrazuje.

Samostatný `plain.tar.gz` se nezakládá. Po kontrole stagingu jde `tar` na standardní výstup a `age` šifruje tento proud do dočasného `.age` souboru. `pipefail` hlídá návratový kód `tar` i `age`. Konečný archiv v adresáři záloh vznikne až po úspěchu celé pipeline a po ověření součtu toho dočasného souboru. Při chybě se neúplný `.age` smaže a běh není úspěšná záloha. Soukromá identita se při záloze nepoužívá. Obnova dál čte jen `.tar.gz.age`.

Když je k dispozici `shred`, skript jím soubory ve stagingu jednou přepíše a smaže jejich jméno. To je nejlepší úsilí. `shred` nezaručuje, že data zmizela z SSD, z copy-on-write souborového systému ani ze snímku disku. Při pádu procesu nebo při `SIGKILL` se úklid nespustí a nešifrovaný staging může na disku zůstat. Bez `shred` se soubor jen odlinkuje.

Kontrolní součet `.sha256` patří šifrovanému souboru.

## Co záloha obsahuje

`./scripts/backup.sh` v kontejneru:

1. ověří příjemce a přítomnost `age` ještě před zastavením Authentiku;
2. ověří, že `authentik-postgresql` běží a healthcheck je `healthy`;
3. zastaví `authentik-server` a `authentik-worker`, pokud běží;
4. udělá `pg_dump -Fc` lokálním socketem uživatele `postgres` uvnitř kontejneru;
5. zkopíruje `authentik/data`, `authentik/templates` a `authentik/certs`;
6. přidá kopii runtime `.env` jako `stack.env`;
7. zapíše `manifest.txt`, ověří mód `700`/`600` a teprve potom dump, adresáře a `AUTHENTIK_SECRET_KEY`;
8. pošle `tar` ze stagingu na standardní výstup do `age` a zapíše dočasný `.age` soubor;
9. po úspěchu pipeline a po ověření jeho součtu teprve uloží konečný šifrovaný archiv;
10. spustí jen ty kontejnery Authentiku, které tento běh zastavil.

Adresář dat PostgreSQL se nekopíruje. Konzistentní obraz databáze je dump.

HTTP na `10.10.10.100:9000` je po dobu dumpu a kopírování nedostupné. PostgreSQL zůstává spuštěná. Když server nebo worker před zálohou neběžel, skript ho po sobě nespouští.

Archiv:

```text
/docker-data/backups/authentik-netcup/authentik-netcup-YYYYMMDD-HHMMSS.tar.gz.age
```

Tento adresář leží na disku Incus kontejneru. Ani šifrovaný soubor v něm není záloha mimo kontejner.

## Ostrá záloha

`BACKUP_EXTERNAL_DIR` je `/backups`. V kontejneru je to Incus diskové zařízení z hostitelského VPS. `df` a `stat` na něm ukazují stejné zařízení jako u `/docker-data`. Rozdíl je mountpoint: `/backups` je připojený mount, lokální adresář záloh není.

`check-env.sh` prázdný `BACKUP_AGE_RECIPIENT` i prázdný `BACKUP_EXTERNAL_DIR` přijme. Prázdný příjemce znamená, že `backup.sh` archiv nezapíše. Prázdný cíl znamená, že šifrovaný soubor zůstane jen v lokálním adresáři na disku kontejneru.

Pro kopii na hostitelský adresář musí být v runtime `.env` veřejný příjemce `BACKUP_AGE_RECIPIENT` (`age1…` nebo veřejný SSH klíč) a `/backups` musí být skutečně připojený mountpoint s módem `700`. Soukromá identita (`AGE-SECRET-KEY-…`) do příjemce nepatří. Zůstává odděleně mimo Git, stack, `DATA_DIR` a `/docker-data/backups/authentik-netcup`. `backup.sh` ji nečte. Obnova ji dostane jen jako `--identity`, v souboru s módem `600` nebo `400`.

`backup.sh` při prázdném příjemci, při soukromém klíči na místě příjemce, nebo když v kontejneru chybí příkaz `age`, archiv nezapíše a běh není úspěšná záloha.

Úspěch kopie znamená ověřený soubor `.tar.gz.age` a jeho `.sha256` na připojeném hostitelském adresáři VPS. Není to záloha na jiném disku. Není to přenos na jiný server. Ten přenos dělá později jiný program a tento repozitář ho neprovádí.

## Kopie na `/backups`

Cesta se vezme přes `realpath`. Musí to být existující adresář, vlastněný uživatelem, který zálohu spouští, mód `700`, a nesmí být v Gitu, ve stacku, v datech ani v lokálních zálohách. Skript adresář nevytváří a mód `700` mu sám nenastavuje.

Mountpoint se čte z `findmnt` a z `/proc/self/mountinfo`. Obě tabulky se musí shodovat a `mountpoint` musí potvrdit, že cílem je přímo tento mount, ne adresář uvnitř jiného mountu. Číslo zařízení se nepoužívá. Stejné zařízení jako `/docker-data` je u tohoto Incus bind mountu očekávané.

Když `/backups` není připojené, nebo když na kořenovém souborovém systému kontejneru leží jen obyčejný adresář stejného jména, `backup.sh` skončí chybou a do toho adresáře nezapíše.

Po zápisu mají archiv i checksum mód `600`. Kontrolní součet se ověřuje až na souborech v cílovém adresáři. Teprve potom se vypíše ověřená kopie na připojeném hostitelském adresáři.

## Obnovení

Nejdřív ověření bez zápisu. Součet šifrovaného souboru se kontroluje před dešifrováním:

```bash
./scripts/restore.sh \
  --archive /docker-data/backups/authentik-netcup/authentik-netcup-YYYYMMDD-HHMMSS.tar.gz.age \
  --identity /cesta/mimo/stack/authentik.agekey \
  --confirm authentik-netcup
```

Exit code `2` znamená, že šifrovaný archiv, manifest, dump, persistentní adresáře i `AUTHENTIK_SECRET_KEY` sedí a persistentní data se nezměnila.

Zápis:

```bash
./scripts/restore.sh \
  --archive /docker-data/backups/authentik-netcup/authentik-netcup-YYYYMMDD-HHMMSS.tar.gz.age \
  --identity /cesta/mimo/stack/authentik.agekey \
  --confirm authentik-netcup \
  --replace-data
```

Před `--replace-data`:

- `authentik-server` a `authentik-worker` jsou zastavené;
- `authentik-postgresql` běží a je healthy;
- `AUTHENTIK_TAG` v `.env` je stejný jako `authentik_tag` v manifestu.

`--confirm` musí být přesně `authentik-netcup`.

Po dešifrování do adresáře `700` se kontroluje neprázdný `postgresql/authentik.dump`, adresáře `authentik/data`, `authentik/templates` a `authentik/certs`, manifest a použitelný `AUTHENTIK_SECRET_KEY`. Teprve potom se do `BACKUP_LOCAL_DIR` zapíše rollback. Jakmile adresář snímku vznikne, při nečekaném konci se nesmaže. Před první `rm` živých dat je snímek ověřený a tento režim už platí.

Snímek obsahuje tři adresáře, kopii `.env` a `pg_dump` současné databáze. Pak se nahradí soubory, v `.env` jen řádek `AUTHENTIK_SECRET_KEY` a nakonec `pg_restore --single-transaction`. Ostatní řádky `.env` zůstávají. Před zápisem klíče vznikne `.env.bak-*` s módem `600`.

Úspěch se vypíše až po porovnání souborů, shodě klíče a healthy PostgreSQL. Snímek se maže až potom. Když se snímek po ověřené obnově nesmaže, úspěch se nevyhlásí.

`SIGTERM`, `SIGINT` a `SIGHUP` spustí jeden pokus o návrat, pokud už živá data mohla být změněná. Snímek zůstane. `SIGKILL` zachytit nelze: automatický návrat neproběhne a snímek zůstane na disku právě proto, aby šel návrat udělat ručně.

## Když obnova nedoběhne

Authentik nespouštějte, dokud soubory, klíč a databáze znovu nesedí.

- Skript sám vrátil stav a skončil chybou. Snímek je v `BACKUP_LOCAL_DIR/rollback.*`. Je to kopie stavu před obnovou, ne druhá šifrovaná záloha.
- Návrat selhal. Ve zprávě je cesta ke snímku. Nejdřív vraťte `authentik/data`, `templates`, `certs` a řádek `AUTHENTIK_SECRET_KEY` ze `runtime.env` ve snímku. Teprve potom načtěte `postgresql/authentik.dump` ze snímku do běžící PostgreSQL.
- `SIGKILL` uprostřed zápisu. Snímek na disku je, automatický návrat ne. Živé adresáře mohou být prázdné nebo smíchané s archivem, klíč v `.env` může být nový a databáze ještě starý, nebo naopak. Stejný ruční postup: soubory a klíč ze snímku, potom dump ze snímku. Dokud to nesedí, server a worker nechte zastavené.

Klíč a dump jsou svázané tím, že byly v jednom archivu se součty. Skript nezkouší, že klíč dešifruje řádky v databázi.

`--allow-version-mismatch` obnovu povolí i při jiném tagu. Bez ověřeného důvodu ho nepoužívejte.

## Test bez produkčních dat

`./scripts/test.sh --static` v dočasných adresářích pouští skutečné `age`, `install`, `tar` a `sha256sum`, když jsou na stroji, a u souborů čte `stat`. `pg_dump`, `pg_restore` a Docker při tom nespouští. Zastavení kontejnerů a načtení databáze jsou v příslušných testech nahrazené funkce. `SIGTERM` dostane pomocný proces, ne produkční `restore.sh`. Rozpoznání mountpointu se zkouší v soukromém mount namespace na dočasném bind mountu. Produkční `/backups` ani disk VPS se nepřipojuje. Obyčejný adresář na stejném zařízení se dál odmítá. Kontrola `shred` ověřuje jen to, že jméno souboru zmizelo. Neověřuje, že bloky na SSD nebo na copy-on-write souborovém systému jsou pryč.
