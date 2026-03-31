#!/bin/bash
# ============================================================
#  sing-box — Общие функции для скриптов управления
# ============================================================

SINGBOX_CONFIG="/etc/sing-box/config.json"
SINGBOX_BACKUP_DIR="/root/singbox-backup"
SINGBOX_BIN="/usr/local/bin/sing-box"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR ]${NC}  $*"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        err "Запустите скрипт от root:  sudo $0"
        exit 1
    fi
}

check_singbox() {
    if [ ! -x "$SINGBOX_BIN" ]; then
        err "sing-box не установлен. Сначала запустите 02-singbox-install.sh"
        exit 1
    fi
    if [ ! -f "$SINGBOX_CONFIG" ]; then
        err "Конфиг $SINGBOX_CONFIG не найден"
        exit 1
    fi
}

check_jq() {
    if ! command -v jq &>/dev/null; then
        err "jq не установлен. Запустите: sudo apt install jq"
        exit 1
    fi
}

backup_config() {
    mkdir -p "$SINGBOX_BACKUP_DIR"
    cp "$SINGBOX_CONFIG" "$SINGBOX_BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"
}

validate_config() {
    local output
    if output=$("$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" 2>&1); then
        ok "Конфиг валиден"
        return 0
    else
        err "Конфиг невалиден!"
        echo "$output"
        return 1
    fi
}

apply_config() {
    if validate_config; then
        systemctl restart sing-box
        sleep 2
        if systemctl is-active --quiet sing-box; then
            ok "sing-box перезапущен"
            return 0
        else
            err "sing-box не запустился!"
            journalctl -u sing-box --no-pager -n 10
            return 1
        fi
    else
        return 1
    fi
}

offer_apply() {
    echo ""
    read -p "Применить изменения сейчас? [Y/n]: " APPLY
    APPLY=${APPLY:-Y}
    if [[ "$APPLY" =~ ^[Yy]$ ]]; then
        apply_config
    else
        info "Для применения запустите: sudo ./singbox.sh apply"
    fi
}

# Безопасная запись конфига: записываем во временный файл, затем перемещаем
write_config() {
    local new_json="$1"
    local tmp_file="${SINGBOX_CONFIG}.tmp"
    echo "$new_json" > "$tmp_file"
    mv "$tmp_file" "$SINGBOX_CONFIG"
}
