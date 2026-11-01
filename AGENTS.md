# AGENTS.md — conventions for AI coding agents

This is `ops`: docker-compose and `dev.sh` for local development (later also CI/CD workflows). Read `README.md` first.

- Keep the stack working from a clean state: `./dev.sh down --volumes && ./dev.sh up all`.
- Infrastructure (`mysql`, `redis`) has no profile and always starts; every application service has the profiles
  `[<service>, all]`. A new service also goes into `SERVICES` (and `port_of`) in `dev.sh`.
- `dev.sh` is the single entry point (app repos call it via `npm run infra`). Keep it bash 3.2 compatible (macOS)
  and build images one at a time.
- Every service has a healthcheck; dependents use `depends_on: condition: service_healthy`.
- Services are built from sibling folders (`../<repo>`); do not copy service code here.
- Configuration via environment variables with defaults (`${VAR:-default}`); document every variable in
  `.env.example` and the README. Local-only placeholder passwords are fine; real secrets never.
- New service or port → update the ports table in `README.md`.
- This repository is public: no secrets, tokens, internal host names or machine-specific paths.
- English only. Conventional Commits (`ci: ...`, `chore(compose): ...`). PRs use `.github/pull_request_template.md`.
