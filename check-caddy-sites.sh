#!/usr/bin/env bash

# Default configuration
CADDY_BASE_DIR="/opt/docker/caddy"
SHOW_DISABLED=false

# Parse arguments (supports path override and -a/--all in any order)
for arg in "$@"; do
    case "$arg" in
        -a|--all)
            SHOW_DISABLED=true
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [CADDY_BASE_DIR] [-a|--all]"
            echo "Example: $(basename "$0") . --all"
            exit 0
            ;;
        *)
            CADDY_BASE_DIR="$arg"
            ;;
    esac
done

# Strip trailing slash if present (unless root "/")
[[ "$CADDY_BASE_DIR" != "/" ]] && CADDY_BASE_DIR="${CADDY_BASE_DIR%/}"

ENABLED_DIR="${CADDY_BASE_DIR}/sites-enabled"
DISABLED_DIR="${CADDY_BASE_DIR}/sites-disabled"

if [[ ! -d "$ENABLED_DIR" && ! -d "$DISABLED_DIR" ]]; then
    echo "Error: Neither '$ENABLED_DIR' nor '$DISABLED_DIR' exists." >&2
    exit 1
fi

# Cache Docker info to avoid slow repeated inspect calls
declare -A DOCKER_CACHE
HAS_DOCKER=false
if command -v docker &>/dev/null && docker info &>/dev/null; then
    HAS_DOCKER=true
fi

get_docker_info() {
    local target_host="$1"

    # Skip IP addresses or localhost
    if [[ "$target_host" == "localhost" || "$target_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "[Host / IP]"
        return
    fi

    if [[ "$HAS_DOCKER" == false ]]; then
        echo "[Docker unavailable]"
        return
    fi

    # Return cached result if already inspected
    if [[ -n "${DOCKER_CACHE[$target_host]+_}" ]]; then
        echo "${DOCKER_CACHE[$target_host]}"
        return
    fi

    local inspect_out
    inspect_out=$(docker inspect -f '{{.State.Status}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$target_host" 2>/dev/null)

    local result
    if [[ $? -ne 0 || -z "$inspect_out" ]]; then
        result="[Not Found]"
    else
        local status="${inspect_out%%|*}"
        local compose_file="${inspect_out#*|}"

        # Capitalize status nicely (e.g., running -> Running, exited -> Exited)
        status="${status^}"

        if [[ -n "$compose_file" && "$compose_file" != "<no value>" ]]; then
            result="[$status] $compose_file"
        else
            result="[$status] (No compose file)"
        fi
    fi

    DOCKER_CACHE["$target_host"]="$result"
    echo "$result"
}

parse_caddy_dir() {
    local dir="$1"
    [[ ! -d "$dir" ]] && return

    # Output tab-separated fields: file \t domain:port \t container:port \t raw_container_host
    find "$dir" -maxdepth 1 -type f ! -name ".*" | sort | while read -r file; do
        awk -v fname="$(basename "$file")" '
        function parse_endpoint(raw, out,    idx, host, port) {
            sub(/^https?:\/\//, "", raw)
            sub(/\/.*$/, "", raw)
            idx = index(raw, ":")
            if (idx > 0) {
                host = substr(raw, 1, idx - 1)
                port = substr(raw, idx + 1)
                if (host == "") host = "*"
            } else {
                host = raw
                port = ""
            }
            out["host"] = host
            out["port"] = port
            out["formatted"] = (port != "") ? host ":" port : host
        }

        {
            sub(/#.*/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
        }
        /^$/ { next }

        /\{$/ {
            line = $0
            sub(/[ \t]*\{$/, "", line)
            if (line != "" && line !~ /^@/ && line !~ /^\(/) {
                raw_sites = line
            }
            next
        }

        raw_sites != "" && /^reverse_proxy[ \t]+/ {
            sub(/^reverse_proxy[ \t]+/, "")
            sub(/[ \t]*\{$/, "")

            gsub(/,[ \t]*/, " ", raw_sites)
            d_count = split(raw_sites, domains, /[ \t]+/)
            t_count = split($0, targets, /[ \t]+/)

            for (d = 1; d <= d_count; d++) {
                parse_endpoint(domains[d], dom_info)

                for (t = 1; t <= t_count; t++) {
                    target = targets[t]
                    if (target ~ /^-/) continue

                    parse_endpoint(target, tgt_info)
                    if (tgt_info["host"] == "*") {
                        tgt_info["host"] = "localhost"
                        tgt_info["formatted"] = (tgt_info["port"] != "") ? "localhost:" tgt_info["port"] : "localhost"
                    }

                    printf "%s\t%s\t%s\t%s\n", \
                        fname, dom_info["formatted"], tgt_info["formatted"], tgt_info["host"]
                }
            }
        }

        /^\}$/ {
            raw_sites = ""
        }
        ' "$file"
    done
}

print_section() {
    local title="$1"
    local dir="$2"
    local empty_msg="$3"

    printf "\n\033[1;36m=== %s ===\033[0m\n" "$title"

    local raw_rows
    raw_rows=$(parse_caddy_dir "$dir")

    if [[ -z "$raw_rows" ]]; then
        printf "\033[2m(%s)\033[0m\n" "$empty_msg"
        return
    fi

    printf "\033[1m%-20s | %-28s | %-24s | %s\033[0m\n" \
        "FILE" "DOMAIN" "CONTAINER" "STATUS & COMPOSE FILE"
    printf -- "-----------------------------------------------------------------------------------------------------------------\n"

    while IFS=$'\t' read -r fname dom_disp tgt_disp tgt_host; do
        docker_meta=$(get_docker_info "$tgt_host")
        printf "%-20s | %-28s | %-24s | %s\n" \
            "$fname" "$dom_disp" "$tgt_disp" "$docker_meta"
    done <<< "$raw_rows"
}

print_section "ENABLED SITES ($ENABLED_DIR)" "$ENABLED_DIR" "No enabled sites found"

if [[ "$SHOW_DISABLED" == true ]]; then
    print_section "DISABLED SITES ($DISABLED_DIR)" "$DISABLED_DIR" "No disabled sites found"
fi
echo ""
