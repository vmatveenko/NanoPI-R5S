#!/bin/bash
# ============================================================
#  NanoPi R5S — одноразовое удаление старого второго слоя
# ============================================================
#  Удаляет установленный этим проектом sing-box и Telegram-бот,
#  не затрагивая Netplan, DHCP, bridge br0 и базовый NAT/router.
#
#  Перед удалением создаёт закрытую резервную копию в /root.
#  Без --yes требует интерактивного подтверждения.
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<'EOF'
Использование:
  sudo ./scripts/00-remove-legacy-second-layer.sh [--yes]

Параметры:
  --yes     не запрашивать интерактивное подтверждение
  -h        показать эту справку
EOF
}

ASSUME_YES=0
case "${1:-}" in
    "") ;;
    --yes|-y) ASSUME_YES=1 ;;
    --help|-h) usage; exit 0 ;;
    *) err "Неизвестный параметр: $1"; usage; exit 2 ;;
esac

if [ "$EUID" -ne 0 ]; then
    err "Запустите скрипт от root: sudo $0"
    exit 1
fi

BACKUP_DIR="/root/nanopi-legacy-second-layer-$(date +%Y%m%d-%H%M%S)"
NFTABLES_CONFIG="/etc/nftables.conf"
FAILURES=0

echo ""
echo "Будут удалены только компоненты старого второго слоя:"
echo "  - sing-box, его systemd unit, конфигурация и данные;"
echo "  - Telegram-бот nanopi-bot, его unit, конфигурация и venv;"
echo "  - sysctl-файл 99-singbox.conf;"
echo "  - только правила br0 <-> tun0, добавленные старым установщиком."
echo ""
echo "Не будут изменены Netplan, br0, DHCP и базовые правила LAN -> eth0."
echo "Резервная копия будет создана в: $BACKUP_DIR"
echo ""

if [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "Продолжить? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Отменено."
        exit 0
    fi
fi

install -d -m 700 "$BACKUP_DIR"

backup_path() {
    local source_path="$1"
    local relative_path destination

    if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]; then
        return 0
    fi

    relative_path="${source_path#/}"
    destination="$BACKUP_DIR/$relative_path"
    mkdir -p "$(dirname "$destination")"
    cp -a -- "$source_path" "$destination"
    ok "Сохранено: $source_path"
}

info "Создание резервной копии конфигурации и данных..."
for path in \
    /etc/sing-box \
    /var/lib/sing-box \
    /root/singbox-backup \
    /usr/local/bin/sing-box \
    /etc/systemd/system/sing-box.service \
    /etc/systemd/system/sing-box.service.d \
    /opt/nanopi-bot \
    /etc/nanopi-bot \
    /etc/systemd/system/nanopi-bot.service \
    /etc/systemd/system/nanopi-bot.service.d \
    /etc/sysctl.d/99-singbox.conf \
    /etc/nftables.conf; do
    backup_path "$path"
done
chmod -R go-rwx "$BACKUP_DIR"
ok "Резервная копия готова: $BACKUP_DIR"
warn "В копии могут находиться VPN-ключи и Telegram-токен; не публикуйте её."

stop_and_disable_service() {
    local service_name="$1"

    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        info "Остановка $service_name..."
        if systemctl stop "$service_name"; then
            ok "$service_name остановлен"
        else
            err "Не удалось остановить $service_name"
            FAILURES=$((FAILURES + 1))
        fi
    else
        ok "$service_name уже не запущен"
    fi

    if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        if systemctl disable "$service_name"; then
            ok "Автозапуск $service_name отключён"
        else
            err "Не удалось отключить автозапуск $service_name"
            FAILURES=$((FAILURES + 1))
        fi
    fi
}

stop_and_disable_service sing-box
stop_and_disable_service nanopi-bot

remove_path() {
    local target="$1"
    if [ -e "$target" ] || [ -L "$target" ]; then
        rm -rf -- "$target"
        ok "Удалено: $target"
    fi
}

info "Удаление файлов старого второго слоя..."
for path in \
    /etc/sing-box \
    /var/lib/sing-box \
    /root/singbox-backup \
    /usr/local/bin/sing-box \
    /etc/systemd/system/sing-box.service \
    /etc/systemd/system/sing-box.service.d \
    /opt/nanopi-bot \
    /etc/nanopi-bot \
    /etc/systemd/system/nanopi-bot.service \
    /etc/systemd/system/nanopi-bot.service.d \
    /etc/sysctl.d/99-singbox.conf; do
    remove_path "$path"
done

systemctl daemon-reload
systemctl reset-failed sing-box nanopi-bot 2>/dev/null || :

if ip link show tun0 >/dev/null 2>&1; then
    info "Удаление оставшегося интерфейса tun0..."
    if ip link delete tun0; then
        ok "tun0 удалён"
    else
        err "Не удалось удалить tun0"
        FAILURES=$((FAILURES + 1))
    fi
else
    ok "tun0 исчез после остановки sing-box"
fi

if [ -f "$NFTABLES_CONFIG" ] && \
   grep -qE 'iifname "br0" oifname "tun0"|iifname "tun0" oifname "br0"|sing-box TUN' "$NFTABLES_CONFIG"; then
    info "Удаление правил старого tun0 из $NFTABLES_CONFIG..."
    NFT_TMP=$(mktemp)
    trap 'rm -f "$NFT_TMP"' EXIT

    awk '
        /# sing-box TUN/ { next }
        /iifname "br0" oifname "tun0" accept/ { next }
        /iifname "tun0" oifname "br0" accept/ { next }
        { print }
    ' "$NFTABLES_CONFIG" > "$NFT_TMP"

    if nft -c -f "$NFT_TMP"; then
        cat "$NFT_TMP" > "$NFTABLES_CONFIG"
        if systemctl restart nftables; then
            ok "nftables перезагружен без правил tun0"
        else
            err "Не удалось применить изменённый nftables; восстанавливаем исходный файл"
            cp -a "$BACKUP_DIR/etc/nftables.conf" "$NFTABLES_CONFIG"
            if systemctl restart nftables; then
                warn "Исходный nftables восстановлен и снова применён"
            else
                err "Не удалось применить даже исходный nftables-конфиг"
                err "Проверьте вручную: nft -c -f $NFTABLES_CONFIG"
            fi
            FAILURES=$((FAILURES + 1))
        fi
    else
        err "Полученный nftables-конфиг не прошёл проверку; исходный файл не изменён"
        FAILURES=$((FAILURES + 1))
    fi

    rm -f "$NFT_TMP"
    trap - EXIT
else
    ok "Правила старого tun0 в nftables не найдены"
fi

info "Применение оставшихся sysctl-настроек..."
if sysctl --system >/dev/null; then
    ok "sysctl применён"
else
    warn "sysctl --system завершился с ошибкой; проверьте вывод команды вручную"
    FAILURES=$((FAILURES + 1))
fi

echo ""
info "Итоговая проверка..."

for service_name in sing-box nanopi-bot; do
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        err "$service_name всё ещё активен"
        FAILURES=$((FAILURES + 1))
    else
        ok "$service_name не активен"
    fi
done

if ip link show tun0 >/dev/null 2>&1; then
    err "tun0 всё ещё существует"
    FAILURES=$((FAILURES + 1))
else
    ok "tun0 отсутствует"
fi

if [ -f "$NFTABLES_CONFIG" ] && \
   grep -qE 'iifname "br0" oifname "tun0"|iifname "tun0" oifname "br0"|sing-box TUN' "$NFTABLES_CONFIG"; then
    err "В $NFTABLES_CONFIG остались правила старого tun0"
    FAILURES=$((FAILURES + 1))
else
    ok "Правила старого tun0 отсутствуют"
fi

if [ "$FAILURES" -gt 0 ]; then
    echo ""
    err "Удаление завершено с ошибками: $FAILURES"
    err "Резервная копия: $BACKUP_DIR"
    exit 1
fi

echo ""
ok "Старый второй слой полностью удалён"
ok "Базовый роутер (br0, DHCP, nftables, NAT) сохранён"
echo "Резервная копия: $BACKUP_DIR"
echo ""
