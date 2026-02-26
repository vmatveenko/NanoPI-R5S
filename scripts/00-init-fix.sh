#!/bin/bash
# ============================================================
#  NanoPi R5S — Инициализация после установки ОС
# ============================================================
#  Скрипт решает типичные проблемы свежей установки
#  официального образа Ubuntu (FriendlyELEC) на eMMC:
#
#  1. Проверка загрузки с eMMC
#  2. Диагностика сети (WAN / интернет)
#  3. Исправление DNS (битый symlink resolv.conf)
#  4. Отключение systemd-resolved (не нужен на роутере)
#  5. Обновление системы
# ============================================================

set -euo pipefail

# ── Цвета ───────────────────────────────────────────────────
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
step()  { echo ""; echo -e "${BOLD}── $* ──${NC}"; }

# ── Проверка root ───────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    err "Запустите скрипт от root:  sudo $0"
    exit 1
fi

# ── Баннер ──────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║   NanoPi R5S — Post-Install Init & Fix      ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

ERRORS=0

# ════════════════════════════════════════════════════════════
#  1. Проверка загрузки с eMMC
# ════════════════════════════════════════════════════════════
step "1/5  Проверка загрузки с eMMC"

ROOT_DEV=$(findmnt -n -o SOURCE /)
info "Root-раздел: $ROOT_DEV"

if echo "$ROOT_DEV" | grep -q "mmcblk1\|mmcblk2"; then
    ok "Система загружена с eMMC"
elif echo "$ROOT_DEV" | grep -q "mmcblk0"; then
    warn "Система загружена с SD-карты (mmcblk0), а не с eMMC"
    warn "Если вы хотите грузиться с eMMC — извлеките SD-карту и перезагрузитесь"
else
    info "Root-устройство: $ROOT_DEV"
fi

# Версия ОС
if command -v lsb_release &>/dev/null; then
    OS_DESC=$(lsb_release -d -s 2>/dev/null || echo "N/A")
    info "ОС: $OS_DESC"
else
    info "ОС: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo 'N/A')"
fi

info "Ядро: $(uname -r)"

# ════════════════════════════════════════════════════════════
#  2. Проверка сетевых интерфейсов
# ════════════════════════════════════════════════════════════
step "2/5  Сетевые интерфейсы"

for iface in eth0 eth1 eth2; do
    if [ -d "/sys/class/net/$iface" ]; then
        STATE=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        SPEED=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || echo "?")
        MAC=$(cat "/sys/class/net/$iface/address" 2>/dev/null || echo "?")
        IP=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "нет IP")

        if [ "$STATE" = "up" ]; then
            ok "$iface — UP  ${SPEED}Mbps  MAC=$MAC  IP=$IP"
        else
            warn "$iface — $STATE  MAC=$MAC"
        fi
    else
        warn "$iface — не найден"
    fi
done

# ════════════════════════════════════════════════════════════
#  3. Диагностика WAN / интернет
# ════════════════════════════════════════════════════════════
step "3/5  Диагностика интернета"

# Определяем WAN-интерфейс (тот, через который идёт default route)
WAN_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')

if [ -z "$WAN_IFACE" ]; then
    warn "Нет default route — шлюз не назначен"
    info "Попытка получить IP по DHCP на eth0..."

    # Пробуем получить DHCP на eth0
    if command -v dhclient &>/dev/null; then
        dhclient eth0 2>/dev/null && ok "dhclient eth0 выполнен" || warn "dhclient eth0 не удался"
    elif command -v dhcpcd &>/dev/null; then
        dhcpcd eth0 2>/dev/null && ok "dhcpcd eth0 выполнен" || warn "dhcpcd eth0 не удался"
    else
        warn "DHCP-клиент не найден, попробуйте: networkctl reconfigure eth0"
        networkctl reconfigure eth0 2>/dev/null || true
    fi
    sleep 3
    WAN_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
fi

if [ -n "$WAN_IFACE" ]; then
    GW=$(ip route show default | awk '{print $3; exit}')
    ok "WAN-интерфейс: $WAN_IFACE  шлюз: $GW"
else
    err "Шлюз по умолчанию так и не появился"
    err "Проверьте подключение кабеля к WAN (eth0)"
    ERRORS=$((ERRORS + 1))
fi

# Проверка доступности интернета (по IP, без DNS)
info "Проверка связи с 8.8.8.8..."
if ping -c 2 -W 3 8.8.8.8 &>/dev/null; then
    ok "Интернет доступен (ping 8.8.8.8)"
    INET_OK=1
else
    err "Нет ответа от 8.8.8.8 — интернет недоступен"
    INET_OK=0
    ERRORS=$((ERRORS + 1))
fi

# ════════════════════════════════════════════════════════════
#  4. Исправление DNS (главная проблема FriendlyELEC образов)
# ════════════════════════════════════════════════════════════
step "4/5  Проверка и исправление DNS"

DNS_FIXED=0

# ---------- Диагностика текущего состояния ----------

# Проверяем resolv.conf
if [ -L /etc/resolv.conf ]; then
    # Это символическая ссылка
    LINK_TARGET=$(readlink /etc/resolv.conf)
    info "/etc/resolv.conf → $LINK_TARGET (symlink)"

    if [ ! -e /etc/resolv.conf ]; then
        # Ссылка битая — файл-назначение не существует
        err "Битая ссылка! Целевой файл не существует"
        DNS_BROKEN=1
    else
        # Ссылка рабочая — проверим содержимое
        if grep -q "nameserver" /etc/resolv.conf 2>/dev/null; then
            ok "/etc/resolv.conf содержит nameserver"
            DNS_BROKEN=0
        else
            warn "/etc/resolv.conf пуст или без nameserver"
            DNS_BROKEN=1
        fi
    fi
elif [ -f /etc/resolv.conf ]; then
    # Обычный файл
    info "/etc/resolv.conf — обычный файл"
    if grep -q "nameserver" /etc/resolv.conf 2>/dev/null; then
        ok "DNS настроен: $(grep 'nameserver' /etc/resolv.conf | head -2 | tr '\n' ' ')"
        DNS_BROKEN=0
    else
        warn "/etc/resolv.conf пуст или без nameserver"
        DNS_BROKEN=1
    fi
else
    # Файла вообще нет
    err "/etc/resolv.conf не существует"
    DNS_BROKEN=1
fi

# Проверяем systemd-resolved
RESOLVED_ACTIVE=0
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    RESOLVED_ACTIVE=1
    info "systemd-resolved: active"
else
    info "systemd-resolved: inactive/dead"
fi

# ---------- Проверка DNS разрешения ----------
DNS_WORKS=0
if [ "$INET_OK" = "1" ]; then
    info "Проверка DNS (ping google.com)..."
    if ping -c 2 -W 3 google.com &>/dev/null; then
        ok "DNS работает"
        DNS_WORKS=1
    else
        warn "DNS не работает (ping google.com не отвечает)"
    fi
fi

# ---------- Исправление ----------
if [ "$DNS_WORKS" = "0" ] && [ "$DNS_BROKEN" = "1" ]; then
    info "Исправляем DNS..."

    # 1) Отключаем systemd-resolved (не нужен на роутере)
    if systemctl is-enabled systemd-resolved &>/dev/null 2>&1; then
        info "Отключаем systemd-resolved..."
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        ok "systemd-resolved отключён"
    fi

    # 2) Удаляем битую ссылку / пустой файл
    rm -f /etc/resolv.conf

    # 3) Создаём нормальный resolv.conf
    cat > /etc/resolv.conf <<EOF
# DNS — создано скриптом 00-init-fix.sh
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

    ok "/etc/resolv.conf создан (8.8.8.8, 1.1.1.1)"

    # 4) Защищаем от перезаписи (на случай если resolved вернётся)
    chattr +i /etc/resolv.conf 2>/dev/null && \
        info "/etc/resolv.conf защищён от перезаписи (chattr +i)" || true

    DNS_FIXED=1

    # 5) Повторная проверка
    if [ "$INET_OK" = "1" ]; then
        info "Повторная проверка DNS..."
        sleep 1
        if ping -c 2 -W 3 google.com &>/dev/null; then
            ok "DNS работает после исправления!"
        else
            err "DNS всё ещё не работает — проверьте вручную"
            ERRORS=$((ERRORS + 1))
        fi
    fi
elif [ "$DNS_WORKS" = "1" ]; then
    ok "DNS уже работает, исправление не требуется"
else
    warn "Интернет недоступен — DNS проверить невозможно"
    if [ "$DNS_BROKEN" = "1" ]; then
        info "Превентивно исправляем /etc/resolv.conf..."

        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        rm -f /etc/resolv.conf

        cat > /etc/resolv.conf <<EOF
# DNS — создано скриптом 00-init-fix.sh
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
        chattr +i /etc/resolv.conf 2>/dev/null || true

        ok "/etc/resolv.conf создан (проверьте после появления интернета)"
        DNS_FIXED=1
    fi
fi

# ════════════════════════════════════════════════════════════
#  5. Обновление системы
# ════════════════════════════════════════════════════════════
step "5/5  Обновление системы"

# Проверяем доступность интернета (с DNS) перед обновлением
CAN_UPDATE=0
if ping -c 1 -W 3 google.com &>/dev/null; then
    CAN_UPDATE=1
elif ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
    # Интернет есть, но DNS может не работать — пробуем apt напрямую
    CAN_UPDATE=1
fi

if [ "$CAN_UPDATE" = "1" ]; then
    read -p "  Обновить систему? (apt update && apt upgrade) [Y/n]: " DO_UPDATE
    DO_UPDATE=${DO_UPDATE:-Y}

    if [[ "$DO_UPDATE" =~ ^[Yy]$ ]]; then
        info "Обновление списка пакетов..."
        apt-get update -qq

        info "Обновление пакетов..."
        apt-get upgrade -y

        ok "Система обновлена"
    else
        info "Обновление пропущено"
    fi
else
    warn "Нет интернета — обновление пропущено"
fi

# ════════════════════════════════════════════════════════════
#  Итог
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Итог диагностики и инициализации${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""

# Собираем финальный статус
echo "  Загрузка:   $(findmnt -n -o SOURCE /)"
echo "  Ядро:       $(uname -r)"

# WAN
WAN_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d./]+' || echo "нет IP")
echo "  WAN (eth0): $WAN_IP"

# DNS
if [ -f /etc/resolv.conf ] && grep -q nameserver /etc/resolv.conf 2>/dev/null; then
    DNS_LIST=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')
    echo "  DNS:        $DNS_LIST"
else
    echo "  DNS:        не настроен"
fi

# Статус интернета
if ping -c 1 -W 2 google.com &>/dev/null; then
    echo -e "  Интернет:   ${GREEN}работает${NC}"
elif ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
    echo -e "  Интернет:   ${YELLOW}есть связь, DNS не работает${NC}"
else
    echo -e "  Интернет:   ${RED}недоступен${NC}"
fi

# Что было сделано
echo ""
if [ "$DNS_FIXED" = "1" ]; then
    echo -e "  ${GREEN}✔${NC} DNS исправлен (/etc/resolv.conf создан)"
    echo -e "  ${GREEN}✔${NC} systemd-resolved отключён"
fi

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo -e "  ${RED}Обнаружено проблем: $ERRORS${NC}"
    echo -e "  ${YELLOW}Проверьте вывод выше и устраните вручную${NC}"
else
    echo ""
    echo -e "  ${GREEN}${BOLD}Всё в порядке! Устройство готово к настройке.${NC}"
    echo -e "  Следующий шаг:  ${CYAN}sudo ./scripts/01-router-setup.sh${NC}"
fi

echo ""
