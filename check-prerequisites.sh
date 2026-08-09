#!/bin/bash

# ==============================================================================
# check-prerequisites.sh
# Verifica e instala los prerequisitos para WordPress en Ubuntu 24.04 LTS
#
# Flujo:
#   1. Verificar todo sin instalar nada (modo check)
#   2. Mostrar resumen de lo que falta
#   3. Preguntar confirmacion antes de instalar
#   4. Instalar solo lo que falta
#
# Componentes gestionados (instala si falta):
#   - Nginx 1.30.x (repo oficial nginx.org mainline)
#   - PHP 8.3 + extensiones requeridas por WordPress
#   - WP-CLI
#   - Utilitarios: curl, wget, openssl, unzip, gnupg2, etc.
#
# Componentes SOLO VERIFICADOS (no instala):
#   - MariaDB 11.4+ (se asume instalado previamente)
#
# Uso:
#   sudo bash check-prerequisites.sh
# ==============================================================================

# Nota: no usamos set -e aqui intencionalmente.
# Este es un script de verificacion — muchos comandos retornan exit code != 0
# cuando un paquete no esta instalado, lo cual es el comportamiento esperado.
set -uo pipefail

# ==============================================================================
# CONFIGURACION
# ==============================================================================

# Rama de Nginx: "stable" para 1.30.x | "mainline" para 1.31.x+
NGINX_BRANCH="stable"

# Version minima de MariaDB requerida
MARIADB_MIN_VERSION="11.4"

# Version de PHP a instalar
PHP_VERSION="8.3"

# ==============================================================================
# NO EDITAR A PARTIR DE AQUI
# ==============================================================================

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Arrays para tracking del estado de verificacion
declare -a TO_INSTALL=()      # paquetes/componentes que faltan y se pueden instalar
declare -a CHECK_OK=()        # componentes ya instalados y correctos
declare -a CHECK_WARN=()      # advertencias (no bloquean pero hay que revisar)
declare -a CHECK_ERROR=()     # errores que bloquean (ej: MariaDB faltante)

# Estado por componente (para la fase de instalacion)
NEED_NGINX=false
NEED_PHP=false
NEED_WPCLI=false
NEED_UTILITIES=false
MARIADB_OK=false

print_header() {
    echo ""
    echo -e "${BLUE}${BOLD}================================================================${NC}"
    echo -e "${BLUE}${BOLD}  WordPress Prerequisites Checker${NC}"
    echo -e "${BLUE}${BOLD}  Ubuntu 24.04 LTS (noble)${NC}"
    echo -e "${BLUE}${BOLD}================================================================${NC}"
    echo ""
    echo -e "  ${BLUE}Fase 1:${NC} Verificando el estado del sistema..."
    echo ""
}

print_section() {
    echo ""
    echo -e "  ${BOLD}$1${NC}"
    echo "  $(printf '%.0s-' {1..50})"
}

mark_ok() {
    echo -e "    ${GREEN}[OK]${NC}    $1"
    CHECK_OK+=("$1")
}

mark_missing() {
    echo -e "    ${YELLOW}[FALTA]${NC} $1"
    TO_INSTALL+=("$1")
}

mark_warn() {
    echo -e "    ${YELLOW}[AVISO]${NC} $1"
    CHECK_WARN+=("$1")
}

mark_error() {
    echo -e "    ${RED}[ERROR]${NC} $1"
    CHECK_ERROR+=("$1")
}

mark_info() {
    echo -e "    ${BLUE}[INFO]${NC}  $1"
}

# ==============================================================================
# FASE 1: VERIFICACIONES (sin instalar nada)
# ==============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Este script requiere permisos de root.${NC}"
        echo "Ejecutar con: sudo bash $0"
        exit 1
    fi
}

check_os() {
    print_section "Sistema Operativo"

    if [ ! -f /etc/os-release ]; then
        mark_error "No se puede determinar el sistema operativo."
        exit 1
    fi

    source /etc/os-release

    if [ "$ID" != "ubuntu" ]; then
        mark_error "Este script es para Ubuntu. Sistema detectado: $ID"
        exit 1
    fi

    if [ "$VERSION_CODENAME" != "noble" ]; then
        mark_warn "Ubuntu $VERSION_ID ($VERSION_CODENAME) — disenado para 24.04 (noble). Puede funcionar."
    else
        mark_ok "Ubuntu 24.04 LTS (noble)"
    fi
}

check_utilities_status() {
    print_section "Utilitarios base"

    local pkgs=("curl" "wget" "openssl" "unzip" "gnupg2" "ca-certificates" "lsb-release" "ubuntu-keyring" "apt-transport-https")
    local missing_utils=()

    for pkg in "${pkgs[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then
            mark_ok "$pkg"
        else
            mark_missing "$pkg"
            missing_utils+=("$pkg")
        fi
    done

    if [ ${#missing_utils[@]} -gt 0 ]; then
        NEED_UTILITIES=true
    fi
}

check_nginx_status() {
    print_section "Nginx (objetivo: 1.30.x stable desde nginx.org)"

    if command -v nginx &>/dev/null; then
        local current_version
        current_version=$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1)

        # Verificar si es exactamente 1.30.x (rama stable nginx.org)
        if [[ "$current_version" == 1.30.* ]]; then
            mark_ok "Nginx $current_version"

            if systemctl is-active --quiet nginx; then
                mark_ok "Servicio nginx activo"
            else
                mark_warn "Nginx instalado pero el servicio no esta en ejecucion"
                NEED_NGINX=true
            fi
        else
            mark_missing "Nginx $current_version instalado — se requiere 1.30.x stable (se instalara desde nginx.org)"
            NEED_NGINX=true
        fi
    else
        mark_missing "Nginx no instalado"
        NEED_NGINX=true
    fi
}

check_php_status() {
    print_section "PHP ${PHP_VERSION} + extensiones WordPress"

    local php_pkgs=(
        "php${PHP_VERSION}-fpm"
        "php${PHP_VERSION}-mysql"
        "php${PHP_VERSION}-curl"
        "php${PHP_VERSION}-gd"
        "php${PHP_VERSION}-mbstring"
        "php${PHP_VERSION}-xml"
        "php${PHP_VERSION}-zip"
        "php${PHP_VERSION}-intl"
        "php${PHP_VERSION}-bcmath"
        "php${PHP_VERSION}-imagick"
        "php${PHP_VERSION}-soap"
        "php${PHP_VERSION}-cli"
    )

    local missing_php=()

    for pkg in "${php_pkgs[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then
            mark_ok "$pkg"
        else
            mark_missing "$pkg"
            missing_php+=("$pkg")
        fi
    done

    if [ ${#missing_php[@]} -gt 0 ]; then
        NEED_PHP=true
    else
        # Todos instalados — verificar servicio FPM y socket
        local fpm_service="php${PHP_VERSION}-fpm"
        if systemctl is-active --quiet "$fpm_service"; then
            mark_ok "Servicio $fpm_service activo"
        else
            mark_warn "php${PHP_VERSION}-fpm instalado pero el servicio no esta activo"
            NEED_PHP=true
        fi

        local fpm_sock="/run/php/php${PHP_VERSION}-fpm.sock"
        if [ -S "$fpm_sock" ]; then
            mark_ok "Socket FPM: $fpm_sock"
        else
            mark_warn "Socket FPM no encontrado: $fpm_sock"
        fi
    fi
}

check_mariadb_status() {
    print_section "MariaDB (solo verificacion — no se instala)"

    if ! command -v mariadb &>/dev/null && ! command -v mysql &>/dev/null; then
        mark_error "MariaDB no esta instalado"
        mark_info "Instalar con:"
        echo ""
        echo "      curl -fsSL https://r.mariadb.com/downloads/mariadb_repo_setup \\"
        echo "        | sudo bash -s -- --mariadb-server-version=mariadb-11.4"
        echo "      sudo apt-get update"
        echo "      sudo apt-get install -y mariadb-server mariadb-client"
        echo "      sudo systemctl enable --now mariadb"
        echo ""
        return
    fi

    # Verificar version
    # Formatos conocidos de mariadb --version:
    #   "mariadb from 11.4.11-MariaDB, client 15.2 for ..."  (MariaDB >= 11.x)
    #   "mariadb  Ver 15.1 Distrib 10.x.x-MariaDB, for ..."  (MariaDB <= 10.x)
    local mariadb_version
    local version_raw
    if command -v mariadb &>/dev/null; then
        version_raw=$(mariadb --version 2>&1)
    else
        version_raw=$(mysql --version 2>&1)
    fi

    # Intentar "from X.Y.Z" primero (formato >= 11.x)
    mariadb_version=$(echo "$version_raw" | grep -oP 'from \K[\d.]+' | head -1)
    # Si no, intentar "Distrib X.Y.Z" (formato <= 10.x)
    if [ -z "$mariadb_version" ]; then
        mariadb_version=$(echo "$version_raw" | grep -oP 'Distrib \K[\d.]+' | head -1)
    fi
    # Ultimo recurso: primer X.Y.Z en la linea
    if [ -z "$mariadb_version" ]; then
        mariadb_version=$(echo "$version_raw" | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)
    fi

    if [ -z "$mariadb_version" ]; then
        mark_warn "No se pudo determinar la version de MariaDB"
    else
        local major minor req_major req_minor
        major=$(echo "$mariadb_version" | cut -d. -f1)
        minor=$(echo "$mariadb_version" | cut -d. -f2)
        req_major=$(echo "$MARIADB_MIN_VERSION" | cut -d. -f1)
        req_minor=$(echo "$MARIADB_MIN_VERSION" | cut -d. -f2)

        if [ "$major" -gt "$req_major" ] || { [ "$major" -eq "$req_major" ] && [ "$minor" -ge "$req_minor" ]; }; then
            mark_ok "MariaDB $mariadb_version (>= $MARIADB_MIN_VERSION)"
        else
            mark_error "MariaDB $mariadb_version — se requiere >= $MARIADB_MIN_VERSION"
            return
        fi
    fi

    # Verificar servicio
    if systemctl is-active --quiet mariadb; then
        mark_ok "Servicio mariadb activo"
    else
        mark_error "Servicio mariadb no esta en ejecucion — iniciar con: sudo systemctl start mariadb"
        return
    fi

    # Verificar conectividad socket
    if sudo mysql -e "SELECT 1;" &>/dev/null 2>&1; then
        mark_ok "Conectividad via socket (root) verificada"
        MARIADB_OK=true
    else
        mark_warn "No se puede conectar a MariaDB via socket como root"
        mark_warn "El installer requiere: sudo mysql -e 'SELECT 1;' funcional"
    fi
}

check_wpcli_status() {
    print_section "WP-CLI"

    if command -v wp &>/dev/null; then
        local wpcli_version
        wpcli_version=$(wp --info --allow-root 2>/dev/null | grep "WP-CLI version" | awk '{print $NF}' || echo "desconocida")
        mark_ok "WP-CLI $wpcli_version en $(command -v wp)"
    else
        mark_missing "WP-CLI no instalado"
        NEED_WPCLI=true
    fi
}

# ==============================================================================
# RESUMEN DE VERIFICACION + CONFIRMACION
# ==============================================================================

print_check_summary() {
    echo ""
    echo -e "${BLUE}${BOLD}================================================================${NC}"
    echo -e "${BLUE}${BOLD}  RESUMEN DE VERIFICACION${NC}"
    echo -e "${BLUE}${BOLD}================================================================${NC}"
    echo ""
    echo -e "  ${GREEN}Correctos:${NC}    ${#CHECK_OK[@]} componente(s)"
    echo -e "  ${YELLOW}Faltantes:${NC}    ${#TO_INSTALL[@]} componente(s) para instalar"
    echo -e "  ${YELLOW}Advertencias:${NC} ${#CHECK_WARN[@]} aviso(s)"
    echo -e "  ${RED}Errores:${NC}      ${#CHECK_ERROR[@]} error(es) que requieren accion manual"
    echo ""

    # Mostrar errores criticos (no instalables por el script)
    if [ ${#CHECK_ERROR[@]} -gt 0 ]; then
        echo -e "  ${RED}${BOLD}Errores que requieren accion manual:${NC}"
        for err in "${CHECK_ERROR[@]}"; do
            echo -e "    ${RED}x${NC} $err"
        done
        echo ""
        echo -e "  ${RED}Resolver los errores anteriores antes de continuar.${NC}"
        echo ""
        exit 1
    fi

    # Si todo esta OK, no hay nada que instalar
    if [ ${#TO_INSTALL[@]} -eq 0 ] && [ ${#CHECK_WARN[@]} -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}Todo esta instalado y correcto.${NC}"
        echo ""
        print_installed_versions
        echo -e "  ${GREEN}Listo para ejecutar: sudo bash install-wordpress.sh${NC}"
        echo ""
        exit 0
    fi

    # Si solo hay advertencias pero nada que instalar
    if [ ${#TO_INSTALL[@]} -eq 0 ] && [ ${#CHECK_WARN[@]} -gt 0 ]; then
        echo -e "  ${YELLOW}Advertencias activas:${NC}"
        for w in "${CHECK_WARN[@]}"; do
            echo -e "    ${YELLOW}!${NC} $w"
        done
        echo ""
        echo -e "  ${GREEN}Todos los componentes requeridos estan instalados.${NC}"
        echo -e "  ${GREEN}Listo para ejecutar: sudo bash install-wordpress.sh${NC}"
        echo ""
        exit 0
    fi

    # Hay componentes para instalar — mostrar lista y pedir confirmacion
    echo -e "  ${YELLOW}${BOLD}Componentes que se instalaran:${NC}"
    for item in "${TO_INSTALL[@]}"; do
        echo -e "    ${YELLOW}+${NC} $item"
    done
    echo ""

    if $NEED_NGINX; then
        echo -e "    ${BLUE}Nginx:${NC}  repo mainline nginx.org (1.30.x) + GPG verification"
    fi
    if $NEED_PHP; then
        echo -e "    ${BLUE}PHP:${NC}    php${PHP_VERSION}-fpm + 11 extensiones WordPress"
    fi
    if $NEED_WPCLI; then
        echo -e "    ${BLUE}WP-CLI:${NC} descarga desde github.com/wp-cli"
    fi
    if $NEED_UTILITIES; then
        echo -e "    ${BLUE}Utils:${NC}  curl wget openssl unzip gnupg2 y otros"
    fi
    echo ""

    if [ ${#CHECK_WARN[@]} -gt 0 ]; then
        echo -e "  ${YELLOW}Advertencias:${NC}"
        for w in "${CHECK_WARN[@]}"; do
            echo -e "    ${YELLOW}!${NC} $w"
        done
        echo ""
    fi
}

confirm_installation() {
    echo -e "${BLUE}================================================================${NC}"
    echo ""
    read -r -p "  ¿Proceder con la instalacion de los componentes faltantes? [s/N]: " confirm
    echo ""

    if [[ ! "$confirm" =~ ^[sySY]$ ]]; then
        echo -e "  ${YELLOW}Instalacion cancelada.${NC}"
        echo "  Volver a ejecutar este script cuando desee instalar los prerequisitos."
        echo ""
        exit 0
    fi
}

# ==============================================================================
# FASE 2: INSTALACION (solo si el usuario confirma)
# ==============================================================================

do_install() {
    # A partir de aqui si queremos abortar ante errores
    set -e

    echo ""
    echo -e "${BLUE}${BOLD}================================================================${NC}"
    echo -e "${BLUE}${BOLD}  Fase 2: Instalando componentes faltantes${NC}"
    echo -e "${BLUE}${BOLD}================================================================${NC}"

    # Actualizar apt primero
    echo ""
    echo -e "  ${BLUE}Actualizando lista de paquetes...${NC}"
    apt-get update -qq
    echo -e "  ${GREEN}[OK]${NC} apt-get update completado"

    # Utilitarios base (necesarios para agregar repos)
    if $NEED_UTILITIES; then
        echo ""
        echo -e "  ${BLUE}Instalando utilitarios base...${NC}"
        local pkgs=("curl" "wget" "openssl" "unzip" "gnupg2" "ca-certificates" "lsb-release" "ubuntu-keyring" "apt-transport-https")
        local to_inst=()
        for pkg in "${pkgs[@]}"; do
            dpkg -s "$pkg" &>/dev/null || to_inst+=("$pkg")
        done
        if [ ${#to_inst[@]} -gt 0 ]; then
            apt-get install -y -qq "${to_inst[@]}"
            for pkg in "${to_inst[@]}"; do
                echo -e "  ${GREEN}[INSTALADO]${NC} $pkg"
            done
        fi
    fi

    # Nginx
    if $NEED_NGINX; then
        install_nginx
    fi

    # PHP
    if $NEED_PHP; then
        install_php
    fi

    # WP-CLI (requiere PHP instalado)
    if $NEED_WPCLI; then
        install_wpcli
    fi
}

install_nginx() {
    echo ""
    echo -e "  ${BLUE}Instalando Nginx 1.30.x (stable) desde nginx.org...${NC}"

    local keyring="/usr/share/keyrings/nginx-archive-keyring.gpg"
    local sources_file="/etc/apt/sources.list.d/nginx.list"
    local prefs_file="/etc/apt/preferences.d/99nginx"

    # Importar GPG key
    echo -e "  ${BLUE}[INFO]${NC}  Importando GPG key de nginx.org..."
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
        | tee "$keyring" >/dev/null

    # Verificar fingerprint
    # Segun documentacion oficial de nginx.org, el keyring DEBE contener:
    #   573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62
    # El output puede incluir otras claves adicionales — eso es normal.
    local expected_fingerprint="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"

    local found_fingerprints
    found_fingerprints=$(gpg --dry-run --quiet --no-keyring --import --import-options import-show "$keyring" 2>/dev/null \
        | grep -oP '[0-9A-F]{40}' | tr -d ' ')

    if echo "$found_fingerprints" | grep -q "$expected_fingerprint"; then
        echo -e "  ${GREEN}[OK]${NC}    GPG fingerprint verificado: $expected_fingerprint"
    else
        echo -e "  ${RED}[ERROR]${NC} GPG fingerprint oficial no encontrado en el keyring descargado."
        echo "          Esperado: $expected_fingerprint"
        echo "          Encontrados:"
        echo "$found_fingerprints" | while read -r fp; do [ -n "$fp" ] && echo "            $fp"; done
        echo "          Abortando por seguridad."
        exit 1
    fi

    # Agregar repositorio
    if [ "$NGINX_BRANCH" = "mainline" ]; then
        echo "deb [signed-by=${keyring}] https://nginx.org/packages/mainline/ubuntu $(lsb_release -cs) nginx" \
            | tee "$sources_file" >/dev/null
    else
        echo "deb [signed-by=${keyring}] https://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
            | tee "$sources_file" >/dev/null
    fi

    # Pinning para priorizar nginx.org sobre Ubuntu repos
    printf "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
        | tee "$prefs_file" >/dev/null

    apt-get update -qq
    apt-get install -y nginx

    local installed_ver
    installed_ver=$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1)
    echo -e "  ${GREEN}[INSTALADO]${NC} Nginx $installed_ver"

    systemctl enable nginx --quiet
    systemctl start nginx
    echo -e "  ${GREEN}[OK]${NC}    Nginx habilitado e iniciado"
}

install_php() {
    echo ""
    echo -e "  ${BLUE}Instalando PHP ${PHP_VERSION} + extensiones WordPress...${NC}"

    local php_pkgs=(
        "php${PHP_VERSION}-fpm"
        "php${PHP_VERSION}-mysql"
        "php${PHP_VERSION}-curl"
        "php${PHP_VERSION}-gd"
        "php${PHP_VERSION}-mbstring"
        "php${PHP_VERSION}-xml"
        "php${PHP_VERSION}-zip"
        "php${PHP_VERSION}-intl"
        "php${PHP_VERSION}-bcmath"
        "php${PHP_VERSION}-imagick"
        "php${PHP_VERSION}-soap"
        "php${PHP_VERSION}-cli"
    )

    local missing_pkgs=()
    for pkg in "${php_pkgs[@]}"; do
        dpkg -s "$pkg" &>/dev/null || missing_pkgs+=("$pkg")
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        apt-get install -y -qq "${missing_pkgs[@]}"
        for pkg in "${missing_pkgs[@]}"; do
            echo -e "  ${GREEN}[INSTALADO]${NC} $pkg"
        done
    fi

    # Habilitar e iniciar php-fpm
    local fpm_service="php${PHP_VERSION}-fpm"
    systemctl enable "$fpm_service" --quiet
    systemctl start "$fpm_service"
    echo -e "  ${GREEN}[OK]${NC}    $fpm_service habilitado e iniciado"

    # Verificar socket
    local fpm_sock="/run/php/php${PHP_VERSION}-fpm.sock"
    sleep 1
    if [ -S "$fpm_sock" ]; then
        echo -e "  ${GREEN}[OK]${NC}    Socket FPM disponible: $fpm_sock"
    else
        echo -e "  ${YELLOW}[AVISO]${NC} Socket FPM no encontrado en $fpm_sock — verificar php-fpm"
    fi
}

install_wpcli() {
    echo ""
    echo -e "  ${BLUE}Instalando WP-CLI...${NC}"

    local wpcli_bin="/usr/local/bin/wp"
    local wpcli_url="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"

    curl -fsSL "$wpcli_url" -o /tmp/wp-cli.phar

    if ! php /tmp/wp-cli.phar --info --allow-root &>/dev/null; then
        echo -e "  ${RED}[ERROR]${NC} WP-CLI descargado no es valido. Verificar conectividad y reintentar."
        rm -f /tmp/wp-cli.phar
        exit 1
    fi

    chmod +x /tmp/wp-cli.phar
    mv /tmp/wp-cli.phar "$wpcli_bin"

    local wpcli_version
    wpcli_version=$(wp --info --allow-root 2>/dev/null | grep "WP-CLI version" | awk '{print $NF}' || echo "instalado")
    echo -e "  ${GREEN}[INSTALADO]${NC} WP-CLI $wpcli_version en $wpcli_bin"
}

# ==============================================================================
# RESUMEN FINAL POST-INSTALACION
# ==============================================================================

print_installed_versions() {
    echo -e "  ${BLUE}Versiones en el sistema:${NC}"
    command -v nginx   &>/dev/null && echo "    Nginx:   $(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1)"
    command -v php     &>/dev/null && echo "    PHP:     $(php -r 'echo PHP_VERSION;')"
    if command -v mariadb &>/dev/null; then
        local db_ver
        db_ver=$(mariadb --version 2>&1 | grep -oP 'from \K[\d.]+' | head -1)
        [ -z "$db_ver" ] && db_ver=$(mariadb --version 2>&1 | grep -oP 'Distrib \K[\d.]+' | head -1)
        [ -z "$db_ver" ] && db_ver=$(mariadb --version 2>&1 | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)
        echo "    MariaDB: $db_ver"
    elif command -v mysql &>/dev/null; then
        echo "    MariaDB: $(mysql --version 2>&1 | grep -oP '[\d]+\.[\d]+\.[\d]+' | head -1)"
    fi
    command -v wp      &>/dev/null && echo "    WP-CLI:  $(wp --info --allow-root 2>/dev/null | grep 'WP-CLI version' | awk '{print $NF}')"
    echo ""
}

print_final_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}================================================================${NC}"
    echo -e "${GREEN}${BOLD}  PREREQUISITOS SATISFECHOS${NC}"
    echo -e "${GREEN}${BOLD}================================================================${NC}"
    echo ""
    print_installed_versions

    if [ ${#CHECK_WARN[@]} -gt 0 ]; then
        echo -e "  ${YELLOW}Advertencias pendientes:${NC}"
        for w in "${CHECK_WARN[@]}"; do
            echo -e "    ${YELLOW}!${NC} $w"
        done
        echo ""
    fi

    echo -e "  ${GREEN}Siguiente paso: editar las variables en install-wordpress.sh${NC}"
    echo -e "  ${GREEN}y ejecutar: sudo bash install-wordpress.sh${NC}"
    echo ""
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    print_header
    check_root
    check_os
    check_utilities_status
    check_nginx_status
    check_php_status
    check_mariadb_status
    check_wpcli_status

    # Mostrar resumen y pedir confirmacion si hay algo que instalar
    print_check_summary

    # Si llegamos aqui, hay componentes para instalar y el usuario confirmo
    confirm_installation
    do_install
    print_final_summary
}

main "$@"
