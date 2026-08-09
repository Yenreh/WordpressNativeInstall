#!/bin/bash

# ==============================================================================
# install-nginx.sh
# Instala Nginx desde el repositorio oficial de nginx.org en Ubuntu
#
# Rama stable  -> 1.30.x (recomendada para produccion)
# Rama mainline -> 1.31.x+ (ultimas features)
#
# Documentacion oficial: https://nginx.org/en/linux_packages.html
#
# Uso:
#   sudo bash install-nginx.sh
# ==============================================================================

set -euo pipefail

# ==============================================================================
# CONFIGURACION
# ==============================================================================

# Rama: "stable" para 1.30.x | "mainline" para 1.31.x+
NGINX_BRANCH="stable"

# ==============================================================================
# NO EDITAR A PARTIR DE AQUI
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}        $1"; }
info() { echo -e "  ${BLUE}[INFO]${NC}      $1"; }
done_() { echo -e "  ${GREEN}[INSTALADO]${NC} $1"; }
err()  { echo -e "  ${RED}[ERROR]${NC}     $1"; }

# ------------------------------------------------------------------------------
# Verificar root
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Este script requiere root. Ejecutar con: sudo bash $0${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# Header
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}  Nginx Installer — rama: ${NGINX_BRANCH}${NC}"
echo -e "${BLUE}${BOLD}  Repositorio oficial: nginx.org${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo ""

# ------------------------------------------------------------------------------
# Verificar si ya esta instalado
# ------------------------------------------------------------------------------
if command -v nginx &>/dev/null; then
    current_ver=$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1)
    echo -e "  Nginx $current_ver ya esta instalado."
    read -r -p "  ¿Reinstalar/actualizar desde nginx.org? [s/N]: " confirm
    echo ""
    if [[ ! "$confirm" =~ ^[ssSY]$ ]]; then
        info "Operacion cancelada."
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# Prerequisitos
# ------------------------------------------------------------------------------
info "Instalando prerequisitos..."
apt-get update -qq
apt-get install -y -qq curl gnupg2 ca-certificates lsb-release ubuntu-keyring
ok "Prerequisitos listos"

# ------------------------------------------------------------------------------
# GPG key
# ------------------------------------------------------------------------------
local_keyring="/usr/share/keyrings/nginx-archive-keyring.gpg"
expected_fingerprint="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"

info "Importando GPG key desde nginx.org..."
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
    | tee "$local_keyring" >/dev/null

# Verificar fingerprint oficial
# Segun nginx.org el keyring DEBE contener 573BFD6B...
# Puede contener otras claves adicionales — eso es normal
found_fingerprints=$(gpg --dry-run --quiet --no-keyring --import \
    --import-options import-show "$local_keyring" 2>/dev/null \
    | grep -oP '[0-9A-F]{40}' | tr -d ' ')

if echo "$found_fingerprints" | grep -q "$expected_fingerprint"; then
    ok "GPG fingerprint verificado: $expected_fingerprint"
else
    err "GPG fingerprint oficial NO encontrado en el keyring descargado."
    echo "          Esperado:    $expected_fingerprint"
    echo "          Encontrados:"
    echo "$found_fingerprints" | while read -r fp; do
        [ -n "$fp" ] && echo "            $fp"
    done
    echo ""
    echo "          Abortando por seguridad."
    rm -f "$local_keyring"
    exit 1
fi

# ------------------------------------------------------------------------------
# Repositorio
# ------------------------------------------------------------------------------
sources_file="/etc/apt/sources.list.d/nginx.list"
prefs_file="/etc/apt/preferences.d/99nginx"

if [ "$NGINX_BRANCH" = "mainline" ]; then
    echo "deb [signed-by=${local_keyring}] https://nginx.org/packages/mainline/ubuntu $(lsb_release -cs) nginx" \
        | tee "$sources_file" >/dev/null
    info "Repositorio mainline configurado (1.31.x+)"
else
    echo "deb [signed-by=${local_keyring}] https://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
        | tee "$sources_file" >/dev/null
    info "Repositorio stable configurado (1.30.x)"
fi

# Pinning: priorizar paquetes de nginx.org sobre los de Ubuntu
printf "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
    | tee "$prefs_file" >/dev/null
ok "Pinning configurado: nginx.org tiene prioridad sobre repos de Ubuntu"

# ------------------------------------------------------------------------------
# Instalar
# ------------------------------------------------------------------------------
info "Ejecutando apt-get update..."
apt-get update -qq

info "Instalando nginx..."
apt-get install -y nginx

installed_ver=$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1)
done_ "Nginx $installed_ver"

# ------------------------------------------------------------------------------
# Habilitar e iniciar servicio
# ------------------------------------------------------------------------------
systemctl enable nginx --quiet
systemctl start nginx
ok "Servicio nginx habilitado e iniciado"

# ------------------------------------------------------------------------------
# Resumen
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  INSTALACION COMPLETADA${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo ""
echo "    Version:     $(nginx -v 2>&1)"
echo "    Binario:     $(command -v nginx)"
echo "    Keyring:     $local_keyring"
echo "    Repo:        $sources_file"
echo "    Pinning:     $prefs_file"
echo "    Servicio:    $(systemctl is-active nginx)"
echo ""
echo -e "  ${BLUE}Comandos utiles:${NC}"
echo "    nginx -t                         # validar configuracion"
echo "    systemctl reload nginx           # recargar sin downtime"
echo "    systemctl status nginx           # estado del servicio"
echo "    cat /etc/apt/sources.list.d/nginx.list  # verificar repo"
echo ""
