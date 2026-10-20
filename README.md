# Authentik-netcup

Authentik v existujícím Incus kontejneru `10.10.10.100`. Skripty se spouštějí uvnitř toho kontejneru. Repozitář kontejner nevytváří.

Veřejné jméno je `auth.serveftp.org`. HTTP backend pro Traefik v Infrastructure-netcup je `http://10.10.10.100:9000`. DNS, TLS a middleware Traefiku zůstávají v Infrastructure-netcup.

## Tři adresáře

```text
Git checkout
/incus-dir/git/Authentik-netcup
        |
        v
Runtime stack
/docker-data/stacks/authentik-netcup
        |
        v
Persistentní data
/docker-data/authentik-netcup
```

Git obsahuje Compose, `configs/`, skripty a `.env.example`. Runtime stack je to, co čte Docker Compose a Dockge, plus samostatný `.env`. Data Authentiku a PostgreSQL leží mimo stack, takže je `rsync --delete` nesmaže.

## Služby

Upstream Compose pro authentik 2026.8 (tag `2026.8.3`) obsahuje PostgreSQL 16, server a worker. Redis v této verzi není. Embedded outpost běží v serveru. Samostatný proxy outpost ani Docker socket ve workeru nejsou.

## Pořadí v kontejneru

```bash
./scripts/init.sh
./scripts/update-env.sh
# doplnit set_* hodnoty v /docker-data/stacks/authentik-netcup/.env
./scripts/check-env.sh
./scripts/deploy.sh
./scripts/post-deploy.sh
./scripts/test.sh
```

`./scripts/test.sh --static` ověřuje checkout bez Dockeru a bez zápisu do `/docker-data`.

Podrobnosti jsou v `docs/`.
