#!/usr/bin/env bash
# Local development stack: infrastructure (MySQL + Redis) always, application services on demand.
#
#   ./dev.sh up                                  infrastructure only
#   ./dev.sh up rates-service treasury-service   infrastructure + these services in containers
#   ./dev.sh up all                              everything
#   ./dev.sh help                                all commands
#
# Works on macOS (bash 3.2) and Linux. Run it from anywhere; it finds docker-compose.yml next to itself.

set -euo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$OPS_DIR")"
cd "$OPS_DIR"

SERVICES="wallet-core rates-service treasury-service client-web back-office"
INFRA="mysql redis mailpit"
OBSERVABILITY_PROJECT="wallet-observability"

die() {
  printf 'dev.sh: %s\n' "$*" >&2
  exit 1
}

# --- docker compose (v2 plugin or the standalone docker-compose binary) -----------------------------

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  die "Docker Compose v2 not found. Install Docker Desktop, or Docker Engine with the compose plugin."
fi

compose() {
  "${COMPOSE[@]}" "$@"
}

# All profiles active: needed so that ps/logs/down also see the opt-in services.
compose_all() {
  "${COMPOSE[@]}" --profile all "$@"
}

compose_observability() {
  GRAFANA_PORT="$GRAFANA_PORT" PROMETHEUS_PORT="$PROMETHEUS_PORT" \
    GRAFANA_ADMIN_PASSWORD=admin GRAFANA_SMTP_PASSWORD=unused \
    "${COMPOSE[@]}" -p "$OBSERVABILITY_PROJECT" \
    -f logging/docker-compose.yml -f logging/docker-compose.local.yml "$@"
}

# --- configuration: environment variable > ops/.env > default (same order as docker compose) --------

env_value() {
  local key="$1" default="$2" value=""
  if [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
    return
  fi
  if [ -f "$OPS_DIR/.env" ]; then
    value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$OPS_DIR/.env" | tail -n 1)"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
  fi
  printf '%s' "${value:-$default}"
}

MYSQL_PORT="$(env_value MYSQL_PORT 3306)"
REDIS_PORT="$(env_value REDIS_PORT 6379)"
MAILPIT_SMTP_PORT="$(env_value MAILPIT_SMTP_PORT 1025)"
MAILPIT_UI_PORT="$(env_value MAILPIT_UI_PORT 8025)"
GRAFANA_PORT="$(env_value GRAFANA_PORT 3300)"
PROMETHEUS_PORT="$(env_value PROMETHEUS_PORT 9090)"
MYSQL_USER="$(env_value MYSQL_USER wallet)"
MYSQL_PASSWORD="$(env_value MYSQL_PASSWORD wallet)"
APP_ENV="$(env_value APP_ENV local)"
CLIENT="$(env_value CLIENT demo)"
JWT_SECRET="$(env_value JWT_SECRET local-docker-jwt-secret-not-for-servers-01)"

port_of() {
  case "$1" in
    wallet-core) env_value WALLET_CORE_PORT 3000 ;;
    rates-service) env_value RATES_SERVICE_PORT 3001 ;;
    treasury-service) env_value TREASURY_SERVICE_PORT 3002 ;;
    client-web) env_value CLIENT_WEB_PORT 8080 ;;
    back-office) env_value BACK_OFFICE_PORT 8081 ;;
    mysql) printf '%s' "$MYSQL_PORT" ;;
    redis) printf '%s' "$REDIS_PORT" ;;
    mailpit) printf '%s' "$MAILPIT_UI_PORT" ;;
  esac
}

database_of() {
  case "$1" in
    wallet-core) printf 'wallet_core' ;;
    rates-service) printf 'rates_service' ;;
    treasury-service) printf 'treasury_service' ;;
  esac
}

is_backend() {
  case "$1" in wallet-core | rates-service | treasury-service) return 0 ;; *) return 1 ;; esac
}

# --- argument validation ------------------------------------------------------------------------------

is_service() {
  local s
  for s in $SERVICES; do [ "$s" = "$1" ] && return 0; done
  return 1
}

is_known() {
  local s
  for s in $SERVICES $INFRA; do [ "$s" = "$1" ] && return 0; done
  return 1
}

# Validates names and stores the application services in RESOLVED ("all" expands to every service).
# mysql/redis are accepted and skipped: the infrastructure always runs.
RESOLVED=()
resolve_services() {
  local name
  RESOLVED=()
  for name in "$@"; do
    case "$name" in
      all)
        RESOLVED=($SERVICES)
        return
        ;;
      mysql | redis | mailpit) ;;
      *) is_service "$name" || die "unknown service '$name'. Known: $SERVICES (or 'all')." ;;
    esac
  done
  for name in "$@"; do
    if is_service "$name"; then RESOLVED+=("$name"); fi
  done
}

require_repo() {
  [ -d "$ROOT_DIR/$1" ] || die "$1 is not cloned. Clone it next to ops: $(basename "$ROOT_DIR")/$1"
}

# --- commands -----------------------------------------------------------------------------------------

# Builds images one at a time: parallel builds run out of memory on a Docker VM with 2 GiB of RAM.
build_one_by_one() {
  local s
  for s in "$@"; do
    require_repo "$s"
    printf '\n==> Building %s\n' "$s"
    compose build "$s"
  done
}

cmd_up() {
  local build=1 observability=0 args=() services=() s
  for s in "$@"; do
    case "$s" in
      --no-build) build=0 ;;
      -*) die "unknown option '$s' for up" ;;
      observability) observability=1 ;;
      *) args+=("$s") ;;
    esac
  done
  if [ "${#args[@]}" -gt 0 ]; then
    resolve_services "${args[@]}"
    services=(${RESOLVED[@]+"${RESOLVED[@]}"})
  fi

  if [ "${#services[@]}" -gt 0 ] && [ "$build" -eq 1 ]; then
    build_one_by_one "${services[@]}"
  fi

  printf '\n==> Starting %s\n' "$INFRA${services[*]:+ ${services[*]}}"
  # Naming a service on the command line enables its profile. --wait blocks until healthchecks pass.
  # shellcheck disable=SC2086
  compose up -d --no-build --wait $INFRA ${services[@]+"${services[@]}"}

  if [ "$observability" -eq 1 ]; then
    printf '\n==> Starting observability: Loki, Prometheus, Grafana, Alloy\n'
    compose_observability up -d --wait
  fi

  print_info
}

cmd_down() {
  local volumes=() services=() everything=0 observability=0 s
  for s in "$@"; do
    case "$s" in
      -v | --volumes) volumes=(-v) ;;
      -*) die "unknown option '$s' for down" ;;
      all) everything=1 ;;
      observability) observability=1 ;;
      *)
        is_known "$s" || die "unknown service '$s'. Known: $INFRA $SERVICES observability (or 'all')."
        services+=("$s")
        ;;
    esac
  done

  if [ "$everything" -eq 0 ] && { [ "${#services[@]}" -gt 0 ] || [ "$observability" -eq 1 ]; }; then
    [ "${#volumes[@]}" -eq 0 ] || die "--volumes removes the data of the whole stack; use it without service names."
    if [ "$observability" -eq 1 ]; then
      compose_observability down --remove-orphans
    fi
    if [ "${#services[@]}" -gt 0 ]; then
      compose_all stop "${services[@]}"
      compose_all rm -f "${services[@]}"
    fi
  else
    compose_observability down --remove-orphans ${volumes[@]+"${volumes[@]}"}
    compose_all down --remove-orphans ${volumes[@]+"${volumes[@]}"}
  fi
}

cmd_build() {
  [ "$#" -gt 0 ] || die "name the service(s) to build, e.g. ./dev.sh build wallet-core (or 'all')"
  resolve_services "$@"
  [ "${#RESOLVED[@]}" -gt 0 ] || die "mysql, redis and mailpit use prebuilt images; nothing to build."
  build_one_by_one "${RESOLVED[@]}"
}

cmd_logs() {
  local observability=0 s
  for s in "$@"; do
    case "$s" in
      -*) ;;
      observability) observability=1 ;;
      *) is_known "$s" || die "unknown service '$s'. Known: $INFRA $SERVICES observability." ;;
    esac
  done
  if [ "$observability" -eq 1 ]; then
    [ "$#" -eq 1 ] || die "follow the observability stack on its own: ./dev.sh logs observability"
    compose_observability logs -f --tail 200
    return
  fi
  compose_all logs -f --tail 200 "$@"
}

cmd_ps() {
  compose_all ps "$@"
  if [ "$#" -eq 0 ] && [ -n "$(compose_observability ps -q 2>/dev/null)" ]; then
    printf '\nObservability (project %s)\n' "$OBSERVABILITY_PROJECT"
    compose_observability ps
  fi
}

running_services() {
  compose_all ps --status running --services 2>/dev/null || true
}

print_info() {
  local running observability_running s port where
  running="$(running_services)"
  observability_running="$(compose_observability ps --status running --services 2>/dev/null || true)"
  is_running() { printf '%s\n' "$running" | grep -qx "$1"; }

  printf '\nPorts (host)\n'
  printf '  %-17s %-36s %s\n' "SERVICE" "URL" "RUNS"
  for s in $INFRA $SERVICES; do
    port="$(port_of "$s")"
    if is_running "$s"; then where="docker"; else where="-"; fi
    case "$s" in
      mysql) printf '  %-17s %-36s %s\n' "$s" "localhost:$port" "$where" ;;
      redis) printf '  %-17s %-36s %s\n' "$s" "localhost:$port" "$where" ;;
      mailpit) printf '  %-17s %-36s %s\n' "$s" "http://localhost:$port" "$where" ;;
      client-web | back-office) printf '  %-17s %-36s %s\n' "$s" "http://localhost:$port" "$where" ;;
      *) printf '  %-17s %-36s %s\n' "$s" "http://localhost:$port/graphql" "$where" ;;
    esac
  done
  for s in grafana prometheus; do
    if printf '%s\n' "$observability_running" | grep -qx "$s"; then where="docker"; else where="-"; fi
    if [ "$s" = grafana ]; then port="$GRAFANA_PORT"; else port="$PROMETHEUS_PORT"; fi
    printf '  %-17s %-36s %s\n' "$s" "http://localhost:$port" "$where"
  done
  printf '  ("-" = not in Docker: run it from source, or ./dev.sh up <service>;\n'
  printf '   grafana, prometheus: ./dev.sh up observability, Grafana login admin / admin)\n'

  printf '\nEnvironment for a service run on the host (npm run start:dev). The service defaults already match;\n'
  printf 'only DEV_AUTH=true (and JWT_SECRET, equal to the one of the backends in Docker) must be set, e.g. in its .env:\n'
  printf '  APP_ENV=%s CLIENT=%s DEV_AUTH=true\n' "$APP_ENV" "$CLIENT"
  printf '  JWT_SECRET=%s\n' "$JWT_SECRET"
  printf '  REDIS_URL=redis://localhost:%s\n' "$REDIS_PORT"
  printf '  EMAIL_TRANSPORT=smtp SMTP_URL=smtp://localhost:%s   (emails: http://localhost:%s)\n' "$MAILPIT_SMTP_PORT" "$MAILPIT_UI_PORT"
  for s in wallet-core rates-service treasury-service; do
    printf '  %-17s DATABASE_URL=mysql://%s:%s@localhost:%s/%s\n' \
      "$s" "$MYSQL_USER" "$MYSQL_PASSWORD" "$MYSQL_PORT" "$(database_of "$s")"
  done
  printf '  WALLET_CORE_URL=http://localhost:%s RATES_SERVICE_URL=http://localhost:%s TREASURY_SERVICE_URL=http://localhost:%s\n' \
    "$(port_of wallet-core)" "$(port_of rates-service)" "$(port_of treasury-service)"
  printf '  Containers reach a backend on the host at http://host.docker.internal:<port> (preconfigured).\n'

  local in_docker=""
  for s in wallet-core rates-service treasury-service; do
    if is_running "$s"; then in_docker="$in_docker $s"; fi
  done
  if [ -n "$in_docker" ]; then
    printf '\nIn Docker:%s. To run one of them from source instead: ./dev.sh down <service>\n' "$in_docker"
  fi
}

usage() {
  cat <<EOF
Usage: ./dev.sh <command> [service...]

Commands
  up [service...|all] [--no-build]  Start MySQL + Redis, plus the named services in containers.
                                    Builds the named services first, one at a time (--no-build skips it).
  up observability [service...]     The same plus the logging and metrics stack (Grafana, Prometheus).
  down [service...|observability]   Stop and remove the named services, or the whole stack.
  down --volumes                    Stop the whole stack and DELETE all data (MySQL, Redis, logs, metrics).
  build <service...|all>            Build images one at a time.
  logs [service...|observability]   Follow logs (all services when none is named).
  ps                                Show containers and health.
  info                              Print ports and the env values for services run from source.
  help                              This text.

Services: $SERVICES
Infrastructure (always on): $INFRA

Examples
  ./dev.sh up                                  # work on any service with npm run start:dev
  ./dev.sh up rates-service treasury-service   # plus two backends in Docker
  ./dev.sh up all                              # the whole system
  ./dev.sh up observability wallet-core
  ./dev.sh logs rates-service
  ./dev.sh down
EOF
}

command="${1:-help}"
[ "$#" -gt 0 ] && shift

case "$command" in
  up) cmd_up "$@" ;;
  down | stop) cmd_down "$@" ;;
  build) cmd_build "$@" ;;
  logs) cmd_logs "$@" ;;
  ps | status) cmd_ps "$@" ;;
  info | env) print_info ;;
  help | -h | --help) usage ;;
  *) die "unknown command '$command'. See ./dev.sh help" ;;
esac
