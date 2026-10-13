#!/usr/bin/env bash
set -euo pipefail

API="https://api.cloudflare.com/client/v4"
TOKEN="${CLOUDFLARE_API_TOKEN:-}"

die() { echo "Error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required."; }
api() {
  curl -fsS "$API$1" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json"
}
need curl
need jq
need column
[ -n "$TOKEN" ] || die "CLOUDFLARE_API_TOKEN is not set."

get_zones() {
  local page=1 data
  while :; do
    data="$(api "/zones?page=$page&per_page=100")"
    echo "$data" | jq -c '.result[]'
    [ "$(echo "$data" | jq -r '.result_info.page < .result_info.total_pages')" = "true" ] || break
    page=$((page + 1))
  done
}

get_account_id() {
  local accounts
  accounts="$(get_zones | jq -r '.account.id' | sort -u)"
  [ -n "$accounts" ] || die "No Cloudflare account was found through this token."
  [ "$(echo "$accounts" | wc -l)" -eq 1 ] || die "Token has access to multiple Cloudflare accounts. Use an explicit tunnel command."
  echo "$accounts"
}

get_zone_id() {
  local domain="$1" zone
  zone="$(get_zones | jq -r --arg d "$domain" 'select(.name == $d) | .id' | head -n1)"
  [ -n "$zone" ] || die "Domain not found: $domain"
  echo "$zone"
}

fqdn() {
  local domain="$1" host="$2"
  [ "$host" = "@" ] && echo "$domain" || echo "$host.$domain"
}

dns_records() {
  local zone="$1" page=1 data
  while :; do
    data="$(api "/zones/$zone/dns_records?page=$page&per_page=100")"
    echo "$data" | jq -c '.result[]'
    [ "$(echo "$data" | jq -r '.result_info.page < .result_info.total_pages')" = "true" ] || break
    page=$((page + 1))
  done
}

find_dns() {
  local zone="$1" name="$2" type="${3:-}"
  dns_records "$zone" | jq -c --arg n "$name" --arg t "$type" \
    'select(.name == $n and ($t == "" or .type == $t))' | head -n1
}

tunnels() {
  local account
  account="$(get_account_id)"
  api "/accounts/$account/cfd_tunnel?per_page=100" | jq -c '.result[]'
}

tunnel_config() {
  local tunnel="$1" account
  account="$(get_account_id)"
  api "/accounts/$account/cfd_tunnel/$tunnel/configurations" | jq '.result.config'
}

tunnel_source() {
  local tunnel="$1" account
  account="$(get_account_id)"
  api "/accounts/$account/cfd_tunnel/$tunnel" | jq -r '.result.source // "unknown"'
}

find_tunnel() {
  local name="$1" t
  while IFS= read -r t; do
    local id tname route
    id="$(echo "$t" | jq -r '.id')"
    tname="$(echo "$t" | jq -r '.name')"
    route="$(tunnel_config "$id" | jq -c --arg h "$name" '.ingress[]? | select(.hostname == $h)' | head -n1)"
    if [ -n "$route" ]; then
      printf '%s\t%s\t%s\n' "$id" "$tname" "$route"
      return 0
    fi
  done < <(tunnels)
  return 1
}

single_tunnel() {
  local data count
  data="$(tunnels)"
  count="$(echo "$data" | sed '/^[[:space:]]*$/d' | wc -l)"
  [ "$count" -eq 1 ] || return 1
  echo "$data" | head -n1
}

create_dns_tunnel() {
  local zone="$1" name="$2" tunnel="$3"
  local existing target
  existing="$(find_dns "$zone" "$name" CNAME || true)"
  target="${tunnel}.cfargotunnel.com"
  if [ -n "$existing" ]; then
    [ "$(echo "$existing" | jq -r '.content')" = "$target" ] && return 0
    die "A CNAME already exists for $name and points somewhere else."
  fi
  api "/zones/$zone/dns_records" -X POST \
    -d "$(jq -nc --arg n "$name" --arg c "$target" \
      '{type:"CNAME",name:$n,content:$c,proxied:true}')"
}

delete_dns_tunnel() {
  local zone="$1" name="$2" tunnel="$3" record id
  record="$(find_dns "$zone" "$name" CNAME || true)"
  [ -n "$record" ] || return 0
  [ "$(echo "$record" | jq -r '.content')" = "${tunnel}.cfargotunnel.com" ] || return 0
  id="$(echo "$record" | jq -r '.id')"
  api "/zones/$zone/dns_records/$id" -X DELETE >/dev/null
}

put_tunnel_config() {
  local tunnel="$1" config="$2" account
  account="$(get_account_id)"
  api "/accounts/$account/cfd_tunnel/$tunnel/configurations" \
    -X PUT -d "{\"config\":$config}" >/dev/null
}

check_remote_tunnel() {
  local tunnel="$1" source
  source="$(tunnel_source "$tunnel")"
  [ "$source" = "local" ] && die "Tunnel '$tunnel' is locally managed. Its YAML config must be changed on the server."
}

tunnel_add() {
  local tunnel="$1" domain="$2" host="$3" service="$4"
  local zone name config
  zone="$(get_zone_id "$domain")"
  name="$(fqdn "$domain" "$host")"
  check_remote_tunnel "$tunnel"
  config="$(tunnel_config "$tunnel")"
  if echo "$config" | jq -e --arg h "$name" '.ingress[]? | select(.hostname == $h)' >/dev/null; then
    die "Tunnel route already exists: $name"
  fi
  config="$(echo "$config" | jq --arg h "$name" --arg s "$service" '
    .ingress = (
      (.ingress // [])
      | if length > 0 and .[-1].hostname == null
        then .[:-1] + [{hostname:$h,service:$s}] + .[-1:]
        else . + [{hostname:$h,service:$s}]
        end
    )')"
  put_tunnel_config "$tunnel" "$config"
  create_dns_tunnel "$zone" "$name" "$tunnel" >/dev/null
  echo "Added tunnel: $name -> $service"
}

tunnel_update() {
  local tunnel="$1" domain="$2" host="$3" service="$4"
  local zone name config
  zone="$(get_zone_id "$domain")"
  name="$(fqdn "$domain" "$host")"
  check_remote_tunnel "$tunnel"
  config="$(tunnel_config "$tunnel")"
  echo "$config" | jq -e --arg h "$name" '.ingress[]? | select(.hostname == $h)' >/dev/null \
    || die "Tunnel route not found: $name"
  config="$(echo "$config" | jq --arg h "$name" --arg s "$service" '
    .ingress |= map(if .hostname == $h then .service = $s else . end)')"
  put_tunnel_config "$tunnel" "$config"
  create_dns_tunnel "$zone" "$name" "$tunnel" >/dev/null
  echo "Updated tunnel: $name -> $service"
}

tunnel_remove() {
  local tunnel="$1" domain="$2" host="$3"
  local zone name config
  zone="$(get_zone_id "$domain")"
  name="$(fqdn "$domain" "$host")"
  check_remote_tunnel "$tunnel"
  config="$(tunnel_config "$tunnel")"
  echo "$config" | jq -e --arg h "$name" '.ingress[]? | select(.hostname == $h)' >/dev/null \
    || die "Tunnel route not found: $name"
  config="$(echo "$config" | jq --arg h "$name" '
    .ingress |= map(select(.hostname != $h))')"
  put_tunnel_config "$tunnel" "$config"
  delete_dns_tunnel "$zone" "$name" "$tunnel"
  echo "Removed tunnel: $name"
}

tunnel_rename() {
  local tunnel="$1" domain="$2" old="$3" new="$4" service="$5"
  local zone oldname newname config
  zone="$(get_zone_id "$domain")"
  oldname="$(fqdn "$domain" "$old")"
  newname="$(fqdn "$domain" "$new")"
  check_remote_tunnel "$tunnel"
  config="$(tunnel_config "$tunnel")"
  echo "$config" | jq -e --arg h "$oldname" '.ingress[]? | select(.hostname == $h)' >/dev/null \
    || die "Tunnel route not found: $oldname"
  echo "$config" | jq -e --arg h "$newname" '.ingress[]? | select(.hostname == $h)' >/dev/null \
    && die "Tunnel route already exists: $newname"
  config="$(echo "$config" | jq --arg old "$oldname" --arg new "$newname" --arg s "$service" '
    .ingress |= map(if .hostname == $old then (.hostname=$new | .service=$s) else . end)')"
  put_tunnel_config "$tunnel" "$config"
  create_dns_tunnel "$zone" "$newname" "$tunnel" >/dev/null
  delete_dns_tunnel "$zone" "$oldname" "$tunnel"
  echo "Renamed tunnel: $oldname -> $newname"
}

dns_add() {
  local domain="$1" host="$2" type="$3" content="$4"
  local zone name
  zone="$(get_zone_id "$domain")"
  name="$(fqdn "$domain" "$host")"
  [ -z "$(find_dns "$zone" "$name" "$type" || true)" ] || die "DNS record already exists: $name $type"
  api "/zones/$zone/dns_records" -X POST \
    -d "$(jq -nc --arg t "$type" --arg n "$name" --arg c "$content" \
      '{type:$t,name:$n,content:$c}')"
  echo "Added DNS: $name $type -> $content"
}

dns_update() {
  local domain="$1" host="$2" type="$3" content="$4"
  local zone name record id
  zone="$(get_zone_id "$domain")"
  name="$(fqdn "$domain" "$host")"
  record="$(find_dns "$zone" "$name" "$type" || true)"
  [ -n "$record" ] || die "DNS record not found: $name $type"
  id="$(echo "$record" | jq -r '.id')"
  api "/zones/$zone/dns_records/$id" -X PUT \
    -d "$(jq -nc --arg t "$type" --arg n "$name" --arg c "$content" \
      '{type:$t,name:$n,content:$c}')"
  echo "Updated DNS: $name $type -> $content"
}

dns_remove() {
  local domain="$1" host="$2" type="${3:-}"
  local zone name record id
  zone="$(get_zone_id "$domain")"
  name="$(fqdn "$domain" "$host")"
  record="$(find_dns "$zone" "$name" "$type" || true)"
  [ -n "$record" ] || die "DNS record not found: $name${type:+ $type}"
  id="$(echo "$record" | jq -r '.id')"
  api "/zones/$zone/dns_records/$id" -X DELETE >/dev/null
  echo "Removed DNS: $name ${type:-record}"
}

dns_rename() {
  local domain="$1" old="$2" new="$3" type="$4" content="$5"
  dns_add "$domain" "$new" "$type" "$content"
  dns_remove "$domain" "$old" "$type"
}

list_domains() {
  printf '%s\n' "DOMAIN                 STATUS        ACCOUNT"
  printf '%s\n' "---------------------------------------------------------------"
  get_zones | jq -r '[.name,.status,.account.name] | @tsv' | column -t -s $'\t'
}

list_tunnels() {
  printf '%s\n' "TUNNEL                         ID                                    SOURCE"
  printf '%s\n' "---------------------------------------------------------------------------------------------"
  tunnels | jq -r '[.name,.id,.source] | @tsv' | column -t -s $'\t'
}

list_tunnel_routes() {
  local tunnel="$1" config
  config="$(echo "$tunnel" | jq -r '.id' | xargs -I{} bash -c 'tunnel_config "$1"' _ {})"
  echo "$config" | jq -r '.ingress[]? | select(.hostname != null) | [.hostname,.service] | @tsv' |
    column -t -s $'\t'
}

list_domain() {
  local domain="$1" zone records tunnel_data tunnel_routes
  zone="$(get_zone_id "$domain")"
  records="$(dns_records "$zone")"
  tunnel_data="$(tunnels)"
  echo
  echo "DOMAIN: $domain"
  echo "=========================================================================="
  echo
  printf '%-35s %-8s %-45s %-25s\n' "HOST" "TYPE" "POINTS TO" "TUNNEL"
  printf '%-35s %-8s %-45s %-25s\n' "-----------------------------------" "--------" "---------------------------------------------" "-------------------------"

  while IFS= read -r record; do
    local name type target tunnel_info tunnel_name
    name="$(echo "$record" | jq -r '.name')"
    type="$(echo "$record" | jq -r '.type')"
    target="$(echo "$record" | jq -r '.content')"
    tunnel_name="-"

    if [ "$type" = "CNAME" ] && [[ "$target" == *.cfargotunnel.com ]]; then
      while IFS= read -r t; do
        local tid tname route
        tid="$(echo "$t" | jq -r '.id')"
        tname="$(echo "$t" | jq -r '.name')"
        route="$(tunnel_config "$tid" | jq -c --arg h "$name" '.ingress[]? | select(.hostname == $h)' | head -n1)"
        if [ -n "$route" ]; then
          target="$(echo "$route" | jq -r '.service')"
          type="TUNNEL"
          tunnel_name="$tname"
          break
        fi
      done <<< "$tunnel_data"
    fi

    printf '%-35s %-8s %-45s %-25s\n' "$name" "$type" "$target" "$tunnel_name"
  done <<< "$records"

  echo
  echo "TUNNEL ROUTES WITHOUT MATCHING DNS RECORD"
  echo "=========================================================================="
  printf '%-35s %-25s %-45s\n' "HOST" "TUNNEL" "POINTS TO"
  printf '%-35s %-25s %-45s\n' "-----------------------------------" "-------------------------" "---------------------------------------------"

  while IFS= read -r t; do
    local tid tname route
    tid="$(echo "$t" | jq -r '.id')"
    tname="$(echo "$t" | jq -r '.name')"
    while IFS= read -r route; do
      local host service cname
      host="$(echo "$route" | jq -r '.hostname')"
      service="$(echo "$route" | jq -r '.service')"
      cname="$(find_dns "$zone" "$host" CNAME || true)"
      if [ -z "$cname" ]; then
        printf '%-35s %-25s %-45s\n' "$host" "$tname" "$service"
      fi
    done < <(tunnel_config "$tid" | jq -c --arg d "$domain" '.ingress[]? | select(.hostname != null and (.hostname == $d or .hostname | endswith("." + $d)))')
  done <<< "$tunnel_data"
}

usage() {
  cat <<'EOF'
Cloudflare DNS + Tunnel Manager

Usage:
  ./cf.sh domains
  ./cf.sh list DOMAIN
  ./cf.sh tunnels
  ./cf.sh tunnel-list TUNNEL

DNS:
  ./cf.sh add DOMAIN HOST TYPE CONTENT
  ./cf.sh update DOMAIN HOST TYPE CONTENT
  ./cf.sh remove DOMAIN HOST [TYPE]
  ./cf.sh rename DOMAIN OLD_HOST NEW_HOST TYPE CONTENT

Tunnel:
  ./cf.sh tunnel-add TUNNEL DOMAIN HOST SERVICE
  ./cf.sh tunnel-update TUNNEL DOMAIN HOST SERVICE
  ./cf.sh tunnel-remove TUNNEL DOMAIN HOST
  ./cf.sh tunnel-rename TUNNEL DOMAIN OLD_HOST NEW_HOST SERVICE

Examples:
  ./cf.sh domains
  ./cf.sh list example.com

  ./cf.sh add example.com www A 203.0.113.10
  ./cf.sh add example.com api CNAME app.example.com
  ./cf.sh update example.com www A 203.0.113.20
  ./cf.sh remove example.com www A
  ./cf.sh rename example.com old new A 203.0.113.10

  ./cf.sh tunnels
  ./cf.sh tunnel-list "My Server"

  ./cf.sh tunnel-add "My Server" example.com jellyfin http://jellyfin:8096
  ./cf.sh tunnel-update "My Server" example.com jellyfin http://jellyfin:8097
  ./cf.sh tunnel-remove "My Server" example.com jellyfin
  ./cf.sh tunnel-rename "My Server" example.com old new http://new-service:8080

Simple Tunnel commands:
  If the hostname already belongs to a Tunnel, the script detects it.
  If the account has only one Tunnel, add can use it automatically.

  ./cf.sh add example.com jellyfin http://jellyfin:8096
  ./cf.sh update example.com jellyfin http://jellyfin:8097
  ./cf.sh remove example.com jellyfin
  ./cf.sh rename example.com old new http://new-service:8080

Environment:
  export CLOUDFLARE_API_TOKEN="your-api-token"

Required token permissions:
  Zone Read
  DNS Write
  Tunnel Write / Cloudflare One Connector Write

Notes:
  - Account ID is discovered automatically from the zones API.
  - No CLOUDFLARE_ACCOUNT_ID variable is required.
  - Tunnel routes must be Cloudflare-managed/remote to modify them through the API.
  - Locally managed cloudflared YAML tunnels must be changed in their YAML configuration.
  - The list command joins DNS records with Tunnel routes and shows the
    actual service such as http://jellyfin:8096 instead of only the
    *.cfargotunnel.com CNAME.
EOF
}

simple_add() {
  if [ "$#" -eq 4 ]; then
    dns_add "$@"
    return
  fi
  [ "$#" -eq 3 ] || die "Usage: ./cf.sh add DOMAIN HOST TYPE CONTENT  OR  ./cf.sh add DOMAIN HOST SERVICE"
  local domain="$1" host="$2" service="$3" t zone name
  t="$(single_tunnel)" || die "Multiple tunnels found. Use: ./cf.sh tunnel-add TUNNEL DOMAIN HOST SERVICE"
  zone="$(get_zone_id "$domain")"
  name="$(fqdn "$domain" "$host")"
  tunnel_add "$(echo "$t" | jq -r '.id')" "$domain" "$host" "$service"
}

simple_update() {
  if [ "$#" -eq 4 ]; then
    dns_update "$@"
    return
  fi
  [ "$#" -eq 3 ] || die "Usage: ./cf.sh update DOMAIN HOST TYPE CONTENT  OR  ./cf.sh update DOMAIN HOST SERVICE"
  local domain="$1" host="$2" service="$3" name="$t" owner
  name="$(fqdn "$domain" "$host")"
  owner="$(find_tunnel "$name")" || die "No Tunnel route found for $name"
  tunnel_update "$(echo "$owner" | cut -f1)" "$domain" "$host" "$service"
}

simple_remove() {
  local domain="$1" host="$2" type="${3:-}" name owner
  name="$(fqdn "$domain" "$host")"
  if [ -z "$type" ]; then
    if owner="$(find_tunnel "$name" 2>/dev/null)"; then
      tunnel_remove "$(echo "$owner" | cut -f1)" "$domain" "$host"
    else
      dns_remove "$domain" "$host"
    fi
  else
    dns_remove "$domain" "$host" "$type"
  fi
}

simple_rename() {
  if [ "$#" -eq 5 ]; then
    dns_rename "$@"
    return
  fi
  [ "$#" -eq 4 ] || die "Usage: ./cf.sh rename DOMAIN OLD_HOST NEW_HOST TYPE CONTENT  OR  ./cf.sh rename DOMAIN OLD_HOST NEW_HOST SERVICE"
  local domain="$1" old="$2" new="$3" service="$4" owner
  owner="$(find_tunnel "$(fqdn "$domain" "$old")")" || die "No Tunnel route found for $(fqdn "$domain" "$old")"
  tunnel_rename "$(echo "$owner" | cut -f1)" "$domain" "$old" "$new" "$service"
}

[ "$#" -gt 0 ] || { usage; exit 0; }

case "$1" in
  help|-h|--help) usage ;;
  domains) [ "$#" -eq 1 ] || die "Usage: ./cf.sh domains"; list_domains ;;
  list) [ "$#" -eq 2 ] || die "Usage: ./cf.sh list DOMAIN"; list_domain "$2" ;;
  tunnels) [ "$#" -eq 1 ] || die "Usage: ./cf.sh tunnels"; list_tunnels ;;
  tunnel-list) [ "$#" -eq 2 ] || die "Usage: ./cf.sh tunnel-list TUNNEL"; t="$(tunnels | jq -c --arg n "$2" 'select(.name == $n or .id == $n)' | head -n1); [ -n "$t" ] || die "Tunnel not found: $2"; list_tunnel_routes "$t" ;;
  add) shift; simple_add "$@" ;;
  update) shift; simple_update "$@" ;;
  remove) shift; simple_remove "$@" ;;
  rename) shift; simple_rename "$@" ;;
  tunnel-add) [ "$#" -eq 5 ] || die "Usage: ./cf.sh tunnel-add TUNNEL DOMAIN HOST SERVICE"; tunnel_add "$(tunnels | jq -r --arg n "$2" 'select(.name == $n or .id == $n) | .id' | head -n1)" "$3" "$4" "$5" ;;
  tunnel-update) [ "$#" -eq 5 ] || die "Usage: ./cf.sh tunnel-update TUNNEL DOMAIN HOST SERVICE"; tunnel_update "$(tunnels | jq -r --arg n "$2" 'select(.name == $n or .id == $n) | .id' | head -n1)" "$3" "$4" "$5" ;;
  tunnel-remove) [ "$#" -eq 4 ] || die "Usage: ./cf.sh tunnel-remove TUNNEL DOMAIN HOST"; tunnel_remove "$(tunnels | jq -r --arg n "$2" 'select(.name == $n or .id == $n) | .id' | head -n1)" "$3" "$4" ;;
  tunnel-rename) [ "$#" -eq 6 ] || die "Usage: ./cf.sh tunnel-rename TUNNEL DOMAIN OLD_HOST NEW_HOST SERVICE"; tunnel_rename "$(tunnels | jq -r --arg n "$2" 'select(.name == $n or .id == $n) | .id' | head -n1)" "$3" "$4" "$5" "$6" ;;
  *) die "Unknown command '$1'. Run './cf.sh help'." ;;
esac
