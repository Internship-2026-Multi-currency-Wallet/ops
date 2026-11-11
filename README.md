# ops

Infrastructure for the white-label multi-currency wallet. Today it contains the **local development stack**:
`docker-compose.yml` (MySQL, Redis, the three backend services and both frontends) and `dev.sh`, the one script
that starts it.

**Infrastructure is always on, every application service is opt-in.** You usually work on one service from source
(`npm run start:dev`) and need only MySQL + Redis, maybe plus one or two other services in Docker.

It also holds the **deploy workflows** shared by all repositories (see [Deployment](#deployment)). Release
automation (cut-release, fan-out, cherry-pick) and the list of clients will live here too — those are tasks.

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
./dev.sh up                                   # infrastructure only: MySQL (all databases) + Redis + Mailpit
./dev.sh up rates-service                     # + rates-service in a container
./dev.sh up rates-service treasury-service    # + several services
./dev.sh up all                               # the whole system (what `docker compose up` used to do)
```

| Command                               | What it does                                                                                         |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `./dev.sh up [service...\|all]`       | Start MySQL + Redis + Mailpit and the named services; wait until healthy; print ports and env values |
| `./dev.sh up <service...> --no-build` | The same without rebuilding the images (by default the named services are rebuilt, one at a time)    |
| `./dev.sh build <service...\|all>`    | Build images one at a time                                                                           |
| `./dev.sh down`                       | Stop the whole stack (data is kept)                                                                  |
| `./dev.sh down <service...>`          | Stop and remove only these containers, e.g. to run that service from source instead                  |
| `./dev.sh down --volumes`             | Stop the whole stack and **delete all data** (MySQL, Redis)                                          |
| `./dev.sh ps`                         | Containers and their health                                                                          |
| `./dev.sh logs [service...]`          | Follow the logs                                                                                      |
| `./dev.sh info`                       | Print the ports table and the env values for services run from source                                |

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

| Service          | URL                                             | Notes                                                                                  |
| ---------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------- |
| client-web       | <http://localhost:8080>                         | Built static app, dev user `1:wallet` (`npm run dev`: :5173)                           |
| back-office      | <http://localhost:8081>                         | Built static app, dev user `100:bo:users,bo:users:modify` (`npm run dev`: :5174)       |
| wallet-core      | <http://localhost:3000/graphql> · `/health`     | GraphQL (Apollo Sandbox in the browser)                                                |
| rates-service    | <http://localhost:3001/graphql> · `/health`     | Subscriptions: `ws://localhost:3001/graphql`                                           |
| treasury-service | <http://localhost:3002/graphql> · `/health`     | Gateway + worker in one container                                                      |
| MySQL 8.4        | `localhost:3306`                                | User `wallet` / `wallet`; databases `wallet_core`, `rates_service`, `treasury_service` |
| Redis 8          | `localhost:6379`                                | Events (pub/sub, streams) and BullMQ                                                   |
| Mailpit          | <http://localhost:8025> · SMTP `localhost:1025` | Local email catcher: every email sent by a service shows up in the web UI              |

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
| `EMAIL_TRANSPORT`      | `smtp`                                              | `smtp`                                 |
| `SMTP_URL`             | `smtp://localhost:1025`                             | `smtp://mailpit:1025`                  |
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
payment provider: <https://paygate.wallet.shatori.com> (API docs at `/docs`). You get API keys per environment
from the mentor; keep them in your local `.env` files, never in Git.

## Deployment

Three environments, each serving one client. **Deploys happen only through CI** — a push (a merged PR) to the branch
deploys that environment; nobody deploys by hand.

| Environment (`APP_ENV`) | Branch              | `CLIENT` | `DEV_AUTH` |
| ----------------------- | ------------------- | -------- | ---------- |
| `staging`               | `main`              | `demo`   | `true`     |
| `kvitka-uat`            | `client/kvitka-uat` | `kvitka` | `false`    |
| `wisla-uat`             | `client/wisla-uat`  | `wisla`  | `false`    |

### Hostnames

| What             | Host                                           | Runs on          |
| ---------------- | ---------------------------------------------- | ---------------- |
| client-web       | `https://<env>.wallet.shatori.com`             | Cloudflare Pages |
| back-office      | `https://<env>-admin.wallet.shatori.com`       | Cloudflare Pages |
| wallet-core      | `https://<env>-wallet-core.wallet.shatori.com` | VPS (Dokploy)    |
| rates-service    | `https://<env>-rates.wallet.shatori.com`       | VPS (Dokploy)    |
| treasury-service | `https://<env>-treasury.wallet.shatori.com`    | VPS (Dokploy)    |
| PayGate (shared) | `https://paygate.wallet.shatori.com`           | VPS (Dokploy)    |

Backends serve GraphQL at `/graphql` (subscriptions: `wss://` on the same path) and `/health`. Their `CORS_ORIGINS`
are the environment's client-web and back-office hosts. DNS: a wildcard `*.wallet` record points to the VPS
(backends, PayGate); each frontend host has its own CNAME to its Pages project (created by the deploy workflow).

### How CD works

Each app repository has a thin `.github/workflows/deploy.yml` (on push to `main`, `client/kvitka-uat`,
`client/wisla-uat`, and `workflow_dispatch`) that calls a reusable workflow here:

- **`deploy-service.yml`** (wallet-core, rates-service, treasury-service, paygate):
  1. resolve the environment from the branch (`main` → `staging`, `client/<c>-uat` → `<c>-uat`);
  2. build the Docker image in GitHub Actions (`APP_VERSION` = commit SHA) and push it to
     `ghcr.io/internship-2026-multi-currency-wallet/<repo>` as `<env>-<sha>` and `<env>-latest`;
  3. point the Dokploy application `<repo>` in environment `<env>` of project _Internship 2026_ at `<env>-<sha>` and
     redeploy it through the Dokploy API (looked up by name, no ids in Git);
  4. wait for the Dokploy deployment, then poll `https://<env>-<service>.wallet.shatori.com/health` until it is `ok`
     **and** reports the new SHA as `version`; otherwise the job fails. Docker Swarm starts the new container first
     and rolls back automatically if it never becomes healthy.
- **`deploy-pages.yml`** (client-web, back-office): resolve the environment, `npm ci && npm run build` with that
  environment's `VITE_APP_ENV`, `VITE_CLIENT` and (staging only) `VITE_DEV_USER`, upload `dist/` with
  `wrangler pages deploy` to the Pages project `<app>-<env>` (e.g. `client-web-staging`). The same job creates the
  Pages project, the custom domain and the DNS CNAME if they are missing (idempotent), then waits until the host
  serves exactly this build and a deep link returns the app (SPA fallback).
- **`pages-domains.yml`** (manual): shows the state of all Pages custom domains and DNS records and can re-attach a
  domain stuck in _pending_.

The backends apply their migrations on start (container command `npm run migrate && node dist/main.js`).

### Redeploy

- Same commit again: _Actions → Deploy → Run workflow_ on the branch of the environment (or re-run the last run).
- Roll back: revert the commit on the branch (a normal PR) — the revert deploys like any change.
- Do not use the Dokploy _Deploy_ button for images that are not public (PayGate, or a new package not yet made
  public): Dokploy pulls them with the short-lived token of the CI job.

### Where things live (names only — values are never in Git)

| What                   | Where                                                                                                                                                                                                                                                                                                |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Dokploy project        | _Internship 2026_: environments `shared` (MySQL `mysql`, Redis `redis`, app `paygate`, compose `logging`), `staging`, `kvitka-uat`, `wisla-uat` (apps `wallet-core`, `rates-service`, `treasury-service`)                                                                                            |
| Backend runtime config | Dokploy → app → _Environment_: `APP_ENV`, `CLIENT`, `DEV_AUTH`, `DATABASE_URL`, `REDIS_URL`, `CORS_ORIGINS`, `NODE_OPTIONS`, `*_SERVICE_URL`, `ROLE` (treasury)                                                                                                                                      |
| MySQL                  | One instance, databases `<env>_<service>` (e.g. `staging_wallet_core`); one user per environment (`staging`, `kvitka_uat`, `wisla_uat`) with access to its own databases only. Passwords: Dokploy → `mysql` (root/staging) and its _Environment_ (`KVITKA_UAT_DB_PASSWORD`, `WISLA_UAT_DB_PASSWORD`) |
| Redis                  | One instance; environments isolated by the `APP_ENV` key/channel prefix. Password: Dokploy → `redis`                                                                                                                                                                                                 |
| PayGate secrets        | Dokploy → `paygate` → _Environment_: `PAYGATE_ADMIN_PASSWORD`, `PAYGATE_MERCHANT_<ID>_API_KEY` / `_WEBHOOK_SECRET` (ids `STAGING`, `KVITKA_UAT`, `WISLA_UAT`); config file mount `/etc/paygate/config.toml`, volume `paygate-data`                                                                   |
| GitHub secrets         | Repository secrets `DOKPLOY_URL`, `DOKPLOY_TOKEN` (backends, paygate); organization secrets `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` (frontends, ops)                                                                                                                                         |

Memory limits: backends 256 MB (`--max-old-space-size=192`), MySQL 512 MB, Redis 256 MB (reservation 64 MB), PayGate 64 MB; logging stack
see [Logging](#logging).

## Email

- **Provider**: [Resend](https://resend.com). Only `wallet-core` sends email (`src/email`).
- **Domain**: `wallet.shatori.com`, verified in Resend (SPF, DKIM, DMARC records are in Cloudflare DNS, added by the
  mentor). Sender address `no-reply@wallet.shatori.com` for every environment; the display name comes from the
  client's brand, e.g. `Kvitka Bank <no-reply@wallet.shatori.com>`.
- **Where the key lives**: one API key for all environments (sending access only, limited to the domain). Dokploy →
  _Internship 2026_ → `staging`, `kvitka-uat`, `wisla-uat` → `wallet-core` → _Environment_. The team and the mentor
  get it through the password manager / GitHub organization secrets. Never in Git, Asana or logs.
- **Configuration per environment** (Dokploy → `wallet-core` → _Environment_):

  | Variable          | Staging, kvitka-uat, wisla-uat | Local                   |
  | ----------------- | ------------------------------ | ----------------------- |
  | `EMAIL_TRANSPORT` | `resend`                       | `smtp`                  |
  | `RESEND_API_KEY`  | the key                        | — (no key locally)      |
  | `EMAIL_FROM`      | `no-reply@wallet.shatori.com`  | —                       |
  | `SMTP_URL`        | —                              | `smtp://localhost:1025` |

- **Local emails**: Mailpit starts with `./dev.sh up`. Open <http://localhost:8025> — every email a service sends is
  there; nothing leaves your machine. SMTP is `localhost:1025` (`smtp://mailpit:1025` from a container, already set
  for `wallet-core`). Ports can be changed with `MAILPIT_SMTP_PORT` / `MAILPIT_UI_PORT` in `.env`. Emails are kept
  until Mailpit is restarted.
- **Check a deployed environment**: send a test email to a Gmail address and make sure it lands in _Inbox_, not
  _Spam_ (Gmail → _Show original_ should say `SPF: PASS`, `DKIM: PASS`, `DMARC: PASS`). Resend → _Emails_ shows
  delivery status.

## Logging

```
backend containers (JSON lines on stdout) ──┐
shared Redis / MySQL (plain text on stdout) ─┼─► Alloy ──► Loki (14 days, filesystem) ──► Grafana
docker-events (die/oom events, JSON) ────────┘  Docker API  internal network only       https://logs.wallet.shatori.com
```

- **In code** (all three backends): `nestjs-pino`, one JSON line per event with `service`, `appEnv`, `client`, `level`,
  `context`, `requestId`; an access line per HTTP request; secrets redacted. How to log and how to search:
  the handbook's `logging.md`.
- **Collection**: the Dokploy Compose service `logging` (environment `shared`) runs Loki, Grafana, Alloy and
  `docker-events` from [`logging/docker-compose.yml`](logging/docker-compose.yml) (all configs inline; no secrets in
  the file). Alloy reads the Docker logs of our containers **only**:
  - backends (container names `<env>-<wallet-core|rates-service|treasury-service>-…`): labels `env`, `service`,
    `level` from the JSON line;
  - the shared Redis and MySQL (`internship-<redis|mysql>-…`): `env="shared"`, `service="redis"` / `"mysql"` from
    the container name; their lines are plain text, so they have no `level`;
  - `docker-events`, a small sidecar that prints one JSON line per `die` / `oom` event of those containers,
    e.g. `{"action":"die","container":"internship-redis-…","exitCode":"137"}`; Alloy gives each event the `env` /
    `service` of the container it is about, so `{service="redis"}` shows Redis's own lines and its die events in
    one time-ordered list. Events also get `level`: `error` for `oom` and for any exit code except 0 and 143
    (killed, crash), `info` for exit codes 0 and 143 (normal stop or restart); Redis/MySQL lines still have none.
    Events are lost while the `docker-events` container itself is down (for example while it is recreated by a
    deploy that changes it, or during a Docker daemon restart); there are no duplicates.

  Container names of other projects on the server never reach Loki (and are filtered out inside `docker-events`
  already). Loki is not published; Grafana is the only entry point.
- **Grafana**: <https://logs.wallet.shatori.com>. Provisioned data source _Loki_ and the dashboard
  _Internship → Logs_ (filters env/service/level, error count, error/warning graph, logs panel, search by
  `requestId` or text). Anonymous access and sign-up are disabled.
- **Admin password**: Dokploy → _Internship 2026_ → `shared` → `logging` → _Environment_ → `GRAFANA_ADMIN_PASSWORD`
  (user `admin`). Changing it there only affects a fresh Grafana volume; afterwards change it in Grafana
  (_Profile → Change password_).
- **Intern accounts** (mentor): _Administration → Users and access → Users → New user_, set a temporary password,
  role **Viewer** in the main organization (the default for new users). Interns change the password at first login.
- **Where to look**: dashboard _Logs_ for day-to-day; _Explore_ for ad-hoc LogQL; `{env="staging"} |= "<requestId>"`
  follows one request across services. Quick end-to-end check:
  `curl -X POST https://staging-wallet-core.wallet.shatori.com/diagnostics/ping -H 'Authorization: Dev 1:wallet' -H 'x-request-id: check-1'`
  and search `check-1`.
- **Update the stack**: open a PR that changes `logging/docker-compose.yml`. The Dokploy service `logging` takes this
  file from GitHub (`ops`, `main`, watch path `logging/**`), so merging the PR deploys it automatically — test the
  change locally first and never edit the compose in the Dokploy UI. Deployment logs: Dokploy → _Internship 2026_ →
  `shared` → `logging` → _Deployments_. Memory limits: Loki 256 MB, Grafana 256 MB (Grafana 12 idles at ~190 MB, so 200 MB was too tight),
  Alloy 128 MB, docker-events 32 MB.

## PR review (PR-Agent)

Every pull request in the organization gets an AI review from [PR-Agent](https://github.com/The-PR-Agent/pr-agent)
(model `gpt-6.1-sol`, OpenAI API). It is advice, not a gate: the human approvals stay required.

- **When**: PR opened, reopened or marked _Ready for review_ → `/describe` (title/summary) + `/review`; every push to
  the PR branch → `/review` again. Draft PRs are skipped. On demand, comment `/review`, `/describe`, `/improve` or
  `/ask "<question>"` on a PR.
- **Runs**: the Dokploy Compose service `pr-agent` (environment `shared`) from
  [`pr-agent/docker-compose.yml`](pr-agent/docker-compose.yml) — source GitHub (`ops`, `main`), auto deploy, watch path
  `pr-agent/**`. Webhook `https://pr-agent.wallet.shatori.com/api/v1/github_webhooks`. Memory limit 640 MB. The image
  is built on deploy from [`pr-agent/Dockerfile`](pr-agent/Dockerfile): the upstream image plus one patch (below).
- **GitHub App** _PR-Agent_ (organization settings → GitHub Apps), installed on all repositories. Permissions: Pull
  requests R/W, Issues R/W, Contents R, Metadata R. Events: Pull request, Issue comment, Pull request review comment.
- **Secrets**: Dokploy → `pr-agent` → _Environment_: `PR_AGENT_GITHUB_APP_ID`, `PR_AGENT_GITHUB_WEBHOOK_SECRET`,
  `PR_AGENT_GITHUB_PRIVATE_KEY_B64` (the app's `.pem`, base64 in one line), `PR_AGENT_OPENAI_KEY`.
- **Review prompt**: `PR_REVIEWER__EXTRA_INSTRUCTIONS` in the compose file — appended to PR-Agent's built-in prompt
  (critical stance, project context, risks to check, comment discipline, severity + fix per finding). One review
  summary per PR, updated on every push, plus each finding as an inline comment on its line; up to 7 findings.
- **Test files are not reviewed**: `IGNORE__GLOB` drops `*.spec.*`, `*.e2e-spec.*` and `*.test.*` (in any directory)
  from the diff for every command, and the "does the PR include tests" check is off, since it would see no tests.
- **Is it running?** Automatic runs show up in the PR checks as _PR Agent - Review_ / _PR Agent - Describe_:
  _in progress_ while working, then done. The review summary is one PR comment, _PR Reviewer Guide_, updated on every
  push (with run details: model, tokens, time, cost); the findings are inline comments in the diff. Commands typed in a comment get 👀 when picked
  up, then 🚀 (success) or 😕 (failure). Needs the App permission _Checks: read & write_.
- **No repeated findings**: the review comment keeps every finding in a hidden marker, and the next `/review` gets
  them in its prompt: a finding that still applies is repeated word for word, so its inline comment is recognised as
  already posted (`CONFIG__PERSISTENT_INLINE_COMMENTS`) instead of being posted again in new words. To close a finding
  you will not fix, reply with the reason and _Resolve conversation_: later reviews do not raise it again. Upstream
  PR-Agent turns this memory off when results go to check runs; [`patch-review-memory.py`](pr-agent/patch-review-memory.py)
  keeps it on (the check run still shows progress), and the image build fails if a PR-Agent upgrade breaks the patch.
- **Per-repository settings**: a `.pr_agent.toml` in the repository root (default branch) overrides the defaults from
  the compose file. `[pr_reviewer] extra_instructions` there **replaces** the shared prompt, so copy it and extend.
- **Cost**: roughly $0.05–0.30 per run, paid from the OpenAI API balance; keep a monthly budget limit on the OpenAI
  project.

## Not here yet

- CI checks on pull requests (lint, type check, tests) — a task.
- Release automation (cut-release, fan-out, cherry-pick) and `clients.yml` — tasks.
- Seed data — will be added later.
