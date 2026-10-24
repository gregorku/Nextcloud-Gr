# Traefik

Router se do tohoto repozitáře nezapisuje. V Infrastructure-netcup bude později soubor `configs/traefik/dynamic/nextcloud.yml`. Tento projekt určuje jen backend.

## Smlouva

- Veřejné jméno: `gregor.serveftp.org`
- Schéma mezi Traefikem a Nginxem: HTTP
- Adresa a port: hodnoty `NEXTCLOUD_BACKEND_BIND` a `NEXTCLOUD_BACKEND_PORT` po jejich doplnění do runtime `.env`
- TLS a certifikát: Traefik v Infrastructure-netcup
- `TRUSTED_PROXIES`: CIDR, ze kterého Traefik na tento Nginx přichází. Bez změřené adresy zůstává placeholder a deploy neproběhne

Traefik má posílat `X-Forwarded-Proto: https`, `X-Forwarded-Host: gregor.serveftp.org` a `X-Forwarded-For` s adresou klienta. Nextcloud má `overwriteprotocol=https`, `overwritehost` a `overwrite.cli.url` nastavené na veřejnou HTTPS adresu.

WebDAV, CalDAV, CardDAV, desktopový a mobilní klient jdou na stejnou doménu bez ForwardAuth. Nezapínejte middleware, který by vyžadoval přihlášení Authentikem před každým požadavkem na `/remote.php` nebo `/.well-known`.

Ukázka, kterou patří doplnit až budou známé adresy, nepatří do tohoto Compose:

```yaml
http:
  routers:
    nextcloud-gr:
      rule: Host(`gregor.serveftp.org`)
      entryPoints:
        - websecure
      service: nextcloud-gr
      tls:
        certResolver: letsencrypt
  services:
    nextcloud-gr:
      loadBalancer:
        servers:
          - url: http://ADRESA_Z_ENV:PORT_Z_ENV
```

`ADRESA_Z_ENV` a `PORT_Z_ENV` sem nepište, dokud je správce v `.env` nenastaví. Router nepotřebuje Docker socket tohoto kontejneru.
