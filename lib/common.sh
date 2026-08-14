# shellcheck shell=bash
# =============================================================================
# common.sh - Shared logging helpers and small utilities.
# Sourced by every script under bin/. Not executable on its own.
# =============================================================================

[ -n "${_WP_COMMON_SOURCED:-}" ] && return 0
_WP_COMMON_SOURCED=1

# Colors are disabled when stdout is not a terminal or NO_COLOR is set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'
    C_BOLD=$'\033[1m'
    C_NC=$'\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_NC=''
fi

# Set to true by callers (e.g. --yes) to skip every interactive prompt.
ASSUME_YES="${ASSUME_YES:-false}"

_STEP_NO=0

banner() {
    echo ""
    echo "${C_BLUE}${C_BOLD}================================================================${C_NC}"
    echo "${C_BLUE}${C_BOLD}  $1${C_NC}"
    [ -n "${2:-}" ] && echo "${C_BLUE}  $2${C_NC}"
    echo "${C_BLUE}${C_BOLD}================================================================${C_NC}"
    echo ""
}

section() {
    echo ""
    echo "  ${C_BOLD}$1${C_NC}"
    echo "  --------------------------------------------------"
}

step() {
    _STEP_NO=$((_STEP_NO + 1))
    echo ""
    echo "${C_BLUE}[STEP ${_STEP_NO}]${C_NC} $1"
}

ok()   { echo "  ${C_GREEN}[OK]${C_NC}    $1"; }
info() { echo "  ${C_BLUE}[INFO]${C_NC}  $1"; }
warn() { echo "  ${C_YELLOW}[WARN]${C_NC}  $1" >&2; }
err()  { echo "  ${C_RED}[ERROR]${C_NC} $1" >&2; }

die() {
    echo "" >&2
    echo "  ${C_RED}${C_BOLD}[FATAL]${C_NC} $1" >&2
    echo "" >&2
    exit 1
}

# confirm "question" -> 0 on yes, 1 on no. Always yes when ASSUME_YES=true.
confirm() {
    if [ "$ASSUME_YES" = true ]; then
        info "$1 [auto-yes]"
        return 0
    fi
    local answer
    read -r -p "  $1 [y/N]: " answer
    [[ "$answer" =~ ^([yY]|[sS])$ ]]
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must run as root. Try: sudo bash $0 $*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# render_template <template-file> KEY=VALUE ... -> rendered content on stdout.
# Replaces every {{KEY}} token. Pure bash: values are never re-interpreted,
# so passwords, slashes and regex metacharacters are safe.
render_template() {
    local template="$1"; shift
    [ -f "$template" ] || die "Template not found: $template"

    local content pair key value
    content="$(cat "$template")"
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        content="${content//\{\{$key\}\}/$value}"
    done

    if [[ "$content" == *'{{'* ]]; then
        warn "Template $template still contains unresolved {{...}} tokens."
    fi
    printf '%s\n' "$content"
}

# print_usage <script-file> - print the leading comment header as help text,
# without the shebang and without the '# ====' rules that delimit it.
print_usage() {
    awk '
        NR == 1 && /^#!/ { next }
        /^# ?={10,}/     { if (++rules > 1) exit; next }
        /^#/             { sub(/^# ?/, ""); print; next }
        { exit }
    ' "$1"
}

# generate_password [length] [tr-charset] - random string, alphanumeric by
# default so it never needs quoting in SQL, YAML or the shell.
#
# /dev/urandom is read in bounded chunks instead of being piped into `head`:
# that pipeline kills `tr` with SIGPIPE, and under `set -o pipefail` the
# non-zero status aborts the caller intermittently.
generate_password() {
    local length="${1:-24}"
    local charset="${2:-A-Za-z0-9}"
    local out=""

    while [ "${#out}" -lt "$length" ]; do
        out+="$(LC_ALL=C tr -dc "$charset" < <(head -c 256 /dev/urandom))"
    done

    printf '%s\n' "${out:0:length}"
}

# MariaDB/MySQL client wrapper for root socket access (script already runs as root).
db_root() {
    if command -v mariadb >/dev/null 2>&1; then
        mariadb "$@"
    else
        mysql "$@"
    fi
}

# Names of the available client binaries, MariaDB first.
db_client()      { command -v mariadb      >/dev/null 2>&1 && echo mariadb      || echo mysql; }
db_dump_client() { command -v mariadb-dump >/dev/null 2>&1 && echo mariadb-dump || echo mysqldump; }

# db_as_user <client-binary> [args...] - run a client as DB_USER, reading
# DB_USER/DB_PASSWORD/DB_HOST/DB_PORT from the loaded site config.
#
# The credentials travel in a temporary 0600 defaults file instead of on the
# command line, where `-p<password>` would be readable through `ps` by every
# local user for the lifetime of the process (a full dump, for instance).
db_as_user() {
    local client="$1"; shift
    local cnf status=0

    cnf="$(mktemp)" || die "Cannot create a temporary defaults file."
    chmod 600 "$cnf"

    # Option-file values are unescaped on read: protect backslashes first, then quotes.
    local password="${DB_PASSWORD//\\/\\\\}"
    password="${password//\"/\\\"}"
    printf '[client]\nuser="%s"\npassword="%s"\nhost="%s"\nport="%s"\n' \
        "$DB_USER" "$password" "$DB_HOST" "$DB_PORT" > "$cnf"

    # --defaults-extra-file must come first, before any other option.
    "$client" --defaults-extra-file="$cnf" "$@" || status=$?
    rm -f "$cnf"
    return "$status"
}
