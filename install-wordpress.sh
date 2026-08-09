#!/bin/bash

# ==============================================================================
# install-wordpress.sh
# Instalacion limpia de WordPress en Ubuntu 24.04 LTS (sin Docker)
#
# Stack:
#   - WordPress (version parametrizable, por defecto "latest")
#   - PHP 8.3 + FPM via unix socket
#   - MariaDB 11.4 (debe estar instalado y activo — ver check-prerequisites.sh)
#   - Nginx 1.30.x desde repo oficial nginx.org
#   - SSL autofirmado (o se usa certificado existente)
#   - WP-CLI para instalacion y configuracion automatizada
#
# Uso:
#   1. Editar la seccion CONFIGURACION a continuacion
#   2. sudo bash install-wordpress.sh
#
# Prerequisitos:
#   Ejecutar primero: sudo bash check-prerequisites.sh
# ==============================================================================

set -euo pipefail

# ==============================================================================
# CONFIGURACION — EDITAR ESTA SECCION
# ==============================================================================

# --- WordPress ---
WP_VERSION="latest"                    # "latest" o version especifica ej: "6.7.2"
WP_PATH="/apps/example_wp"             # Ruta absoluta donde instalar WordPress
WP_TITLE="Mi Sitio WordPress"          # Titulo del sitio
WP_ADMIN_USER="admin"                  # Usuario administrador de WordPress
WP_ADMIN_PASSWORD="changeme123!"       # Password del administrador (usar una segura)
WP_ADMIN_EMAIL="admin@example.com"     # Email del administrador
WP_LOCALE="en_US"                      # Idioma: "es_ES", "en_US", etc.

# --- Base de datos (usuario dedicado creado por este script) ---
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_NAME="wp_example"                   # Nombre de la base de datos
DB_USER="wp_example_user"              # Usuario dedicado para esta instalacion
DB_PASSWORD="changeme456!"             # Password del usuario de DB (usar una segura)

# --- Servidor web ---
SERVER_NAME="example.com"              # Dominio o IP del servidor
NGINX_SITE_NAME="wordpress-example"    # Nombre del sitio en Nginx

# Modo Nginx segun el origen de instalacion:
#   "nginxorg"  — Nginx instalado desde nginx.org (1.30.x/1.31.x)
#                 Usa /etc/nginx/conf.d/*.conf (include directo, sin symlinks)
#   "ubuntu"    — Nginx instalado desde repositorios de Ubuntu (1.24.x)
#                 Usa /etc/nginx/sites-available + sites-enabled (symlinks)
NGINX_MODE="nginxorg"

# --- SSL ---
SSL_PATH="/apps/ssl/example_wp"        # Directorio para los certificados SSL
SSL_CERT="${SSL_PATH}/server.crt"
SSL_KEY="${SSL_PATH}/server.key"

# --- PHP-FPM ---
PHP_VERSION="8.3"
PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

# ==============================================================================
# NO EDITAR A PARTIR DE AQUI
# ==============================================================================

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Usuario del servidor web
WEB_USER="www-data"
WEB_GROUP="www-data"

print_header() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}  WordPress Installer — Sin Docker${NC}"
    echo -e "${BLUE}  Ubuntu 24.04 LTS | PHP ${PHP_VERSION} | MariaDB 11.4 | Nginx 1.30.x${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
    echo -e "  ${BLUE}Configuracion detectada:${NC}"
    echo "    WP Path:      $WP_PATH"
    echo "    WP Version:   $WP_VERSION"
    echo "    WP Locale:    $WP_LOCALE"
    echo "    Server Name:  $SERVER_NAME"
    echo "    DB Name:      $DB_NAME"
    echo "    DB User:      $DB_USER"
    echo "    PHP-FPM:      $PHP_FPM_SOCK"
    echo ""
}

step() {
    echo ""
    echo -e "${BLUE}[PASO $1]${NC} $2"
}

ok() {
    echo -e "  ${GREEN}[OK]${NC} $1"
}

info() {
    echo -e "  ${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "  ${YELLOW}[AVISO]${NC} $1"
}

die() {
    echo ""
    echo -e "  ${RED}[ERROR FATAL]${NC} $1"
    echo ""
    exit 1
}

# ------------------------------------------------------------------------------
# PASO 1: Verificar root
# ------------------------------------------------------------------------------
check_root() {
    step "1" "Verificando permisos"
    if [ "$EUID" -ne 0 ]; then
        die "Este script requiere root. Ejecutar con: sudo bash $0"
    fi
    ok "Ejecutando como root"
}

# ------------------------------------------------------------------------------
# PASO 2: Verificar prerequisitos criticos
# ------------------------------------------------------------------------------
check_prerequisites() {
    step "2" "Verificando prerequisitos"

    local missing=0

    # Nginx
    if ! command -v nginx &>/dev/null; then
        echo -e "  ${RED}[FALTA]${NC} nginx"
        missing=$((missing + 1))
    else
        ok "Nginx: $(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1)"
    fi

    # PHP-FPM
    if ! command -v "php${PHP_VERSION}" &>/dev/null && ! command -v php &>/dev/null; then
        echo -e "  ${RED}[FALTA]${NC} php${PHP_VERSION}"
        missing=$((missing + 1))
    else
        ok "PHP: $(php -r 'echo PHP_VERSION;')"
    fi

    # PHP-FPM socket
    if [ ! -S "$PHP_FPM_SOCK" ]; then
        warn "Socket PHP-FPM no encontrado: $PHP_FPM_SOCK"
        warn "Intentando iniciar php${PHP_VERSION}-fpm..."
        systemctl start "php${PHP_VERSION}-fpm" 2>/dev/null || true
        sleep 1
        if [ ! -S "$PHP_FPM_SOCK" ]; then
            echo -e "  ${RED}[FALTA]${NC} Socket PHP-FPM: $PHP_FPM_SOCK"
            missing=$((missing + 1))
        else
            ok "Socket PHP-FPM disponible: $PHP_FPM_SOCK"
        fi
    else
        ok "Socket PHP-FPM: $PHP_FPM_SOCK"
    fi

    # MariaDB
    if ! command -v mariadb &>/dev/null && ! command -v mysql &>/dev/null; then
        echo -e "  ${RED}[FALTA]${NC} mariadb / mysql"
        missing=$((missing + 1))
    else
        local db_ver
        db_ver=$(mariadb --version 2>&1 | grep -oP 'Distrib \K[\d.]+' | head -1 \
            || mysql --version 2>&1 | grep -oP '[\d.]+' | head -1)
        ok "MariaDB: $db_ver"
    fi

    # Servicio MariaDB activo
    if ! systemctl is-active --quiet mariadb; then
        echo -e "  ${RED}[FALTA]${NC} Servicio mariadb no esta en ejecucion"
        missing=$((missing + 1))
    else
        ok "Servicio mariadb activo"
    fi

    # WP-CLI
    if ! command -v wp &>/dev/null; then
        echo -e "  ${RED}[FALTA]${NC} wp-cli"
        missing=$((missing + 1))
    else
        ok "WP-CLI: $(wp --info --allow-root 2>/dev/null | grep 'WP-CLI version' | awk '{print $NF}')"
    fi

    if [ "$missing" -gt 0 ]; then
        die "$missing prerequisito(s) faltante(s). Ejecutar primero: sudo bash check-prerequisites.sh"
    fi

    ok "Todos los prerequisitos satisfechos"
}

# ------------------------------------------------------------------------------
# PASO 3: Verificar que la ruta de instalacion no este en uso
# ------------------------------------------------------------------------------
check_install_path() {
    step "3" "Verificando ruta de instalacion: $WP_PATH"

    if [ -d "$WP_PATH" ] && [ "$(ls -A "$WP_PATH" 2>/dev/null)" ]; then
        warn "El directorio $WP_PATH ya existe y no esta vacio."
        echo ""
        read -r -p "  ¿Continuar y sobreescribir el contenido existente? [s/N]: " confirm
        if [[ ! "$confirm" =~ ^[sS]$ ]]; then
            echo ""
            info "Instalacion cancelada por el usuario."
            exit 0
        fi
        warn "Continuando con sobreescritura..."
    fi

    mkdir -p "$WP_PATH"
    ok "Directorio listo: $WP_PATH"
}

# ------------------------------------------------------------------------------
# PASO 4: Crear base de datos y usuario dedicado
# ------------------------------------------------------------------------------
setup_database() {
    step "4" "Configurando base de datos MariaDB"

    info "Conectando a MariaDB via socket (root)..."

    # Verificar conectividad
    if ! sudo mysql -e "SELECT 1;" &>/dev/null 2>&1; then
        die "No se puede conectar a MariaDB via socket. Verificar: sudo mysql -e 'SELECT 1;'"
    fi

    # Verificar si la DB ya existe
    local db_exists
    db_exists=$(sudo mysql -sN -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';" 2>/dev/null || echo "")

    if [ -n "$db_exists" ]; then
        warn "La base de datos '${DB_NAME}' ya existe."
        read -r -p "  ¿Eliminar y recrear la base de datos? Esto borrara TODOS los datos. [s/N]: " confirm
        if [[ "$confirm" =~ ^[sS]$ ]]; then
            sudo mysql -e "DROP DATABASE \`${DB_NAME}\`;"
            info "Base de datos '${DB_NAME}' eliminada."
        else
            info "Usando base de datos existente '${DB_NAME}'."
        fi
    fi

    # Crear base de datos
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    ok "Base de datos '${DB_NAME}' creada (utf8mb4)"

    # Eliminar usuario si ya existe (limpieza)
    sudo mysql -e "DROP USER IF EXISTS '${DB_USER}'@'${DB_HOST}';" 2>/dev/null || true
    sudo mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" 2>/dev/null || true

    # Crear usuario dedicado para esta instalacion
    sudo mysql -e "CREATE USER '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASSWORD}';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${DB_HOST}';"

    # Tambien permitir conexion desde localhost (por si WordPress usa 'localhost')
    if [ "$DB_HOST" != "localhost" ]; then
        sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
        sudo mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
    fi

    sudo mysql -e "FLUSH PRIVILEGES;"

    ok "Usuario '${DB_USER}'@'${DB_HOST}' creado con permisos sobre '${DB_NAME}'"

    # Verificar conectividad con el nuevo usuario
    if mariadb -u"${DB_USER}" -p"${DB_PASSWORD}" -h"${DB_HOST}" -e "USE \`${DB_NAME}\`;" &>/dev/null 2>&1; then
        ok "Conectividad del usuario '${DB_USER}' verificada"
    else
        warn "No se pudo verificar la conectividad del usuario '${DB_USER}'. Puede que sea normal si el puerto ${DB_PORT} no es el 3306 por defecto."
    fi
}

# ------------------------------------------------------------------------------
# PASO 5: Descargar WordPress via WP-CLI
# ------------------------------------------------------------------------------
download_wordpress() {
    step "5" "Descargando WordPress ($WP_VERSION)"

    local version_flag=""
    if [ "$WP_VERSION" != "latest" ]; then
        version_flag="--version=${WP_VERSION}"
    fi

    info "Descargando WordPress en $WP_PATH..."
    wp core download \
        --path="$WP_PATH" \
        --locale="$WP_LOCALE" \
        $version_flag \
        --allow-root \
        --force

    local installed_version
    installed_version=$(wp core version --path="$WP_PATH" --allow-root 2>/dev/null || echo "desconocida")
    ok "WordPress $installed_version descargado en $WP_PATH"
}

# ------------------------------------------------------------------------------
# PASO 6: Generar wp-config.php
# ------------------------------------------------------------------------------
create_wp_config() {
    step "6" "Generando wp-config.php"

    # Remover wp-config.php existente si hay
    rm -f "${WP_PATH}/wp-config.php"

    wp config create \
        --path="$WP_PATH" \
        --dbname="$DB_NAME" \
        --dbuser="$DB_USER" \
        --dbpass="$DB_PASSWORD" \
        --dbhost="${DB_HOST}:${DB_PORT}" \
        --dbcharset="utf8mb4" \
        --dbcollate="utf8mb4_unicode_ci" \
        --locale="$WP_LOCALE" \
        --allow-root

    # Agregar configuraciones adicionales de seguridad y rendimiento
    wp config set WP_DEBUG false --raw --path="$WP_PATH" --allow-root
    wp config set WP_DEBUG_LOG false --raw --path="$WP_PATH" --allow-root
    wp config set DISALLOW_FILE_EDIT true --raw --path="$WP_PATH" --allow-root
    wp config set FS_METHOD "direct" --path="$WP_PATH" --allow-root

    ok "wp-config.php generado"
    ok "Opciones de seguridad configuradas (WP_DEBUG=false, DISALLOW_FILE_EDIT=true)"
}

# ------------------------------------------------------------------------------
# PASO 7: Instalar WordPress via WP-CLI
# ------------------------------------------------------------------------------
install_wordpress_core() {
    step "7" "Instalando WordPress"

    # Determinar URL
    local wp_url="https://${SERVER_NAME}"

    # Verificar si ya esta instalado
    if wp core is-installed --path="$WP_PATH" --allow-root &>/dev/null 2>&1; then
        warn "WordPress ya esta instalado en $WP_PATH."
        read -r -p "  ¿Reinstalar WordPress? Esto restablecera la base de datos. [s/N]: " confirm
        if [[ ! "$confirm" =~ ^[sS]$ ]]; then
            info "Conservando instalacion existente."
            return
        fi
    fi

    wp core install \
        --path="$WP_PATH" \
        --url="$wp_url" \
        --title="$WP_TITLE" \
        --admin_user="$WP_ADMIN_USER" \
        --admin_password="$WP_ADMIN_PASSWORD" \
        --admin_email="$WP_ADMIN_EMAIL" \
        --skip-email \
        --allow-root

    ok "WordPress instalado"
    ok "URL del sitio: $wp_url"
    ok "Admin: $WP_ADMIN_USER / $WP_ADMIN_EMAIL"

    # Configuraciones post-instalacion
    info "Aplicando configuraciones post-instalacion..."

    # Eliminar pagina de muestra, post de muestra y comentario
    wp post delete 1 2 --force --path="$WP_PATH" --allow-root 2>/dev/null || true

    # Establecer estructura de permalinks
    wp rewrite structure '/%postname%/' --path="$WP_PATH" --allow-root 2>/dev/null || true
    wp rewrite flush --path="$WP_PATH" --allow-root 2>/dev/null || true

    ok "Configuraciones post-instalacion aplicadas"
}

# ------------------------------------------------------------------------------
# PASO 8: Configurar permisos de archivos
# ------------------------------------------------------------------------------
set_permissions() {
    step "8" "Configurando permisos de archivos"

    # Propietario: www-data
    chown -R "${WEB_USER}:${WEB_GROUP}" "$WP_PATH"

    # Directorios: 755
    find "$WP_PATH" -type d -exec chmod 755 {} \;

    # Archivos: 644
    find "$WP_PATH" -type f -exec chmod 644 {} \;

    # wp-content (subidas, plugins, themes): 775
    chmod -R 775 "${WP_PATH}/wp-content"

    # wp-config.php: solo lectura para propietario
    if [ -f "${WP_PATH}/wp-config.php" ]; then
        chmod 640 "${WP_PATH}/wp-config.php"
    fi

    ok "Permisos configurados:"
    ok "  Directorios: 755 | Archivos: 644 | wp-content: 775 | wp-config.php: 640"
    ok "  Propietario: ${WEB_USER}:${WEB_GROUP}"
}

# ------------------------------------------------------------------------------
# PASO 9: Generar SSL autofirmado
# ------------------------------------------------------------------------------
setup_ssl() {
    step "9" "Configurando SSL"

    if [ ! -d "$SSL_PATH" ]; then
        info "Creating SSL directory: $SSL_PATH"
        mkdir -p "$SSL_PATH"
    fi

    if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
        info "Generating self-signed SSL certificate..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$SSL_KEY" \
            -out "$SSL_CERT" \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=${SERVER_NAME}"
        ok "SSL certificate generated at: $SSL_PATH"
    else
        ok "SSL certificate already exists at: $SSL_PATH"
    fi
}

# ------------------------------------------------------------------------------
# PASO 10: Crear configuracion Nginx
# ------------------------------------------------------------------------------
setup_nginx() {
    step "10" "Configurando Nginx (modo: ${NGINX_MODE})"

    # Determinar rutas segun el modo
    local conf_file
    local enabled_link=""

    if [ "$NGINX_MODE" = "nginxorg" ]; then
        # nginx.org: conf.d/*.conf — include directo, sin symlinks
        conf_file="/etc/nginx/conf.d/${NGINX_SITE_NAME}.conf"
        mkdir -p "/etc/nginx/conf.d"
        # Limpiar archivos anteriores en ubicacion incorrecta (Ubuntu style)
        rm -f "/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
        rm -f "/etc/nginx/sites-available/${NGINX_SITE_NAME}"
        info "Usando conf.d (nginx.org)"
    elif [ "$NGINX_MODE" = "ubuntu" ]; then
        # Ubuntu: sites-available + symlink en sites-enabled
        conf_file="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
        mkdir -p "/etc/nginx/sites-available" "/etc/nginx/sites-enabled"
        # Limpiar archivos anteriores en ubicacion incorrecta (nginx.org style)
        rm -f "/etc/nginx/conf.d/${NGINX_SITE_NAME}.conf"
        info "Usando sites-available/sites-enabled (Ubuntu)"
    else
        die "NGINX_MODE invalido: '${NGINX_MODE}'. Valores validos: 'nginxorg' o 'ubuntu'"
    fi

    info "Creando configuracion: $conf_file"

    cat > "$conf_file" <<EOF
# WordPress — ${SERVER_NAME}
# Generado por install-wordpress.sh
# NGINX_MODE: ${NGINX_MODE}
server {
    listen 80;
    server_name ${SERVER_NAME};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${SERVER_NAME};

    # SSL
    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Raiz del sitio
    root ${WP_PATH};
    index index.php index.html;

    # Logs
    access_log /var/log/nginx/${NGINX_SITE_NAME}_access.log;
    error_log  /var/log/nginx/${NGINX_SITE_NAME}_error.log;

    # Limite de carga de archivos (sincronizar con php.ini si se cambia)
    client_max_body_size 64M;

    # WordPress permalinks
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    # PHP via unix socket (PHP-FPM)
    location ~ \.php\$ {
        # Bloquear ejecucion de PHP en uploads
        include fastcgi_params;
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    # Bloquear ejecucion de PHP en wp-content/uploads
    location ~* /wp-content/uploads/.*\.php\$ {
        deny all;
    }

    # Cache de assets estaticos
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|webp)\$ {
        expires max;
        log_not_found off;
        add_header Cache-Control "public, immutable";
    }

    # Seguridad: bloquear acceso a archivos sensibles
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~* /(wp-config\.php|xmlrpc\.php|wp-login\.php) {
        # wp-login.php permitido (acceso al admin)
        # xmlrpc.php bloqueado por defecto — descomentar si se necesita
        # deny all;
    }

    location = /xmlrpc.php {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Bloquear acceso a wp-config.php directamente
    location = /wp-config.php {
        deny all;
    }
}
EOF

    ok "Configuracion Nginx creada: $conf_file"

    # En modo nginxorg el worker corre como 'nginx' pero el socket es de 'www-data'
    # Cambiar el usuario de Nginx a www-data para compatibilidad con PHP-FPM y permisos de WordPress
    if [ "$NGINX_MODE" = "nginxorg" ]; then
        if grep -q "^user  nginx;" /etc/nginx/nginx.conf; then
            sed -i 's/^user  nginx;/user www-data;/' /etc/nginx/nginx.conf
            ok "Usuario Nginx cambiado de 'nginx' a 'www-data' (compatibilidad PHP-FPM)"
        elif grep -q "^user nginx;" /etc/nginx/nginx.conf; then
            sed -i 's/^user nginx;/user www-data;/' /etc/nginx/nginx.conf
            ok "Usuario Nginx cambiado de 'nginx' a 'www-data' (compatibilidad PHP-FPM)"
        else
            info "Usuario Nginx ya configurado: $(grep '^user' /etc/nginx/nginx.conf || echo 'no definido')"
        fi
    fi

    # En modo Ubuntu habilitar el sitio con symlink
    if [ "$NGINX_MODE" = "ubuntu" ]; then
        enabled_link="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
        ln -sf "$conf_file" "$enabled_link"
        ok "Sitio habilitado via symlink: $enabled_link"
    fi

    # Validar configuracion
    info "Validando configuracion de Nginx..."
    if nginx -t 2>/dev/null; then
        ok "Configuracion Nginx valida"
    else
        echo ""
        nginx -t
        die "Configuracion Nginx invalida. Revisar manualmente: $conf_file"
    fi
}

# ------------------------------------------------------------------------------
# PASO 11: Recargar servicios
# ------------------------------------------------------------------------------
reload_services() {
    step "11" "Recargando servicios"

    # Recargar PHP-FPM
    info "Recargando php${PHP_VERSION}-fpm..."
    systemctl reload "php${PHP_VERSION}-fpm"
    ok "php${PHP_VERSION}-fpm recargado"

    # Recargar Nginx
    info "Recargando Nginx..."
    systemctl reload nginx
    ok "Nginx recargado"
}

# ------------------------------------------------------------------------------
# PASO 12: Resumen final
# ------------------------------------------------------------------------------
print_summary() {
    local wp_version
    wp_version=$(wp core version --path="$WP_PATH" --allow-root 2>/dev/null || echo "instalado")

    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}  INSTALACION COMPLETADA${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo ""
    echo -e "  ${GREEN}WordPress $wp_version instalado correctamente.${NC}"
    echo ""
    echo -e "  ${BLUE}Acceso al sitio:${NC}"
    echo "    URL sitio:   https://${SERVER_NAME}"
    echo "    URL admin:   https://${SERVER_NAME}/wp-admin"
    echo ""
    echo -e "  ${BLUE}Credenciales WordPress:${NC}"
    echo "    Usuario:     ${WP_ADMIN_USER}"
    echo "    Password:    ${WP_ADMIN_PASSWORD}"
    echo "    Email:       ${WP_ADMIN_EMAIL}"
    echo ""
    echo -e "  ${BLUE}Base de datos:${NC}"
    echo "    DB Name:     ${DB_NAME}"
    echo "    DB User:     ${DB_USER}"
    echo "    DB Password: ${DB_PASSWORD}"
    echo "    DB Host:     ${DB_HOST}:${DB_PORT}"
    echo ""
    echo -e "  ${BLUE}Rutas del servidor:${NC}"
    echo "    WordPress:   ${WP_PATH}"
    echo "    SSL certs:   ${SSL_PATH}"
    if [ "$NGINX_MODE" = "nginxorg" ]; then
        echo "    Nginx conf:  /etc/nginx/conf.d/${NGINX_SITE_NAME}.conf"
    else
        echo "    Nginx conf:  /etc/nginx/sites-available/${NGINX_SITE_NAME}"
        echo "    Nginx link:  /etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
    fi
    echo "    Logs Nginx:  /var/log/nginx/${NGINX_SITE_NAME}_*.log"
    echo ""
    echo -e "  ${YELLOW}IMPORTANTE:${NC}"
    echo "    - Cambiar las credenciales de admin antes de produccion."
    echo "    - El certificado SSL es AUTOFIRMADO. Usar Let's Encrypt para produccion:"
    echo "      sudo apt install certbot python3-certbot-nginx"
    echo "      sudo certbot --nginx -d ${SERVER_NAME}"
    echo "    - wp-config.php esta en: ${WP_PATH}/wp-config.php (permisos 640)"
    echo ""
    echo -e "${GREEN}================================================================${NC}"
    echo ""
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    print_header

    check_root
    check_prerequisites
    check_install_path
    setup_database
    download_wordpress
    create_wp_config
    install_wordpress_core
    set_permissions
    setup_ssl
    setup_nginx
    reload_services
    print_summary
}

main "$@"
