# Migrace ze současné instalace

Tento dokument migraci nespouští. `init.sh` a `deploy.sh` stará data nemění a do nového Nextcloudu je nepřipojují.

Současná instalace běží na fyzickém domácím serveru:

| Co | Cesta na hostiteli |
| --- | --- |
| Aplikace | `/docker/nextcloud/nextcloud_gregor/nextcloud_app` |
| Uživatelské soubory | `/HDD/data-raid-HDD/Nextcloud-data/data-Gregor` |
| MariaDB | `/SDD/nvme-1T-btrf/nextcloud_gregor/mariadb/db_data` |
| Redis | `/docker/nextcloud/nextcloud_gregor/redis/data` |

Nová instance má vlastní PostgreSQL 18 a vlastní prázdný datový adresář. Adresář MariaDB se do PostgreSQL nekopíruje. Není to kompatibilní dump a `restore.sh` soubor bez hlavičky `PGDMP` odmítne. Starý aplikační strom a starý Redis se také nepřebírají.

Které z těchto cest už jsou v novém Incus kontejneru vidět, z tohoto checkoutu nešlo zjistit. Incus disk device nastavuje správce. Zdroj souborů má být v kontejneru jen pro čtení a jen po dobu kopie.

## Co kopie souborů nepřenese

| Druh | Kde to žije ve starém Nextcloudu | Jak to přenést |
| --- | --- | --- |
| Fotografie, dokumenty, malé soubory | soubory v datadir | kopie souborů a `occ files:scan` |
| Časová razítka souborů | metadata souborů | `rsync -a` nebo `cp -a` |
| Kalendáře a události | databáze, ne soubory v datadir | export iCalendar `.ics` a import |
| Kontakty | databáze | export vCard `.vcf` a import |
| Účty, hesla, skupiny, práva | databáze | nový účet se stejným jménem; hesla se ze staré MariaDB nepřenesou |
| Sdílení, komentáře, značky, verze souborů, koš, historie | databáze a `files_versions` | verze souborů leží v datadir, ale jejich metadata v databázi; samotná kopie datadir je neobnoví jako historii Nextcloudu |
| Aplikační nastavení a seznam aplikací | databáze a `config.php` | nastavit znovu; `config.php` ze staré instance do PostgreSQL instalace nepatří |

Sdílení, oprávnění a historii Nextcloud po souborové kopii automaticky nesestaví. To je potřeba říct uživateli před cutoverem. Hesla účtů je nutné nastavit znovu nebo později napojit OIDC. Tento projekt ForwardAuth nezapíná.

## Kalendáře a kontakty

Ověřená cesta pro Nextcloud 35 i pro starší řadu, ze které se odchází, je standardní výměna CalDAV/CardDAV:

1. Ve starém Nextcloudu otevřete Kalendář a u každého kalendáře zvolte stažení nebo export `.ics`. U velkého kalendáře lze použít `occ` v kontejneru staré instance, pokud tam je k dispozici, nebo klienta CalDAV (Thunderbird, DAVx5) a export do `.ics`.
2. Kontakty exportujte jako `.vcf` z aplikace Kontakty nebo přes CardDAV klienta.
3. V nové instanci, až existuje účet se stejným uživatelským jménem, kalendář naimportujte v aplikaci Kalendář a kontakty v aplikaci Kontakty.
4. Porovnejte počet událostí a kontaktů. Samotný `files:scan` kalendář ani kontakty neuvidí.

Přímý SQL převod MariaDB → PostgreSQL se nedělá. Nástroje typu `pgloader` by přenesly i interní schéma konkrétní verze Nextcloudu a snadno by rozešly soubory a databázi. Pro tuto migraci se nepoužívají.

## Postup cutoveru

1. Na staré instanci zapněte maintenance mode a zastavte její cron. Od této chvíle do ní klienti nezapisují.
2. Udělejte ověřenou zálohu staré instalace jejím dosavadním postupem. Dokud ta záloha není obnovitelná, v kopírování nepokračujte.
3. Exportujte kalendáře do `.ics` a kontakty do `.vcf` a uložte je mimo oba datové adresáře.
4. Zkopírujte jen uživatelské soubory do `NEXTCLOUD_DATA_HOST_DIR`. Zdroj otevřete read-only. Cíl musí být jiný adresář. Nepoužívejte `rsync --delete` proti starým datům. Vhodné je `rsync -a` bez `--delete` do prázdného cíle.
5. V nové instanci založte účet se stejným uživatelským jménem, jaké mají adresáře v datadir (`files/USERNAME` podle starého úložiště).
6. V kontejneru `nextcloud-gr-app` spusťte jako `www-data`:

   ```bash
   php occ files:scan --all
   ```

   Scan přiřadí soubory k účtu. Nesestaví sdílení ani starou historii verzí.
7. Naimportujte `.ics` a `.vcf`.
8. Zkontrolujte fotografie, malé soubory, časová razítka, jeden kalendář, jeden kontakt a přihlášení desktopového i mobilního klienta na nové URL. Staré klienty nepřepínejte, dokud tato kontrola nesedí.
9. Cutover je změna backendu v Traefiku z starého Nextcloudu na `http://BIND:PORT` tohoto Nginxu. Starou instanci nechte vypnutou, ale její data a MariaDB nemažte, dokud nová instance neběží a záloha nové instance neprojde `restore.sh` bez `--replace-data` aspoň ověřením archivu.

Návrat je zapnutí staré instance a vrácení Traefik routeru. Nový PostgreSQL a nový datadir se při návratu nemažou, jen se přestanou používat. Proto nesmí být starý datadir namountovaný do nové instance pro zápis.

`files:scan` může u velkého počtu fotografií trvat dlouho. Do té doby klienti novou instanci nesmí považovat za hotovou.
