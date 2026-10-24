# Upgrade

https://docs.nextcloud.com/server/stable/admin_manual/maintenance/upgrade.html

https://github.com/nextcloud/docker#update-to-a-newer-version

`deploy.sh` a `reload.sh` verzi Nextcloudu nemění. Když `state/installed-version` nesouhlasí s `NEXTCLOUD_TAG`, deploy skončí dřív, než stáhne image a než spustí kontejner. Entrypoint oficiálního image by jinak při startu `php-fpm` migraci provedl sám.

## Povolený krok

Z `35.0.2-fpm` lze krokem verze jít na novější `35.x.y-fpm` nebo na následující hlavní řadu. To samo nestačí. `scripts/lib/upgrade/php.sh` obsahuje jen ověřenou matici. K 2026-10-20 je v ní Nextcloud 35 s PHP 8.3, 8.4 a 8.5 podle [system requirements](https://docs.nextcloud.com/server/35/admin_manual/installation/system_requirements.html). Neznámá hlavní verze, včetně 36, se odmítne, dokud se matice nerozšíří z dokumentace té řady. PHP image se čte z cílového kontejneru a porovná s maticí této verze, ne s pevným rozsahem pro všechny budoucí řady.

Před výměnou image se zastaví cron, zkontrolují se `max-version` zapnutých aplikací v `custom_apps` a udělá se záloha. Aplikace bez čitelného `max-version` upgrade zastaví. Změna hlavní verze PostgreSQL tímto skriptem neprojde.

## Postup

1. V Gitu změňte `NEXTCLOUD_TAG` na přesný tag `X.Y.Z-fpm`.
2. `./scripts/update-env.sh`
3. `./scripts/check-env.sh`
4. `./scripts/upgrade.sh --target X.Y.Z-fpm --confirm nextcloud-gr`

Cíl musí být stejný jako `NEXTCLOUD_TAG`. Skript ověří nainstalovanou verzi, krok, matici PHP, volné místo, healthchecky a kompatibilitu custom apps. Pak zastaví cron, spustí `backup.sh --hold` a znovu vytvoří jen službu `nextcloud`. Její standardní entrypoint smí upgrade provést jednou. Cron má příkaz `/cron.sh` a `NEXTCLOUD_UPDATE=0`, takže ho neprovede. Znovu se vytvoří až po `occ status` s `needsDbUpgrade: false`, zdravé PostgreSQL a `/status.php`.

Aplikace třetích stran mohou upgrade zastavit. Image to obvykle zjistí dřív, než přepíše schéma, ale skript to nerozlišuje. Při jakékoliv chybě starou image nespouští. Databáze už mohla být zčásti migrovaná a starý kód nad ní nesmí naběhnout.

## Když upgrade spadne

- Cron nechte zastavený a maintenance zapnutou.
- `state/upgrade.lock` nemažte, dokud neobnovíte zálohu nebo vědomě nerozhodnete jinak. `deploy.sh` zámek respektuje.
- Obnova je v `docs/backup-restore.md`. Použijte age archiv z okamžiku `--hold` a restic snapshot z jeho manifestu.
- Log kontejneru `nextcloud-gr-app` je zdroj hlášky. Hesla do něj skript nepřidává.

Po úspěchu skript vypne maintenance, spustí cron a přepíše `installed-version`. Zámek smaže.
