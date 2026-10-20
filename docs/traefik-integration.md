# Návaznost na Infrastructure-netcup

Traefik, DNS, certifikáty a middleware zůstávají v repozitáři a kontejneru Infrastructure-netcup. Authentik-netcup je nepřidává a při deployi Traefik nerestartuje. `deploy_restart_services` je proto prázdný krok se zprávou, že lokální reverse proxy se nerestartuje.

## Backend

| Položka | Hodnota |
| --- | --- |
| Jméno | `auth.serveftp.org` |
| Backend | `http://10.10.10.100:9000` |
| Vazba portu | jen `10.10.10.100`, ne `0.0.0.0` |
| TLS | na Traefiku, ne v Authentiku |

Router, service a middleware se doplní v Infrastructure-netcup. Tento dokument je jen smlouva mezi projekty, ne konfigurace Traefiku.

## Hlavičky

Authentik přijme `X-Forwarded-Proto`, `X-Forwarded-Host` a `X-Forwarded-For` jen od adresy ze `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS`. Od release 2026.8 to platí pro forwarded hlavičky důsledně. Výchozí seznam authentiku se nastavením proměnné nahrazuje, nepřidává se k němu.

Placeholder `set_trusted_proxy_cidrs` deploy odmítne. CIDR doplňte podle adresy, ze které se Traefik na `10.10.10.100:9000` skutečně připojí. Ta adresa z tohoto checkoutu změřená nebyla. Traefik v Infrastructure-netcup je na `10.10.10.10`, ale Docker při publikaci portu může zdrojovou adresu přepsat. Do `.env` proto nepatří odhad.

## Embedded outpost

Aplikace, které mají jít přes proxy provider Authentiku, používají embedded outpost na stejném portu `9000`. Samostatný outpost kontejner se nespouští a Infrastructure-netcup ho nemá kam směrovat navíc.

## Co se v Infrastructure-netcup nemění tímto repozitářem

- konfigurace Traefiku a jeho souborové providery;
- CrowdSec;
- DNS `auth.serveftp.org`;
- firewall VPS;
- certifikát pro `auth.serveftp.org`.

Až bude backend z tohoto stacku běžet, ověření zvenku je požadavek na `https://auth.serveftp.org` a na to, že přímý přístup mimo Traefik firewall pustí jen z očekávané adresy.
