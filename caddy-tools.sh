#!/usr/bin/env bash
# caddy-tools.sh - Caddy management helper script
# Usage: ./caddy-tools.sh <command> [arguments]

set -euo pipefail

# ============ Configuration ============
CADDY_NETWORK="${CADDY_NETWORK:-caddy_net}"
CADDY_IMAGE_FILTER="${CADDY_IMAGE_FILTER:-caddy}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
SITES_DIR="${SITES_DIR:-sites-enabled}"

# ============ Colors ============
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    MAGENTA=$'\033[0;35m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; DIM=''; NC=''
fi

# ============ Output primitives ============
println() { printf '%b\n' "${*:-}"; }
print()   { printf '%b'   "${*:-}"; }

log_info()    { println "${BLUE}[INFO]${NC} $*"; }
log_success() { println "${GREEN}[ OK ]${NC} $*"; }
log_warn()    { println "${YELLOW}[WARN]${NC} $*"; }
log_error()   { println "${RED}[FAIL]${NC} $*" >&2; }
log_step()    { println "${MAGENTA}==>${NC} ${BOLD}$*${NC}"; }

die() { log_error "$*"; exit 1; }

# ============ Docker helpers ============
detect_caddy_container() {
    local container=""
    container=$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
        | awk -v pat="$CADDY_IMAGE_FILTER" 'tolower($2) ~ tolower(pat) {print $1; exit}' || true)

    if [[ -z "$container" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "caddyproxy"; then
        container="caddyproxy"
    fi

    [[ -n "$container" ]] || die "Could not detect a running Caddy container. Set CADDY_IMAGE_FILTER or start the container."
    printf '%s\n' "$container"
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
    docker info >/dev/null 2>&1 || die "Cannot connect to docker daemon"
}

require_jq() {
    command -v jq >/dev/null 2>&1 || die "jq is required for this command (apt install jq / brew install jq)"
}

# ============ Commands ============

cmd_help() {
    println "${BOLD}Caddy Tools${NC} — one-file helper for Caddy in Docker

${BOLD}USAGE${NC}
  $(basename "$0") <command> [args]

${BOLD}GETTING STARTED${NC}
  ${CYAN}example${NC}                    Show a full walkthrough with copy-paste commands

${BOLD}SETUP${NC}
  ${CYAN}compose-init [dir]${NC}         Write a ready-to-use docker-compose.yml
  ${CYAN}init-sites${NC}                 Create Caddyfile + ${SITES_DIR}/example.com.caddy
  ${CYAN}network-create${NC}             Create the '${CADDY_NETWORK}' network if missing
  ${CYAN}network-list${NC}               List containers attached to '${CADDY_NETWORK}'

${BOLD}PASSWORDS${NC}
  ${CYAN}hash <password>${NC}            Generate a bcrypt hash for basic_auth
  ${CYAN}hash-interactive${NC}           Same, but prompts with hidden input

${BOLD}OPERATIONS${NC}
  ${CYAN}reload${NC}                     Reload Caddy config (no restart)
  ${CYAN}restart${NC}                    Restart the Caddy container
  ${CYAN}validate${NC}                   Validate the Caddyfile
  ${CYAN}format${NC}                     Format the Caddyfile in place
  ${CYAN}status${NC}                     Show container status + Caddy version
  ${CYAN}container${NC}                  Print the auto-detected container name
  ${CYAN}backup [file]${NC}              Timestamped backup of the Caddyfile

${BOLD}LOGS${NC}
  ${CYAN}logs <domain>${NC}              Compact logs for one domain
  ${CYAN}logs-all${NC}                   Compact logs for all domains
  ${CYAN}logs-raw${NC}                   Raw docker logs (no parsing)

${BOLD}SHELL${NC}
  ${CYAN}shell${NC}                      Open a shell in the Caddy container
  ${CYAN}exec <cmd...>${NC}              Run a command in the Caddy container

${BOLD}ENV VARS${NC}
  CADDY_NETWORK       Network name (default: ${CADDY_NETWORK})
  CADDY_IMAGE_FILTER  Substring to match caddy image (default: ${CADDY_IMAGE_FILTER})
  COMPOSE_FILE        Compose file name (default: ${COMPOSE_FILE})
  SITES_DIR           Sites folder (default: ${SITES_DIR})
  LOG_TZ              Set to 'local' for local time in logs (default: UTC)"
}

cmd_example() {
    println "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════════════╗
║              Caddy Tools — Full Walkthrough Example                  ║
╚══════════════════════════════════════════════════════════════════════╝${NC}

This walks you from an empty directory to a working Caddy reverse proxy
with HTTPS, file browsing, and basic auth — in ~8 commands.

${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}
${BOLD}STEP 1 — Create a working directory${NC}
${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}

    mkdir my-caddy && cd my-caddy

${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}
${BOLD}STEP 2 — Create the docker networks${NC}
${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}

    # One network for Caddy to talk to your services
    docker network create caddy_net

    # (optional) a second network if you use one
    docker network create uddocknet

  ${DIM}Tip: $(basename "$0") network-create does the first one for you.${NC}

${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}
${BOLD}STEP 3 — Generate the compose file${NC}
${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}

    $(basename "$0") compose-init

  ${DIM}Writes ./${COMPOSE_FILE} with:${NC}
    • ports 80/443 (TCP + UDP for HTTP/3)
    • host.docker.internal:host-gateway  ${DIM}(reach host services)${NC}
    • volumes for Caddyfile, sites, data, config, downloads
    • external networks: caddy_net, uddocknet

${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}
${BOLD}STEP 4 — Generate the Caddyfile + a sample site${NC}
${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}

    $(basename "$0") init-sites

  ${DIM}Creates:${NC}
    ./Caddyfile                          ${DIM}(imports ${SITES_DIR}/*)${NC}
    ./${SITES_DIR}/example.com.caddy     ${DIM}(file browse + basic auth)${NC}

${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}
${BOLD}STEP 5 — Edit the sample site${NC}
${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}

    # Change 'example.com' to your real domain:
    \$EDITOR ${SITES_DIR}/example.com.caddy

  ${DIM}Then generate a password hash:${NC}

    $(basename "$0") hash-interactive

  ${DIM}Paste the resulting hash into the basic_auth block, replacing${NC}
  ${DIM}REPLACE_WITH_HASH.${NC}

${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}
${BOLD}STEP 6 — Start Caddy${NC}
${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}

    docker compose up -d
    $(basename "$0") status

${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}
${BOLD}STEP 7 — Watch live traffic (compact logs)${NC}
${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}

    $(basename "$0") logs yourdomain.com

  ${DIM}Output looks like:${NC}
      14:32:01  200  GET  /public/logo.png                 from  203.0.113.5
      14:32:05  401  GET  /private/report.pdf              from  198.51.100.7
      14:32:09  200  GET  /private/report.pdf              from  198.51.100.7

  ${DIM}Press Ctrl+C to stop.${NC}

${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}
${BOLD}STEP 8 — Everyday operations${NC}
${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}

    # After editing Caddyfile or a site file:
    $(basename "$0") validate && $(basename "$0") reload

    # Format the Caddyfile nicely:
    $(basename "$0") format

    # Back up the Caddyfile before big edits:
    $(basename "$0") backup

    # Shell into the container:
    $(basename "$0") shell

${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}
${BOLD}DIRECTORY LAYOUT AFTER SETUP${NC}
${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}

    my-caddy/
    ├── ${COMPOSE_FILE}
    ├── Caddyfile
    └── ${SITES_DIR}/
        └── example.com.caddy

    /opt/dockdata/
    ├── caddy/
    │   ├── data/       ${DIM}(certificates, ACME state)${NC}
    │   └── config/     ${DIM}(autosave)${NC}
    └── downloads/      ${DIM}(served files)${NC}

${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}
${BOLD}COMMON GOTCHAS${NC}
${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${NC}

  • Empty logs?          → Caddy must log JSON to stdout. Don't set 'log'
                           in the Caddyfile unless you also keep stdout.

  • 502 Bad Gateway?     → Your upstream service must be on the SAME
                           docker network as Caddy (${CADDY_NETWORK}). Use the
                           container name as the host, e.g.
                             reverse_proxy myservice:8080

  • Reach the host?      → Use host.docker.internal:PORT (already wired
                           up via extra_hosts in the generated compose).

  • Port 80/443 in use?  → Stop nginx/apache/caddy on the host first.

  • Reload does nothing? → Check '$(basename "$0") validate' for errors,
                           then '$(basename "$0") logs-raw'."
}

cmd_hash() {
    [[ -n "${1:-}" ]] || die "Usage: $(basename "$0") hash <password>"
    log_info "Generating bcrypt hash via disposable caddy container..."
    docker run --rm caddy caddy hash-password --plaintext "$1"
}

cmd_hash_interactive() {
    local pw pw2
    read -r -s -p "Enter password: " pw; echo
    read -r -s -p "Confirm password: " pw2; echo
    [[ "$pw" == "$pw2" ]] || die "Passwords do not match"
    [[ -n "$pw" ]] || die "Password cannot be empty"
    log_info "Generating bcrypt hash..."
    echo
    docker run --rm caddy caddy hash-password --plaintext "$pw"
    echo
    log_info "Copy the line above into your Caddyfile's basic_auth block."
}

cmd_reload() {
    require_docker
    local c; c=$(detect_caddy_container)
    log_info "Reloading config on container: ${BOLD}$c${NC}"
    docker exec -w /etc/caddy "$c" caddy reload --config /etc/caddy/Caddyfile
    log_success "Reload complete"
}

cmd_restart() {
    require_docker
    local c; c=$(detect_caddy_container)
    log_info "Restarting container: ${BOLD}$c${NC}"
    docker restart "$c"
    log_success "Restarted"
}

# Tail helper: runs `docker logs -f | jq` and makes Ctrl+C deterministic.
_tail_logs() {
    local c="$1"; shift
    local prog="$1"; shift

    # Non-interactive shells: docker exec -it style commands would fail, but
    # this is just a stream, so no TTY is needed. However Ctrl+C delivery in
    # non-TTY environments is on us — use a trap that kills our children.

    set +e

    # Start the pipeline in the background; $! is the PID of the LAST process
    # in the pipeline (jq). We kill both docker and jq on signal.
    docker logs -f "$c" 2>&1 | jq -r --unbuffered "$@" "$prog" &
    local pipeline_pid=$!

    # Kill any direct child of this script on INT/TERM.
    trap 'pkill -TERM -P '"$$"' 2>/dev/null; exit 0' INT TERM

    wait "$pipeline_pid"
    local rc=$?

    trap - INT TERM
    set -e
    return $rc
}

cmd_logs() {
    require_docker
    local c domain="${1:-}"
    c=$(detect_caddy_container)
    [[ -n "$domain" ]] || die "Usage: $(basename "$0") logs <domain>"
    require_jq

    log_info "Following logs for ${BOLD}$domain${NC} from ${BOLD}$c${NC} — press Ctrl+C to stop"
    println "${DIM}        TIME  CODE  METHOD  PATH                                      FROM${NC}"

    _tail_logs "$c" '
        select(.request and ((.request.host // "") == $d)) |
        (.status // 0) as $s |
        (if $s >= 400 then $r elif $s >= 300 then $y else $g end) as $color |
        (if .ts then (.ts | todate | .[11:19]) else "--:--:--" end) as $time |
        (.request.uri // "") as $uri |
        "  \($time)  "
        + $color + "\($s)" + $n + "  "
        + "\(.request.method // "-")  "
        + $uri
        + (" " * ([0, (44 - ($uri | length))] | max))
        + "from  \(.request.remote_ip // .request.remote_addr // "-")"
    ' --arg d "$domain" --arg g "$GREEN" --arg y "$YELLOW" --arg r "$RED" --arg n "$NC"
}

cmd_logs_all() {
    require_docker
    local c; c=$(detect_caddy_container)
    require_jq

    log_info "Following ALL logs (compact) from ${BOLD}$c${NC} — press Ctrl+C to stop"
    println "${DIM}        TIME  CODE  METHOD  HOST/PATH                                  FROM${NC}"

    _tail_logs "$c" '
        select(.request) |
        (.status // 0) as $s |
        (if $s >= 400 then $r elif $s >= 300 then $y else $g end) as $color |
        (if .ts then (.ts | todate | .[11:19]) else "--:--:--" end) as $time |
        ((.request.host // "-") + (.request.uri // "-")) as $full |
        "  \($time)  "
        + $color + "\($s)" + $n + "  "
        + "\(.request.method // "-")  "
        + $full
        + (" " * ([0, (44 - ($full | length))] | max))
        + "from  \(.request.remote_ip // .request.remote_addr // "-")"
    ' --arg g "$GREEN" --arg y "$YELLOW" --arg r "$RED" --arg n "$NC"
}

cmd_logs_raw() {
    require_docker
    local c; c=$(detect_caddy_container)
    log_info "Following raw logs from ${BOLD}$c${NC} — press Ctrl+C to stop"
    docker logs -f "$c"
}

cmd_status() {
    require_docker
    local c; c=$(detect_caddy_container)
    log_step "Caddy status"
    println "${BOLD}Container:${NC} $c"
    docker ps --filter "name=^${c}$" \
        --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    echo
    log_info "Caddy version:"
    docker exec "$c" caddy version || true
}

cmd_validate() {
    require_docker
    local c; c=$(detect_caddy_container)
    log_info "Validating Caddyfile in $c ..."
    if docker exec -w /etc/caddy "$c" caddy validate --config /etc/caddy/Caddyfile; then
        log_success "Caddyfile is valid"
    else
        die "Caddyfile validation failed"
    fi
}

cmd_format() {
    require_docker
    local c; c=$(detect_caddy_container)
    log_info "Formatting Caddyfile in $c ..."
    docker exec -w /etc/caddy "$c" caddy fmt --overwrite /etc/caddy/Caddyfile
    log_success "Formatted"
}

cmd_network_create() {
    require_docker
    if docker network ls --filter "name=^${CADDY_NETWORK}$" --format '{{.Name}}' | grep -qx "$CADDY_NETWORK"; then
        log_success "Network '${CADDY_NETWORK}' already exists"
    else
        log_info "Creating network '${CADDY_NETWORK}'..."
        docker network create "$CADDY_NETWORK"
        log_success "Network created"
    fi
}

cmd_network_list() {
    require_docker
    log_info "Containers on network '${CADDY_NETWORK}':"
    docker network inspect "$CADDY_NETWORK" \
        --format '{{range .Containers}}  • {{.Name}} ({{.IPv4Address}}){{"\n"}}{{end}}' 2>/dev/null \
        || die "Network '${CADDY_NETWORK}' not found"
}

cmd_shell() {
    require_docker
    local c; c=$(detect_caddy_container)
    log_info "Opening shell in ${BOLD}$c${NC}..."
    if [[ -t 0 ]]; then
        docker exec -it "$c" sh
    else
        docker exec -i "$c" sh
    fi
}

cmd_exec() {
    require_docker
    [[ $# -gt 0 ]] || die "Usage: $(basename "$0") exec <command...>"
    local c; c=$(detect_caddy_container)
    if [[ -t 0 ]]; then
        docker exec -it "$c" "$@"
    else
        docker exec -i "$c" "$@"
    fi
}

cmd_container() {
    require_docker
    detect_caddy_container
}

cmd_backup() {
    local ts file
    ts=$(date +%Y%m%d-%H%M%S)
    file="${1:-Caddyfile.bak.$ts}"
    [[ -f Caddyfile ]] || die "No Caddyfile in current directory"
    cp Caddyfile "$file"
    log_success "Backed up Caddyfile -> $file"
}

cmd_compose_init() {
    local dir="${1:-.}"
    local file="${dir%/}/${COMPOSE_FILE}"

    if [[ -f "$file" ]]; then
        log_warn "$file already exists — not overwriting."
        log_info "Delete it first, or pass a different directory as the argument."
        return 1
    fi

    mkdir -p "$dir"
    cat > "$file" <<'YAML'
services:
  caddyproxy:
    image: caddy:latest
    container_name: caddyproxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"        # HTTP/3 (QUIC)
    extra_hosts:
      # Lets Caddy reach services running directly on the docker host
      - "host.docker.internal:host-gateway"
    networks:
      - caddy_net
      - uddocknet
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./sites-enabled:/etc/caddy/sites-enabled
      - /opt/dockdata/caddy/data:/data
      - /opt/dockdata/caddy/config:/config
      - /opt/dockdata/downloads:/var/www/downloads
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  caddy_net:
    external: true
  uddocknet:
    external: true
YAML

    log_success "Wrote $file"
    echo
    log_step "Next steps"
    println "  1. Ensure the external networks exist:"
    println "       docker network create caddy_net"
    println "       docker network create uddocknet    ${DIM}# if you use it${NC}"
    println "     ${DIM}or: $(basename "$0") network-create${NC}"
    echo
    println "  2. Generate Caddyfile + sample site:"
    println "       $(basename "$0") init-sites"
    echo
    println "  3. Create a password hash and paste it into your site file:"
    println "       $(basename "$0") hash-interactive"
    echo
    println "  4. Start Caddy:"
    println "       docker compose up -d"
    println "       $(basename "$0") status"
    echo
}

cmd_init_sites() {
    mkdir -p "$SITES_DIR"

    if [[ -f Caddyfile ]]; then
        log_warn "Caddyfile already exists — not overwriting."
    else
        cat > Caddyfile <<'CADDY'
{
    # Global options — uncomment and set your email for ACME/Let's Encrypt
    # email you@example.com

    # Uncomment to enable debug logging
    # debug
}

# Import every site config in sites-enabled/
import sites-enabled/*
CADDY
        log_success "Created Caddyfile"
    fi

    local sample="${SITES_DIR}/example.com.caddy"
    if [[ -f "$sample" ]]; then
        log_warn "$sample already exists — not overwriting."
    else
        cat > "$sample" <<'CADDY'
# ---------------------------------------------------------------------------
# example.com — file server with public + private areas
#
#  • /public/*        → open to everyone, browseable
#  • everything else  → HTTP basic auth required
#
# Before using:
#   1. Replace example.com with your real domain
#   2. Replace REPLACE_WITH_HASH using:  caddy-tools hash-interactive
# ---------------------------------------------------------------------------
example.com {
    root * /var/www/downloads
    file_server browse

    # Match everything EXCEPT /public/*
    @private_files {
        not path /public/*
    }

    # Basic auth on the private matcher only
    basic_auth @private_files {
        # user  <bcrypt-hash-from-caddy-hash-password>
        user REPLACE_WITH_HASH
    }
}
CADDY
        log_success "Created $sample"
    fi

    echo
    log_step "Next steps"
    println "  1. Edit the sample site and set your real domain:"
    println "       \$EDITOR $sample"
    echo
    println "  2. Generate a password hash:"
    println "       $(basename "$0") hash-interactive"
    println "     Paste the output where REPLACE_WITH_HASH is, keeping the"
    println "     word 'user' before it. Example:"
    println "       basic_auth @private_files {"
    println "           user \$2a\$14\$abc...XYZ"
    println "       }"
    echo
    println "  3. Start (or reload) Caddy:"
    println "       docker compose up -d        ${DIM}# first time${NC}"
    println "       $(basename "$0") reload     ${DIM}# subsequent edits${NC}"
    echo
    println "  4. Tail logs:"
    println "       $(basename "$0") logs yourdomain.com"
    echo
}

# ============ Dispatch ============
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        help|-h|--help)          cmd_help ;;
        example|walkthrough)     cmd_example ;;

        compose-init|compose)    cmd_compose_init "$@" ;;
        init-sites|init)         cmd_init_sites ;;
        network-create)          cmd_network_create ;;
        network-list)            cmd_network_list ;;

        hash)                    cmd_hash "$@" ;;
        hash-interactive|hash-i) cmd_hash_interactive ;;

        reload)                  cmd_reload ;;
        restart)                 cmd_restart ;;
        validate)                cmd_validate ;;
        format|fmt)              cmd_format ;;
        status)                  cmd_status ;;
        container)               cmd_container ;;
        backup)                  cmd_backup "$@" ;;

        logs)                    cmd_logs "$@" ;;
        logs-all|logs-compact)   cmd_logs_all ;;
        logs-raw)                cmd_logs_raw ;;

        shell)                   cmd_shell ;;
        exec)                    cmd_exec "$@" ;;

        *)
            log_error "Unknown command: $cmd"
            echo
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
