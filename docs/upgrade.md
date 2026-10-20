# Upgrade

https://docs.nextcloud.com/server/stable/admin_manual/maintenance/upgrade.html

https://github.com/nextcloud/docker#update-to-a-newer-version

`deploy.sh` a `reload.sh` verzi Nextcloudu nemění. Když `state/installed-version` nesouhlasí s `NEXTCLOUD_TAG`, deploy skončí dřív, než stáhne image a než spustí kontejner. Entrypoint oficiálního image by jinak při startu `php-fpm` migraci provedl sám.

## Povolený krok

Z `35.0.2-fpm` lze jít na novější `35.x.y-fpm` nebo na následující hlavní řadu, například `36.0.0-fpm`. Skok o dvě hlavní verze a downgrade se odmítnou. Před každým krokem je nová záloha. Změna hlavní verze PostgreSQL tímto skriptem neprojde.

## Postup

1. V Gitu změňte `NEXTCLOUD_TAG` na přesný tag `X.Y.Z-fpm`.
2. `./scripts/update-env.sh`
3. `./scripts/check-env.sh`
4. `./scripts/upgrade.sh --target X.Y.Z-fpm --confirm nextcloud-gr`

Cíl musí být stejný jako `NEXTCLOUD_TAG`. Skript ověří nainstalovanou verzi, krok, dostupnost image, PHP 8.3 až 8.5 v cílovém image, volné místo, healthchecky a `occ app:list`. Pak spustí `backup.sh --hold`: maintenance zůstane zapnutá a cron zastavený. Teprve potom znovu vytvoří jen službu `nextcloud`. Cron se vytvoří z nového image až po `occ status` a `/status.php`.

Aplikace třetích stran mohou upgrade zastavit. Image to obvykle zjistí dřív, než přepíše schéma, ale skript to nerozlišuje. Při jakékoliv chybě starou image nespouští. Databáze už mohla být zčásti migrovaná a starý kód nad ní nesmí naběhnout.

## Když upgrade spadne

- Cron nechte zastavený a maintenance zapnutou.
- `state/upgrade.lock` nemažte, dokud neobnovíte zálohu nebo vědomě nerozhodnete jinak. `deploy.sh` zámek respektuje.
- Obnova je v `docs/backup-restore.md`. Použijte age archiv z okamžiku `--hold` a restic snapshot z jeho manifestu.
- Log kontejneru `nextcloud-gr-app` je zdroj hlášky. Hesla do něj skript nepřidává.

Po úspěchu skript vypne maintenance, spustí cron a přepíše `installed-version`. Zámek smaže.
