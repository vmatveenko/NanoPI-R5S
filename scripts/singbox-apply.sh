#!/bin/bash
# ============================================================
#  sing-box — Валидация конфига и перезапуск сервиса
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/singbox-common.sh"

check_root
check_singbox

echo ""
echo -e "${CYAN}${BOLD}═══ sing-box: Применение конфигурации ═══${NC}"
echo ""

info "Валидация конфига: $SINGBOX_CONFIG"

if apply_config; then
    echo ""
    ok "Конфигурация успешно применена"

    sleep 1
    if ip link show tun0 &>/dev/null; then
        ok "tun0 — поднят"
    else
        warn "tun0 — не найден (возможно, требуется время)"
    fi
    echo ""
else
    echo ""
    err "Не удалось применить конфигурацию"
    err "Проверьте конфиг: $SINGBOX_CONFIG"
    err "Предыдущие бэкапы: $SINGBOX_BACKUP_DIR/"
    echo ""
    exit 1
fi
