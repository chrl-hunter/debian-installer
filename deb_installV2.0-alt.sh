#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
APT_ETC_DIR="${APT_ETC_DIR:-/etc/apt}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
APT_COMPONENTS="main contrib non-free non-free-firmware"
ARCHIVE_KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
APT_READY=0
AUTO_CONFIRM=0
SELECTION=""

export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[INFO]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
title(){ echo -e "\n${CYAN}${BOLD}── $1 ──${NC}"; }

usage() {
  cat <<USAGE
Uso:
  sudo bash ${SCRIPT_NAME}
  sudo bash ${SCRIPT_NAME} --all -y
  sudo bash ${SCRIPT_NAME} --sections "0 1 3 5" -y

Opciones:
  --all               Selecciona todas las secciones.
  --sections "LISTA"  Secciones a ejecutar, separadas por espacios o comas.
  -y, --yes           No pedir confirmación.
  -h, --help          Muestra esta ayuda.
USAGE
}

require_root() {
  [ "${EUID}" -eq 0 ] || err "Ejecuta el script como root: sudo bash ${SCRIPT_NAME}"
}

load_os_release() {
  [ -r "${OS_RELEASE_FILE}" ] || err "No se puede leer ${OS_RELEASE_FILE}"
  # shellcheck disable=SC1090
  source "${OS_RELEASE_FILE}"

  DIST_ID="${ID:-}"
  DIST_VERSION_ID="${VERSION_ID:-}"
  DIST_CODENAME="${VERSION_CODENAME:-}"
  DIST_PRETTY_NAME="${PRETTY_NAME:-Debian}"

  [ "${DIST_ID}" = "debian" ] || err "Este script solo soporta Debian. Detectado: ${DIST_PRETTY_NAME}"

  if [ -z "${DIST_CODENAME}" ]; then
    case "${DIST_VERSION_ID}" in
      13) DIST_CODENAME="trixie" ;;
      *) err "No se pudo detectar el codename de Debian desde ${OS_RELEASE_FILE}" ;;
    esac
  fi

  if [ "${DIST_CODENAME}" != "trixie" ]; then
    warn "El script está ajustado para Debian 13/Trixie. Sistema detectado: ${DIST_PRETTY_NAME}"
  fi
}

backup_file_once() {
  local file="$1"
  local backup="${file}.bak-debian-installer"
  [ -e "${backup}" ] || cp -a "${file}" "${backup}"
}

update_deb822_sources_file() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"

  awk -v comps="${APT_COMPONENTS}" '
    BEGIN { official = 0 }
    /^$/ { official = 0; print; next }
    /^URIs:[[:space:]]*/ {
      official = ($0 ~ /https?:\/\/deb\.debian\.org\/debian([[:space:]]|$)/ || $0 ~ /https?:\/\/security\.debian\.org\/debian-security([[:space:]]|$)/)
      print
      next
    }
    /^Components:[[:space:]]*/ && official {
      print "Components: " comps
      next
    }
    { print }
  ' "${file}" > "${tmp}"

  if cmp -s "${file}" "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi

  backup_file_once "${file}"
  mv "${tmp}" "${file}"
  log "Actualizado ${file} a componentes: ${APT_COMPONENTS}"
  return 0
}

update_legacy_sources_file() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"

  sed -E "s#^([[:space:]]*deb(-src)?([[:space:]]+\[[^]]+\])?[[:space:]]+https?://(deb\.debian\.org/debian|security\.debian\.org/debian-security)[[:space:]]+[^[:space:]]+[[:space:]]+).*\$#\1${APT_COMPONENTS}#" "${file}" > "${tmp}"

  if cmp -s "${file}" "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi

  backup_file_once "${file}"
  mv "${tmp}" "${file}"
  log "Actualizado ${file} a componentes: ${APT_COMPONENTS}"
  return 0
}

create_default_debian_sources() {
  local file="${APT_ETC_DIR}/sources.list.d/debian.sources"
  mkdir -p "${APT_ETC_DIR}/sources.list.d"

  cat > "${file}" <<EOF2
Types: deb
URIs: https://deb.debian.org/debian
Suites: ${DIST_CODENAME} ${DIST_CODENAME}-updates
Components: ${APT_COMPONENTS}
Signed-By: ${ARCHIVE_KEYRING}

Types: deb
URIs: https://security.debian.org/debian-security
Suites: ${DIST_CODENAME}-security
Components: ${APT_COMPONENTS}
Signed-By: ${ARCHIVE_KEYRING}
EOF2

  log "Creado ${file} con formato deb822 para ${DIST_CODENAME}"
}

prepare_apt_sources() {
  local found_official=0
  local changed=0
  local src

  mkdir -p "${APT_ETC_DIR}/sources.list.d"

  shopt -s nullglob

  for src in "${APT_ETC_DIR}/sources.list.d"/*.sources; do
    if grep -Eq '^URIs:[[:space:]].*(deb\.debian\.org/debian|security\.debian\.org/debian-security)' "${src}"; then
      found_official=1
      if update_deb822_sources_file "${src}"; then
        changed=1
      fi
    fi
  done

  if [ -f "${APT_ETC_DIR}/sources.list" ] && grep -Eq '^[[:space:]]*deb(-src)?([[:space:]]+\[[^]]+\])?[[:space:]]+https?://(deb\.debian\.org/debian|security\.debian\.org/debian-security)[[:space:]]+' "${APT_ETC_DIR}/sources.list"; then
    found_official=1
    if update_legacy_sources_file "${APT_ETC_DIR}/sources.list"; then
      changed=1
    fi
  fi

  for src in "${APT_ETC_DIR}/sources.list.d"/*.list; do
    if grep -Eq '^[[:space:]]*deb(-src)?([[:space:]]+\[[^]]+\])?[[:space:]]+https?://(deb\.debian\.org/debian|security\.debian\.org/debian-security)[[:space:]]+' "${src}"; then
      found_official=1
      if update_legacy_sources_file "${src}"; then
        changed=1
      fi
    fi
  done

  shopt -u nullglob

  if [ "${found_official}" -eq 0 ]; then
    warn "No se encontró ninguna fuente oficial de Debian en ${APT_ETC_DIR}. Se creará una nueva configuración deb822."
    create_default_debian_sources
    changed=1
  fi

  if [ "${changed}" -eq 0 ]; then
    log "Los repositorios APT ya estaban preparados con: ${APT_COMPONENTS}"
  fi
}

ensure_apt_ready() {
  if [ "${APT_READY}" -eq 1 ]; then
    return 0
  fi

  title "Preparando APT"
  prepare_apt_sources

  warn "Actualizando índice de paquetes..."
  apt-get update
  APT_READY=1
  log "APT listo."
}

install_packages() {
  local requested=("$@")
  local available=()
  local missing=()
  local pkg

  ensure_apt_ready

  for pkg in "${requested[@]}"; do
    if apt-cache show "${pkg}" >/dev/null 2>&1; then
      available+=("${pkg}")
    else
      missing+=("${pkg}")
    fi
  done

  if [ "${#available[@]}" -gt 0 ]; then
    warn "Instalando paquetes: ${available[*]}"
    apt-get install -y "${available[@]}"
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    warn "Paquetes no disponibles en los repositorios activos: ${missing[*]}"
  fi
}

validate_selection() {
  local input="$1"
  local normalized="${input//,/ }"
  local item
  local output=()
  local seen=" "

  if [ "${normalized}" = "all" ]; then
    normalized="0 1 2 3 4 5"
  fi

  for item in ${normalized}; do
    [[ "${item}" =~ ^[0-5]$ ]] || err "Opción inválida: '${item}'. Usa números del 0 al 5, separados por espacios o comas, o 'all'."
    case "${seen}" in
      *" ${item} "*) ;;
      *)
        output+=("${item}")
        seen+="${item} "
        ;;
    esac
  done

  [ "${#output[@]}" -gt 0 ] || err "No has seleccionado ninguna sección."
  SELECTION="${output[*]}"
}

interactive_menu() {
  local sections=(
    "0|Preparar APT (deb822/.sources + apt update)"
    "1|Utilidades (7zip, git, curl, htop, simple-scan...)"
    "2|Aplicaciones (Chromium, LibreOffice, VLC, GIMP...)"
    "3|Visual (Evince, Okular, Flameshot, Kate, PDF Arranger...)"
    "4|Fuentes (Liberation, DejaVu, Noto, Nerd Fonts)"
    "5|Flatpak + Pinta"
  )
  local item

  echo -e "\n${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║   Instalador de apps - Debian 13        ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo -e "\nSelecciona las secciones a instalar (separadas por espacios o comas)."
  echo -e "Escribe ${CYAN}all${NC} para instalarlas todas.\n"

  for item in "${sections[@]}"; do
    echo -e "  ${CYAN}[${item%%|*}]${NC} ${item#*|}"
  done

  echo ""
  read -r -p "Tu selección: " SELECTION
  validate_selection "${SELECTION}"
}

confirm_selection_if_needed() {
  local confirm

  if [ "${AUTO_CONFIRM}" -eq 1 ]; then
    warn "Modo no interactivo activado. Se ejecutarán las secciones: ${SELECTION}"
    return 0
  fi

  warn "Se ejecutarán las secciones: ${SELECTION}"
  read -r -p "¿Continuar? [s/N]: " confirm
  [[ "${confirm}" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all)
        SELECTION="0 1 2 3 4 5"
        ;;
      --sections)
        shift
        [ "$#" -gt 0 ] || err "Falta el valor de --sections"
        SELECTION="$1"
        ;;
      -y|--yes)
        AUTO_CONFIRM=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Opción desconocida: $1"
        ;;
    esac
    shift
  done

  if [ -n "${SELECTION}" ]; then
    validate_selection "${SELECTION}"
  fi
}

section_0() {
  title "Sección 0: Preparación de APT"
  ensure_apt_ready
}

section_1() {
  title "Sección 1: Utilidades"
  install_packages \
    7zip \
    unrar \
    zip \
    unzip \
    curl \
    wget \
    git \
    ca-certificates \
    gstreamer1.0-libav \
    deja-dup \
    htop \
    fastfetch \
    system-config-printer \
    simple-scan
  log "Utilidades instaladas."
}

section_2() {
  title "Sección 2: Aplicaciones"
  install_packages \
    chromium \
    libreoffice \
    vlc \
    gimp \
    transmission
  log "Aplicaciones instaladas."
}

section_3() {
  title "Sección 3: Herramientas visuales"
  install_packages \
    evince \
    okular \
    pdfarranger \
    flameshot \
    kate
  log "Herramientas visuales instaladas."
}

get_latest_nerd_fonts_tag() {
  curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/ryanoasis/nerd-fonts/releases/latest | awk -F/ '{print $NF}'
}

install_nerd_font() {
  local version="$1"
  local font="$2"
  local fonts_dir="/usr/local/share/fonts/nerd-fonts/${font}"
  local tmp_zip="/tmp/${font}.zip"

  mkdir -p "${fonts_dir}"
  warn "Descargando ${font} (${version})..."

  if ! curl -fsSL -o "${tmp_zip}" "https://github.com/ryanoasis/nerd-fonts/releases/download/${version}/${font}.zip"; then
    warn "No se pudo descargar ${font}. Se omite."
    rm -f "${tmp_zip}"
    return 0
  fi

  if ! unzip -o "${tmp_zip}" '*.ttf' '*.otf' -d "${fonts_dir}" >/dev/null; then
    warn "No se pudieron extraer fuentes de ${font}. Se omite."
    rm -f "${tmp_zip}"
    return 0
  fi

  rm -f "${tmp_zip}"
  log "${font} instalada."
}

section_4() {
  local nerd_fonts_version

  title "Sección 4: Fuentes"
  install_packages \
    fonts-liberation \
    fonts-dejavu \
    fonts-noto \
    fontconfig \
    curl \
    unzip \
    ca-certificates
  log "Fuentes base instaladas."

  warn "Instalando Nerd Fonts..."
  if ! nerd_fonts_version="$(get_latest_nerd_fonts_tag)" || [ -z "${nerd_fonts_version}" ] || [ "${nerd_fonts_version}" = "latest" ]; then
    warn "No se pudo resolver la última versión de Nerd Fonts. Se omite la instalación externa."
    return 0
  fi

  install_nerd_font "${nerd_fonts_version}" "FiraCode"
  install_nerd_font "${nerd_fonts_version}" "JetBrainsMono"
  install_nerd_font "${nerd_fonts_version}" "Hack"
  install_nerd_font "${nerd_fonts_version}" "SourceCodePro"

  fc-cache -f >/dev/null 2>&1 || warn "No se pudo refrescar la caché de fuentes automáticamente."
  log "Fuentes Nerd instaladas y caché actualizada."
}

section_5() {
  title "Sección 5: Flatpak + Pinta"
  install_packages flatpak ca-certificates
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  flatpak install --system -y flathub com.github.PintaProject.Pinta
  log "Flatpak y Pinta instalados."
}

cleanup() {
  title "Limpieza"
  warn "Eliminando dependencias innecesarias y limpiando caché APT..."
  apt-get autoremove -y
  apt-get clean
  log "Limpieza completada."
}

run_selected_sections() {
  local s
  for s in ${SELECTION}; do
    case "${s}" in
      0) section_0 ;;
      1) section_1 ;;
      2) section_2 ;;
      3) section_3 ;;
      4) section_4 ;;
      5) section_5 ;;
    esac
  done
}

main() {
  require_root
  load_os_release
  parse_args "$@"

  if [ -z "${SELECTION}" ]; then
    if [ -t 0 ]; then
      interactive_menu
    else
      err "Sin terminal interactiva debes usar --all o --sections."
    fi
  fi

  confirm_selection_if_needed
  run_selected_sections
  cleanup

  echo ""
  echo -e "${GREEN}${BOLD}✔ Instalación completada con éxito.${NC}"
  echo -e "${YELLOW}⚠ Reinicia la sesión (o el sistema) para aplicar todos los cambios.${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
