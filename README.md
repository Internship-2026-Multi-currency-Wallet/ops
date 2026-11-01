# ops

Infrastructure for the white-label multi-currency wallet. Today it contains the **local development stack**:
`docker-compose.yml` (MySQL, Redis, the three backend services and both frontends) and `dev.sh`, the one script
that starts it.

**Infrastructure is always on, every application service is opt-in.** You usually work on one service from source
(`npm run start:dev`) and need only MySQL + Redis, maybe plus one or two other services in Docker.

Shared CI/CD workflows, release automation and the list of clients and environments will live here too —
those are tasks.

## Prerequisites

- Docker with Compose v2 (`docker compose version`; the standalone `docker-compose` binary works too)
- Git, Node.js 26 (to run services from source)
- Bash (macOS or Linux)

**Docker memory.** MySQL + Redis need well under 1 GiB. Building images is what needs memory: parallel builds
crash a Docker VM with 2 GiB of RAM. `dev.sh` therefore builds one image at a time. If you build with plain
`docker compose` or run the whole stack often, give Docker at least 4 GiB (Docker Desktop: _Settings → Resources_;
Colima: `colima start --memory 4`).

## 1. Clone all repositories side by side

The compose file builds the services from sibling folders, and every app repository calls `../ops/dev.sh`:

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

## 2. Start what you need — `dev.sh`

```sh
cd ops
./dev.sh up                                   # infrastructure only: MySQL (all databases) + Redis
./dev.sh up rates-service                     # + rates-service in a container
./dev.sh up rates-service treasury-service    # + several services
./dev.sh up all                               # the whole system (what `docker compose up` used to do)
```

| Command                               | What it does                                                                                      |
| ------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `./dev.sh up [service...\|all]`       | Start MySQL + Redis and the named services; wait until healthy; print ports and env values        |
| `./dev.sh up <service...> --no-build` | The same without rebuilding the images (by default the named services are rebuilt, one at a time) |
| `./dev.sh build <service...\|all>`    | Build images one at a time                                                                        |
| `./dev.sh down`                       | Stop the whole stack (data is kept)                                                               |
| `./dev.sh down <service...>`          | Stop and remove only these containers, e.g. to run that service from source instead               |
| `./dev.sh down --volumes`             | Stop the whole stack and **delete all data** (MySQL, Redis)                                       |
| `./dev.sh ps`                         | Containers and their health                                                                       |
| `./dev.sh logs [service...]`          | Follow the logs                                                                                   |
| `./dev.sh info`                       | Print the ports table and the env values for services run from source                             |

Services: `wallet-core`, `rates-service`, `treasury-service`, `client-web`, `back-office`. Unknown names are
rejected. The script works from any folder and on macOS (bash 3.2) and Linux.

From an app repository you do not need to `cd` here — every app has the same commands as npm scripts:

```sh
npm run infra:up                              # = ../ops/dev.sh up
npm run infra -- up rates-service             # = ../ops/dev.sh up rates-service
npm run infra:ps                              # = ../ops/dev.sh ps
npm run infra:down                            # = ../ops/dev.sh down
```

The first build of a service takes a few minutes. The backends apply their database migrations on start.

| Service          | URL                                         | Notes                                                                                  |
| ---------------- | ------------------------------------------- | -------------------------------------------------------------------------------------- |
| client-web       | <http://localhost:8080>                     | Built static app, dev user `1:wallet` (`npm run dev`: :5173)                           |
| back-office      | <http://localhost:8081>                     | Built static app, dev user `100:bo:users,bo:users:modify` (`npm run dev`: :5174)       |
| wallet-core      | <http://localhost:3000/graphql> · `/health` | GraphQL (Apollo Sandbox in the browser)                                                |
| rates-service    | <http://localhost:3001/graphql> · `/health` | Subscriptions: `ws://localhost:3001/graphql`                                           |
| treasury-service | <http://localhost:3002/graphql> · `/health` | Gateway + worker in one container                                                      |
| MySQL 8.4        | `localhost:3306`                            | User `wallet` / `wallet`; databases `wallet_core`, `rates_service`, `treasury_service` |
| Redis 8          | `localhost:6379`                            | Events (pub/sub, streams) and BullMQ                                                   |

A service has the same port whether it runs in Docker or from source, so the other services and the frontends do
not care where it runs. Host ports can be changed in `.env` (`cp .env.example .env`).

## 3. Run a service from source against the stack

```sh
cd ops && ./dev.sh up rates-service        # infrastructure + whatever else you need in Docker
cd ../wallet-core
npm install
npm run migrate
DEV_AUTH=true npm run start:dev
```

The service defaults (`.env.example` of each backend) already point at the stack; only `DEV_AUTH=true` has to be
set. `./dev.sh up` and `./dev.sh info` print the values:

| Variable               | Service run from source (host)                      | Service in a container (preconfigured) |
| ---------------------- | --------------------------------------------------- | -------------------------------------- |
| `DATABASE_URL`         | `mysql://wallet:wallet@localhost:3306/<service_db>` | `mysql://wallet:wallet@mysql:3306/...` |
| `REDIS_URL`            | `redis://localhost:6379`                            | `redis://redis:6379`                   |
| `WALLET_CORE_URL`      | `http://localhost:3000`                             | `http://host.docker.internal:3000`     |
| `RATES_SERVICE_URL`    | `http://localhost:3001`                             | `http://host.docker.internal:3001`     |
| `TREASURY_SERVICE_URL` | `http://localhost:3002`                             | `http://host.docker.internal:3002`     |

How the pieces reach each other:

- **Containers → infrastructure:** by service name (`mysql:3306`, `redis:6379`).
- **Host → anything:** `localhost:<port>`; every container publishes its port.
- **Container → another backend:** `host.docker.internal:<port>`. That address is the host, so it works both when
  the other backend runs in a container (published port) and when it runs from source on your machine. Docker
  Desktop and Colima provide it; on Linux the compose file maps it with `host-gateway`. The `*_SERVICE_URL`
  variables are the names to use when a service starts calling another one.

Do not run the same service twice: if it is running in Docker, stop it first (`./dev.sh down wallet-core`), otherwise
`npm run start:dev` fails with "port already in use".

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
Dev auth is for local development only; real login replaces it. The backends refuse to start with
`DEV_AUTH=true` when `APP_ENV` is a client UAT (`kvitka-uat`, `wisla-uat`); locally `APP_ENV=local`.
All Redis channels, streams and queues are prefixed with `APP_ENV` (e.g. `local:rate.tick`).

## Common tasks

| Task                             | Command                                                         |
| -------------------------------- | --------------------------------------------------------------- |
| Rebuild and restart one service  | `./dev.sh up wallet-core`                                       |
| Logs of a service                | `./dev.sh logs treasury-service`                                |
| Run migrations again (container) | `docker compose exec wallet-core npm run migrate`               |
| Migration status (container)     | `docker compose exec wallet-core npm run migrate:status`        |
| MySQL shell                      | `docker compose exec mysql mysql -uwallet -pwallet wallet_core` |
| Redis shell                      | `docker compose exec redis redis-cli`                           |
| Stop                             | `./dev.sh down`                                                 |
| Stop and **delete all data**     | `./dev.sh down --volumes`                                       |

### How it works

Plain Compose profiles: `mysql` and `redis` have no profile, so they always start (a bare `docker compose up` starts
only them). Every application service has a profile named after itself plus `all`; naming a service on the command
line enables it. `dev.sh` adds validation, one-at-a-time builds, `--wait` for healthchecks, and the info output.
There is one compose file and one script for the whole system: app repositories only delegate to it.

## Switching the client

Each deployment serves exactly one client, chosen by `CLIENT` (`demo`, `kvitka`, `wisla`). Locally:

```sh
CLIENT=kvitka ./dev.sh up all
```

or set `CLIENT=kvitka` in `.env`. The backends report it in `health { client }`. The frontends get it at build
time (`VITE_CLIENT`); `./dev.sh up` rebuilds the named services. All clients share the local databases; use
`./dev.sh down --volumes` for a clean start when switching if data gets in the way.

## PayGate

PayGate (the sandbox card payment gateway) is **not** part of this stack. It is an external service, like a real
payment provider: `https://paygate.wallet.shatori.com` (API docs at `/docs`). You get API keys per environment
from the mentor; keep them in your local `.env` files, never in Git.

## Not here yet

- CI workflows (reusable PR checks) and deploy workflows — tasks.
- Seed data — will be added later.
