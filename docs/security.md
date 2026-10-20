# Bezpečnost

## Co je v Gitu

`.env.example` má u tajemství a u neznámých provozních hodnot prefix `set_`. `check-env.sh` takový runtime soubor odmítne. Skutečné `PG_PASS` a `AUTHENTIK_SECRET_KEY` vzniknou až v `/docker-data/stacks/authentik-netcup/.env`.

Do dokumentace, Compose ani example nepatří produkční heslo, SMTP heslo ani secret key.

## Síťové publikování

Authentik HTTP je navázaný na `10.10.10.100:9000`, ne na `0.0.0.0`. PostgreSQL a worker port na hostitele nepublikují. HTTPS port kontejneru `9443` také ne. TLS končí na Traefiku v Infrastructure-netcup.

Firewall, který má přímý přístup na `10.10.10.100:9000` omezit, je věc Infrastructure-netcup. Tento repozitář ho nemění.

## Trusted proxy

`AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS` nahrazuje výchozí seznam authentiku. Hodnota v example je placeholder, protože adresa, ze které Traefik na publikovaný port skutečně přichází, nebyla z tohoto checkoutu pozorována. Dokud v runtime `.env` není konkrétní CIDR, `deploy.sh` neprojde validací.

Nastavte jen síť, ze které se Traefik připojuje přímo k Authentiku. Ne celou síť klientů.

## Outpost a Docker socket

Embedded outpost je součást serveru a používá `AUTHENTIK_SECRET_KEY`. Samostatný kontejner outpostu se nenasazuje. Worker proto nedostává Docker socket a neběží jako root. `AUTHENTIK_OUTPOSTS__DISCOVER=false`, aby worker nehledal Docker ani Kubernetes integraci pro cizí outposty.

## SMTP a hlášení chyb

SMTP host, uživatel, heslo a odesílatel jsou placeholdery, dokud se nedoplní. `AUTHENTIK_ERROR_REPORTING__ENABLED=false`, aby se reporty neposílaly ven. Časová zóna hostitele se do kontejnerů Authentiku nemountuje; upstream u toho popisuje rozbití OAuth a SAML.

## Zálohy

Trvalý archiv je `tar.gz.age` zašifrovaný veřejným `BACKUP_AGE_RECIPIENT`. Příkaz `age` musí být nainstalovaný v cílovém Debian 13 kontejneru. Bez příjemce nebo bez funkčního šifrování se běh neoznačí za úspěšnou zálohu. Kopie jde do `/backups` jen když je to připojený mountpoint mód `700`. Archiv a checksum v cíli mají mód `600`. Úspěch je ověřená kopie na připojeném hostitelském adresáři VPS, ne záloha na jiném disku a ne přenos na jiný server. Soukromá identita se neukládá do Gitu, do stacku, do dat, do archivu ani do adresáře záloh a při záloze se nečte. Při obnově musí být soubor identity, mód `600` nebo `400`, dostupný mimo tato místa a předá se jen jako `--identity`. Lokální adresář `/docker-data/backups/authentik-netcup` má mód `700`. `/docker-data/authentik-netcup` mód `700` nedostává, aby do podadresářů mohli PostgreSQL UID `70` a Authentik UID `1000`. Není v `DEPLOY_ITEMS`. Obnovení chce `--confirm authentik-netcup` a bez `--replace-data` data nepřepisuje.

Dump, `stack.env` a manifest vznikají rovnou s módem `600` ve staging adresáři `700`. Samostatný plaintext tar se nezapisuje: `tar` jde proudem do `age`. `shred` stagingu je potom jen nejlepší úsilí: na SSD, na copy-on-write souborovém systému a ve snímcích nezaručuje zmizení dat. Pád nebo `SIGKILL` může nešifrovaný staging nechat na disku.

## Dockge

`deploy.sh` Dockge nezastavuje a nemaže. `install-dockge.sh` skončí chybou dřív, než by sáhl na kontejner. Port Dockge `5001` tento projekt nemění.
