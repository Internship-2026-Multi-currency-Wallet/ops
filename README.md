# ops

Infrastructure for the white-label multi-currency wallet. Today it contains the **local development stack**
(`docker-compose.yml`): MySQL, Redis, the three backend services and both frontends.

Shared CI/CD workflows, release automation and the list of clients and environments will live here too —
those are tasks.

## Prerequisites

- Docker with Compose v2 (`docker compose version`), at least 8 GB of RAM for Docker
- Git, Node.js 26 (only to run services outside Docker)

## 1. Clone all repositories side by side

The compose file builds the services from sibling folders:

```sh
mkdir wallet && cd wallet
for repo in ops wallet-core rates-service treasury-service client-web back-office; do
  git clone git@github.com:Internship-2026-Multi-currency-Wallet/$repo.git
done
```

```
wallet/
  ops/  wallet-core/  rates-service/  treasury-service/  client-web/  back-office/
```

## 2. Start everything

```sh
cd ops
cp .env.example .env     # optional — the defaults work out of the box
docker compose up --build
```

The first build takes a few minutes. Every service has a healthcheck; `docker compose ps` shows `healthy` when ready.
The backends apply their database migrations on start.

| Service          | URL                                         | Notes                                                                                  |
| ---------------- | ------------------------------------------- | -------------------------------------------------------------------------------------- |
| client-web       | <http://localhost:8080>                     | Built static app, dev user `1:wallet`                                                  |
| back-office      | <http://localhost:8081>                     | Built static app, dev user `100:bo:users,bo:users:modify`                              |
| wallet-core      | <http://localhost:3000/graphql> · `/health` | GraphQL (Apollo Sandbox in the browser)                                                |
| rates-service    | <http://localhost:3001/graphql> · `/health` | Subscriptions: `ws://localhost:3001/graphql`                                           |
| treasury-service | <http://localhost:3002/graphql> · `/health` | Gateway + worker in one container                                                      |
| MySQL 8.4        | `localhost:3306`                            | User `wallet` / `wallet`; databases `wallet_core`, `rates_service`, `treasury_service` |
| Redis 8          | `localhost:6379`                            | Events (pub/sub, streams) and BullMQ                                                   |

Host ports can be changed in `.env`.

### Check that it works

```sh
curl -s localhost:3000/health
curl -s localhost:3000/graphql -H 'content-type: application/json' \
  -H 'Authorization: Dev 1:wallet' -d '{"query":"{ me { id permissions } }"}'
# without the Authorization header the same query returns UNAUTHENTICATED
```

## Dev auth

The backends run with `DEV_AUTH=true` in this stack, so any request can authenticate with

```
Authorization: Dev <userId>:<perm1,perm2>      e.g.  Dev 1:wallet   or   Dev 100:bo:users,bo:users:modify
```

(for GraphQL subscriptions: the same value as `Authorization` in the graphql-ws connection params).
The frontends send the dev user configured at build time (`CLIENT_WEB_DEV_USER`, `BACK_OFFICE_DEV_USER`).
Dev auth is for local development only; real login replaces it.

## Common tasks

| Task                                                             | Command                                                         |
| ---------------------------------------------------------------- | --------------------------------------------------------------- |
| Start only MySQL + Redis (run services with `npm run start:dev`) | `docker compose up -d mysql redis`                              |
| Rebuild one service after code changes                           | `docker compose up -d --build wallet-core`                      |
| Logs of a service                                                | `docker compose logs -f treasury-service`                       |
| Run migrations again                                             | `docker compose exec wallet-core npm run migrate`               |
| Migration status                                                 | `docker compose exec wallet-core npm run migrate:status`        |
| MySQL shell                                                      | `docker compose exec mysql mysql -uwallet -pwallet wallet_core` |
| Redis shell                                                      | `docker compose exec redis redis-cli`                           |
| Stop                                                             | `docker compose down`                                           |
| Stop and **delete all data**                                     | `docker compose down -v`                                        |

Running a service from source against this stack: `docker compose up -d mysql redis`, then in the service folder
`npm run migrate && DEV_AUTH=true npm run start:dev` (its defaults point at `localhost:3306` / `localhost:6379`).
Stop the container of that service first (`docker compose stop wallet-core`) — or use another `PORT` — so the ports
do not clash.

## Switching the client

Each deployment serves exactly one client, chosen by `CLIENT` (`demo`, `kvitka`, `wisla`). Locally:

```sh
CLIENT=kvitka docker compose up -d --build
```

or set `CLIENT=kvitka` in `.env`. The backends report it in `health { client }`. The frontends get it at build
time (`VITE_CLIENT`), hence `--build`. All clients share the local databases; use `docker compose down -v` for a
clean start when switching if data gets in the way.

## PayGate

PayGate (the sandbox card payment gateway) is **not** part of this stack. It is an external service, like a real
payment provider: `https://paygate.wallet.shatori.com` (API docs at `/docs`). You get API keys per environment
from the mentor; keep them in your local `.env` files, never in Git.

## Not here yet

- CI workflows (reusable PR checks) and deploy workflows — tasks.
- Seed data — will be added later.
