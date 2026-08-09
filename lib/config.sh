# shellcheck shell=bash
# =============================================================================
# config.sh - Locate, load and validate a per-site configuration file.
#
# A site config lives in sites/<domain>.env, is gitignored, and holds BOTH the
# site constants and the credentials. Create one with: bin/new-site <domain>.
# Template: config/site.env.example
# =============================================================================

[ -n "${_WP_CONFIG_SOURCED:-}" ] && return 0
_WP_CONFIG_SOURCED=1

# REPO_ROOT must be set by the caller before sourcing this file.
: "${REPO_ROOT:?REPO_ROOT must be set before sourcing lib/config.sh}"

SITE_CONFIG_TEMPLATE="${REPO_ROOT}/config/site.env.example"
SITES_DIR="${REPO_ROOT}/sites"

# Values that must be present and must not be left as placeholders.
_REQUIRED_VARS=(
    SITE_DOMAIN SITE_TITLE SITE_LOCALE WP_VERSION WP_PATH SSL_DIR
    WP_ADMIN_USER WP_ADMIN_EMAIL WP_ADMIN_PASSWORD
    DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD
    PHP_VERSION NGINX_MODE
)

# resolve_site_config [explicit-path] -> prints the config path to use.
# Order: explicit argument, $WP_SITE_CONFIG, the only file in sites/.
resolve_site_config() {
    local explicit="${1:-}"

    if [ -n "$explicit" ]; then
        [ -f "$explicit" ] || die "Site config not found: $explicit"
        printf '%s\n' "$explicit"
        return 0
    fi

    if [ -n "${WP_SITE_CONFIG:-}" ]; then
        [ -f "$WP_SITE_CONFIG" ] || die "WP_SITE_CONFIG points to a missing file: $WP_SITE_CONFIG"
        printf '%s\n' "$WP_SITE_CONFIG"
        return 0
    fi

    local candidates=()
    local f
    for f in "$SITES_DIR"/*.env; do
        [ -f "$f" ] && candidates+=("$f")
    done

    case "${#candidates[@]}" in
        0) die "No site config found. Create one with: bin/new-site <domain>" ;;
        1) printf '%s\n' "${candidates[0]}" ;;
        *)
            err "Several site configs exist; select one with --config <file>:"
            for f in "${candidates[@]}"; do echo "    $f" >&2; done
            exit 1
            ;;
    esac
}

# load_site_config <path> - source the config, validate it, derive extra values.
load_site_config() {
    local file="$1"
    [ -f "$file" ] || die "Site config not found: $file"

    # Only real site configs carry credentials; the committed template does not.
    if [ "$(readlink -f "$file")" != "$(readlink -f "$SITE_CONFIG_TEMPLATE")" ]; then
        local perms
        perms="$(stat -c '%a' "$file" 2>/dev/null || echo '')"
        if [ -n "$perms" ] && [ "$perms" != "600" ]; then
            warn "$file has mode $perms; it holds credentials. Fix with: chmod 600 $file"
        fi
    fi

    # shellcheck disable=SC1090
    source "$file"

    SITE_CONFIG_FILE="$file"
    validate_site_config
    derive_site_config
}

validate_site_config() {
    local var value missing=0
    for var in "${_REQUIRED_VARS[@]}"; do
        value="${!var:-}"
        if [ -z "$value" ]; then
            err "Missing value in ${SITE_CONFIG_FILE}: $var"
            missing=$((missing + 1))
        elif [[ "$value" == CHANGEME* ]]; then
            err "Placeholder value still in ${SITE_CONFIG_FILE}: $var"
            missing=$((missing + 1))
        fi
    done
    [ "$missing" -eq 0 ] || die "$missing invalid value(s) in ${SITE_CONFIG_FILE}"

    case "$NGINX_MODE" in
        nginxorg|ubuntu) ;;
        *) die "Invalid NGINX_MODE '${NGINX_MODE}'. Use 'nginxorg' or 'ubuntu'." ;;
    esac

    case "$WP_PATH" in
        /*) ;;
        *) die "WP_PATH must be an absolute path: $WP_PATH" ;;
    esac
}

# Everything derived from the values above, so a config file stays short.
derive_site_config() {
    NGINX_SITE_NAME="${NGINX_SITE_NAME:-${SITE_DOMAIN//./-}}"
    PHP_FPM_SOCK="${PHP_FPM_SOCK:-/run/php/php${PHP_VERSION}-fpm.sock}"
    PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"

    SSL_CERT="${SSL_DIR}/server.crt"
    SSL_KEY="${SSL_DIR}/server.key"

    ACCESS_LOG="/var/log/nginx/${NGINX_SITE_NAME}.access.log"
    ERROR_LOG="/var/log/nginx/${NGINX_SITE_NAME}.error.log"

    if [ "$NGINX_MODE" = "nginxorg" ]; then
        NGINX_CONF_FILE="/etc/nginx/conf.d/${NGINX_SITE_NAME}.conf"
        NGINX_ENABLED_LINK=""
    else
        NGINX_CONF_FILE="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
        NGINX_ENABLED_LINK="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
    fi

    SITE_URL="https://${SITE_DOMAIN}"
    CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-64M}"
    WEB_USER="${WEB_USER:-www-data}"
    WEB_GROUP="${WEB_GROUP:-www-data}"
}

# Print the resolved configuration without any secret.
print_site_config() {
    echo "  Config file:  ${SITE_CONFIG_FILE}"
    echo "  Domain:       ${SITE_DOMAIN}"
    echo "  Site URL:     ${SITE_URL}"
    echo "  WP path:      ${WP_PATH}"
    echo "  WP version:   ${WP_VERSION} (${SITE_LOCALE})"
    echo "  DB:           ${DB_NAME} @ ${DB_HOST}:${DB_PORT} (user ${DB_USER})"
    echo "  PHP-FPM:      ${PHP_FPM_SOCK}"
    echo "  Nginx mode:   ${NGINX_MODE}"
    echo "  Nginx conf:   ${NGINX_CONF_FILE}"
    echo "  SSL dir:      ${SSL_DIR}"
}
