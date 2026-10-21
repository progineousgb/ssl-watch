#!/usr/bin/env bash
# ssl-watch - find the domains on this server and check certificate expiry.
# Maintained by Pro Gineous (https://progineous.com). MIT licensed.
set -euo pipefail

VERSION="1.0.1"
WARN_DAYS=14
CRIT_DAYS=7
JSON=0
COLOR=1
QUIET=0
SCAN=1
TIMEOUT=10
PORT=443
DOMAINS=()
CONF_DIRS=(/etc/nginx /etc/apache2 /etc/httpd /etc/caddy /usr/local/etc/nginx)

usage() {
  cat <<USAGE
ssl-watch $VERSION
Finds domains in nginx, apache and caddy configs and checks the TLS
certificate each one serves, using openssl.

Usage: ssl-watch.sh [options] [domain ...]

Options:
  -d, --domains LIST   Comma separated domains to check (host or host:port)
  -f, --file FILE      File with one domain per line (# comments allowed)
  --config-dir DIR     Scan this directory instead of the default config paths
                       (repeatable)
  --no-scan            Do not read web server configs, only check given domains
  --warn DAYS          Warn below this many days (default $WARN_DAYS)
  --crit DAYS          Critical below this many days (default $CRIT_DAYS)
  --timeout SEC        Connect timeout per domain (default $TIMEOUT)
  --json               JSON output
  -q, --quiet          Only print domains that are not OK
  --no-color           Plain output (also honoured: NO_COLOR)
  -h, --help           Show this help
  -V, --version        Show version

Exit codes (for cron):
  0 all OK, 1 at least one under --warn, 2 at least one under --crit,
  expired or unreachable, 3 usage error or nothing to check.

Cron example:
  0 8 * * * /usr/local/bin/ssl-watch.sh -q || mail -s "SSL expiry" you@example.com
USAGE
}

add_list() {
  local item
  IFS=',' read -ra items <<<"$1"
  for item in "${items[@]}"; do
    item=${item//[[:space:]]/}
    [[ -n "$item" ]] && DOMAINS+=("$item")
  done
  return 0
}

need_arg() { [[ $# -ge 2 && -n "$2" ]] || { echo "$1 needs a value" >&2; exit 3; }; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domains) need_arg "$@"; add_list "$2"; shift ;;
    -f|--file) need_arg "$@"; [[ -r "$2" ]] || { echo "Cannot read $2" >&2; exit 3; }
       while IFS= read -r line || [[ -n "$line" ]]; do
         line=${line%%#*}; line=${line//[[:space:]]/}
         [[ -n "$line" ]] && DOMAINS+=("$line")
       done <"$2"; shift ;;
    --config-dir) need_arg "$@"; [[ ${CUSTOM_DIRS:-0} -eq 0 ]] && CONF_DIRS=(); CUSTOM_DIRS=1; CONF_DIRS+=("$2"); shift ;;
    --no-scan) SCAN=0 ;;
    --warn) need_arg "$@"; WARN_DAYS=$2; shift ;;
    --crit) need_arg "$@"; CRIT_DAYS=$2; shift ;;
    --timeout) need_arg "$@"; TIMEOUT=$2; shift ;;
    --json) JSON=1 ;;
    -q|--quiet) QUIET=1 ;;
    --no-color) COLOR=0 ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) echo "ssl-watch $VERSION"; exit 0 ;;
    -*) echo "Unknown option: $1 (see --help)" >&2; exit 3 ;;
    *) add_list "$1" ;;
  esac
  shift
done

for n in "$WARN_DAYS" "$CRIT_DAYS" "$TIMEOUT"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "Day and timeout values must be whole numbers" >&2; exit 3; }
done

command -v openssl >/dev/null 2>&1 || { echo "openssl is required (apt install openssl)" >&2; exit 3; }

[[ -n "${NO_COLOR:-}" || ! -t 1 || $JSON -eq 1 ]] && COLOR=0
if [[ $COLOR -eq 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; D=""; N=""
fi

# Pull server names out of web server configs. Skips wildcards, IPs, localhost.
scan_configs() {
  local files=()
  local dir f
  for dir in "${CONF_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' f; do files+=("$f"); done \
      < <(find -L "$dir" -type f \( -name '*.conf' -o -name 'Caddyfile' -o -path '*sites-enabled*' -o -path '*conf.d*' \) -readable -print0 2>/dev/null)
  done
  [[ ${#files[@]} -eq 0 ]] && return 0
  {
    # nginx: server_name a b c;
    grep -hE '^[[:space:]]*server_name[[:space:]]' "${files[@]}" 2>/dev/null \
      | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;.*//' | sed -E 's/[[:space:]]+/\n/g' || true
    # apache: ServerName / ServerAlias
    grep -hiE '^[[:space:]]*Server(Name|Alias)[[:space:]]' "${files[@]}" 2>/dev/null \
      | sed -E 's/^[[:space:]]*[Ss]erver([Nn]ame|[Aa]lias)[[:space:]]+//' | sed -E 's/[[:space:]]+/\n/g' | sed -E 's/:[0-9]+$//' || true
    # caddy: site blocks like "example.com, www.example.com {"
    for f in "${files[@]}"; do
      [[ "$(basename "$f")" == Caddyfile || "$f" == /etc/caddy/* ]] || continue
      grep -hE '^[^[:space:]#][^{]*\{[[:space:]]*$' "$f" 2>/dev/null | sed -E 's/\{.*//; s/https?:\/\///g' | sed -E 's/[[:space:],]+/\n/g' || true
    done
  } | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' \
    | grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}(:[0-9]+)?$' \
    | grep -viE '^(localhost|_|example\.(com|org|net))$' \
    | sort -u || true
}

if [[ $SCAN -eq 1 ]]; then
  while IFS= read -r d; do [[ -n "$d" ]] && DOMAINS+=("$d"); done < <(scan_configs)
fi

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  echo "No domains found. Pass them with --domains example.com or --file domains.txt" >&2
  exit 3
fi

mapfile -t DOMAINS < <(printf '%s\n' "${DOMAINS[@]}" | awk '!seen[tolower($0)]++')

to_epoch() {
  date -d "$1" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$1" +%s 2>/dev/null || echo ""
}

# GNU timeout on Linux, gtimeout from Homebrew coreutils on macOS, then a perl
# alarm (perl ships with macOS) so a silent server cannot hang the run.
run_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$TIMEOUT" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$TIMEOUT" "$@"
  elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV or exit 127' "$TIMEOUT" "$@"
  else "$@"; fi
}

# Split host[:port], [ipv6]:port, [ipv6], or a bare IPv6 address.
# Sets HOST, PORT_OUT, and CONNECT (the -connect argument).
split_entry() {
  local e=$1
  HOST=$e; PORT_OUT=$PORT
  if [[ "$e" == \[*\]* ]]; then
    HOST=${e#\[}; HOST=${HOST%%\]*}
    local rest=${e#*\]}
    [[ "$rest" == :* ]] && PORT_OUT=${rest#:}
  elif [[ "$e" == *:*:* ]]; then
    HOST=$e
  elif [[ "$e" == *:* ]]; then
    HOST=${e%%:*}; PORT_OUT=${e##*:}
  fi
  if [[ "$HOST" == *:* ]]; then CONNECT="[$HOST]:$PORT_OUT"; else CONNECT="$HOST:$PORT_OUT"; fi
}

NOW=$(date +%s)
WORST=0
ROWS=()   # status|domain|days|expiry|issuer|note

for entry in "${DOMAINS[@]}"; do
  split_entry "$entry"
  host=$HOST
  sni=(-servername "$host")
  # SNI must be a DNS name, so skip it for an IP address.
  [[ "$host" == *:* || "$host" =~ ^[0-9.]+$ ]] && sni=()
  cert=$(run_timeout openssl s_client -connect "$CONNECT" ${sni[@]+"${sni[@]}"} </dev/null 2>/dev/null \
         | openssl x509 -noout -enddate -issuer -subject -ext subjectAltName 2>/dev/null) || cert=""
  if [[ -z "$cert" ]]; then
    ROWS+=("error|$entry|||| could not connect or no certificate")
    WORST=2
    continue
  fi
  end=$(sed -n 's/^notAfter=//p' <<<"$cert")
  issuer=$(sed -n 's/^issuer=//p' <<<"$cert" | sed -E 's/.*O ?= ?([^,]+).*/\1/; s/.*CN ?= ?([^,]+).*/\1/')
  exp=$(to_epoch "$end")
  if [[ -z "$exp" ]]; then
    ROWS+=("error|$entry||$end|$issuer|could not parse expiry date")
    WORST=2
    continue
  fi
  days=$(( (exp - NOW) / 86400 ))
  note=""
  sans=$(grep -A1 'Subject Alternative Name' <<<"$cert" | tail -1 | tr -d ' ' | tr ',' '\n' | sed -n 's/^DNS://p; s/^IPAddress://p')
  match=0
  while IFS= read -r san; do
    [[ -z "$san" ]] && continue
    if [[ "${san,,}" == "${host,,}" ]]; then match=1; break; fi
    if [[ "$san" == \*.* && "${host,,}" == *."${san#\*.}" && "${host#*.}" == "${san#\*.}" ]]; then match=1; break; fi
  done <<<"$sans"
  [[ $match -eq 0 ]] && note="name not in certificate"
  if [[ $exp -le $NOW ]]; then st=expired; WORST=2
  elif [[ $days -lt $CRIT_DAYS ]]; then st=critical; WORST=2
  elif [[ $days -lt $WARN_DAYS ]]; then st=warning; [[ $WORST -lt 1 ]] && WORST=1
  else st=ok; fi
  if [[ $match -eq 0 && $st == ok ]]; then st=warning; [[ $WORST -lt 1 ]] && WORST=1; fi
  ROWS+=("$st|$entry|$days|$(date -d "@$exp" '+%Y-%m-%d' 2>/dev/null || echo "$end")|$issuer|$note")
done

json_esc() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }

if [[ $JSON -eq 1 ]]; then
  printf '{"tool":"ssl-watch","version":"%s","warn_days":%d,"crit_days":%d,"exit_code":%d,"certificates":[' \
    "$VERSION" "$WARN_DAYS" "$CRIT_DAYS" "$WORST"
  first=1
  for r in "${ROWS[@]}"; do
    IFS='|' read -r st dm dy ex is nt <<<"$r"
    [[ $first -eq 0 ]] && printf ','
    first=0
    printf '{"domain":"%s","status":"%s","days_left":%s,"expires":"%s","issuer":"%s","note":"%s"}' \
      "$(json_esc "$dm")" "$st" "${dy:-null}" "$(json_esc "$ex")" "$(json_esc "$is")" "$(json_esc "${nt# }")"
  done
  printf ']}\n'
  exit "$WORST"
fi

[[ $QUIET -eq 0 ]] && printf '%s%-36s %-9s %6s  %-11s %s%s\n' "$B" "DOMAIN" "STATUS" "DAYS" "EXPIRES" "ISSUER" "$N"
for r in "${ROWS[@]}"; do
  IFS='|' read -r st dm dy ex is nt <<<"$r"
  [[ $QUIET -eq 1 && $st == ok ]] && continue
  case "$st" in
    ok) c=$G ;; warning) c=$Y ;; *) c=$R ;;
  esac
  printf '%-36s %s%-9s%s %6s  %-11s %s' "$dm" "$c" "${st^^}" "$N" "${dy:--}" "${ex:--}" "${is:--}"
  [[ -n "${nt// /}" ]] && printf '  %s(%s)%s' "$D" "${nt# }" "$N"
  printf '\n'
done
if [[ $QUIET -eq 0 ]]; then
  printf '\n%sChecked %d domain(s). Warn under %d days, critical under %d. Exit code %d.%s\n' \
    "$D" "${#ROWS[@]}" "$WARN_DAYS" "$CRIT_DAYS" "$WORST" "$N"
fi
exit "$WORST"
