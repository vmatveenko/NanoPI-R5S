#!/bin/bash
# ============================================================
#  NanoPi R5S — Управление роутером
# ============================================================
#  Интерактивный скрипт для просмотра состояния и настройки
#  сетевых параметров роутера NanoPi R5S.
#
#  WAN:  eth0         — подключение к провайдеру
#  LAN:  eth1 + eth2  — мост br0, локальная сеть
# ============================================================

set -euo pipefail

# ── Интерфейсы ───────────────────────────────────────────────
WAN_IFACE="eth0"
LAN_IFACES=("eth1" "eth2")
BRIDGE_IFACE="br0"
NETPLAN_CONFIG="/etc/netplan/01-router.yaml"

# ── Цвета ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "  ${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "  ${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "  ${RED}[ERR ]${NC}  $*"; }

# ── UI helpers (стиль singbox.sh) ────────────────────────────
UI_MIN_WIDTH=64
UI_MAX_WIDTH=100
UI_PAD=2

term_width() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    [ "$cols" -lt "$UI_MIN_WIDTH" ] && cols=$UI_MIN_WIDTH
    [ "$cols" -gt "$UI_MAX_WIDTH" ] && cols=$UI_MAX_WIDTH
    echo "$cols"
}

repeat_char() {
    local ch="$1" count="$2"
    [ "$count" -le 0 ] && return 0
    printf '%*s' "$count" '' | tr ' ' "$ch"
}

rule_line() {
    local ch="${1:--}"
    local cols line_w
    cols=$(term_width)
    line_w=$((cols - UI_PAD * 2))
    repeat_char "$ch" "$line_w"
}

print_kv() {
    local key="$1" value="$2" key_w="${3:-18}"
    printf '  %-*s %b\n' "$key_w" "$key" "$value"
}

print_note() {
    printf '  %b\n' "$1"
}

draw_header() {
    local title="$1" color="${2:-$CYAN}"
    echo
    print_note "${color}${BOLD}▌ ${title}${NC}"
    print_note "${color}$(rule_line '=')${NC}"
}

draw_section() {
    echo
    print_note "${BOLD}$1${NC}"
    print_note "${DIM}$(rule_line '-')${NC}"
}

separator() {
    print_note "${DIM}$(rule_line '.')${NC}"
}

# ── Проверки ─────────────────────────────────────────────────
check_root() {
    if [ "$EUID" -ne 0 ]; then
        err "Запустите скрипт от root:  sudo $0"
        exit 1
    fi
}

# ── Сетевые helpers ──────────────────────────────────────────
get_link_state() {
    local iface="$1"
    [ ! -d "/sys/class/net/$iface" ] && { echo "MISSING"; return; }
    cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown"
}

get_carrier() {
    local iface="$1"
    [ ! -d "/sys/class/net/$iface" ] && { echo "0"; return; }
    cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "0"
}

get_speed() {
    local iface="$1"
    [ ! -d "/sys/class/net/$iface" ] && { echo "-"; return; }
    local speed
    speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || echo "-1")
    [ "$speed" = "-1" ] && { echo "-"; return; }
    echo "${speed} Mbps"
}

get_mac() {
    local iface="$1"
    [ ! -d "/sys/class/net/$iface" ] && { echo "-"; return; }
    cat "/sys/class/net/$iface/address" 2>/dev/null || echo "-"
}

get_hw_mac() {
    local iface="$1"
    local mac
    mac=$(ethtool -P "$iface" 2>/dev/null | awk '{print $NF}')
    if [ -z "$mac" ] || [ "$mac" = "00:00:00:00:00:00" ]; then
        echo "-"
    else
        echo "$mac"
    fi
}

get_ip() {
    local iface="$1"
    ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2; exit}'
}

get_gateway() {
    ip route show default 2>/dev/null | awk '/default via/ {print $3; exit}'
}

get_dns() {
    if command -v resolvectl &>/dev/null; then
        local dns
        dns=$(resolvectl dns "$WAN_IFACE" 2>/dev/null | sed 's/.*: //')
        [ -n "$dns" ] && { echo "$dns"; return; }
    fi
    if [ -f /etc/resolv.conf ]; then
        grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' '
    else
        echo "-"
    fi
}

check_internet() {
    ping -c 1 -W 3 8.8.8.8 &>/dev/null && echo "yes" || echo "no"
}

check_dns_resolve() {
    ping -c 1 -W 3 google.com &>/dev/null && echo "yes" || echo "no"
}

generate_random_mac() {
    printf '%02x:%02x:%02x:%02x:%02x:%02x' \
        $(( (RANDOM % 256) & 0xFE | 0x02 )) \
        $((RANDOM % 256)) $((RANDOM % 256)) \
        $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
}

validate_mac() {
    [[ "$1" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]
}

format_state() {
    local state="$1"
    case "$state" in
        up)      echo "${GREEN}UP${NC}" ;;
        MISSING) echo "${RED}НЕ НАЙДЕН${NC}" ;;
        *)       echo "${RED}DOWN${NC}" ;;
    esac
}

format_carrier() {
    local carrier="$1"
    if [ "$carrier" = "1" ]; then
        echo "${GREEN}подключен${NC}"
    else
        echo "${DIM}не подключен${NC}"
    fi
}

# ════════════════════════════════════════════════════════════
#  СОСТОЯНИЕ СЕТИ
# ════════════════════════════════════════════════════════════
cmd_status() {
    draw_header "Состояние сети"

    # ── Интернет ──
    local inet dns_ok inet_label dns_label
    inet=$(check_internet)
    if [ "$inet" = "yes" ]; then
        inet_label="${GREEN}есть${NC}"
        dns_ok=$(check_dns_resolve)
        [ "$dns_ok" = "yes" ] && dns_label="${GREEN}работает${NC}" || dns_label="${RED}не резолвит${NC}"
    else
        inet_label="${RED}нет${NC}"
        dns_label="${RED}нет связи${NC}"
    fi

    print_kv "Интернет:" "$inet_label"
    print_kv "DNS:" "$dns_label"
    print_kv "Шлюз:" "$(get_gateway || echo '—')"
    print_kv "DNS серверы:" "$(get_dns)"

    # ── WAN ──
    draw_section "WAN — $WAN_IFACE"

    local wan_state wan_carrier wan_speed wan_mac wan_hw_mac wan_ip
    wan_state=$(get_link_state "$WAN_IFACE")
    wan_carrier=$(get_carrier "$WAN_IFACE")
    wan_speed=$(get_speed "$WAN_IFACE")
    wan_mac=$(get_mac "$WAN_IFACE")
    wan_hw_mac=$(get_hw_mac "$WAN_IFACE")
    wan_ip=$(get_ip "$WAN_IFACE")

    print_kv "Состояние:" "$(format_state "$wan_state")"
    print_kv "Кабель:" "$(format_carrier "$wan_carrier")"
    print_kv "Скорость:" "$wan_speed"
    print_kv "IP:" "${wan_ip:-—}"
    print_kv "MAC:" "$wan_mac"
    if [ "$wan_hw_mac" != "-" ] && [ "$wan_mac" != "$wan_hw_mac" ]; then
        print_kv "MAC (заводской):" "$wan_hw_mac ${YELLOW}(изменён)${NC}"
    fi

    # ── LAN ──
    draw_section "LAN — $BRIDGE_IFACE (${LAN_IFACES[*]})"

    local br_state br_ip br_mac
    br_state=$(get_link_state "$BRIDGE_IFACE")
    br_ip=$(get_ip "$BRIDGE_IFACE")
    br_mac=$(get_mac "$BRIDGE_IFACE")

    print_kv "Мост $BRIDGE_IFACE:" "$(format_state "$br_state")"
    print_kv "IP:" "${br_ip:-—}"
    print_kv "MAC:" "${br_mac:-—}"
    echo ""

    for liface in "${LAN_IFACES[@]}"; do
        local l_state l_carrier l_speed l_mac
        l_state=$(get_link_state "$liface")
        l_carrier=$(get_carrier "$liface")
        l_speed=$(get_speed "$liface")
        l_mac=$(get_mac "$liface")
        printf '  %-6s %b  кабель: %b  скорость: %-10s  MAC: %s\n' \
            "$liface" "$(format_state "$l_state")" "$(format_carrier "$l_carrier")" \
            "$l_speed" "$l_mac"
    done

    # ── Службы ──
    draw_section "Службы"

    local services=("nftables" "isc-dhcp-server" "systemd-networkd" "systemd-resolved")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            print_kv "$svc:" "${GREEN}active${NC}"
        else
            print_kv "$svc:" "${RED}inactive${NC}"
        fi
    done

    local fwd
    fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
    if [ "$fwd" = "1" ]; then
        print_kv "IP forwarding:" "${GREEN}включён${NC}"
    else
        print_kv "IP forwarding:" "${RED}выключен${NC}"
    fi

    echo ""
}

# ════════════════════════════════════════════════════════════
#  MAC-АДРЕС WAN
# ════════════════════════════════════════════════════════════
apply_wan_mac() {
    local new_mac="$1"
    local hw_mac is_factory=0
    hw_mac=$(get_hw_mac "$WAN_IFACE")
    [ "$new_mac" = "$hw_mac" ] && is_factory=1

    if [ ! -f "$NETPLAN_CONFIG" ]; then
        err "Конфиг netplan не найден: $NETPLAN_CONFIG"
        err "Сначала запустите scripts/01-router-setup.sh"
        return 1
    fi

    cp "$NETPLAN_CONFIG" "${NETPLAN_CONFIG}.bak-$(date +%Y%m%d-%H%M%S)"

    if [ "$is_factory" -eq 1 ]; then
        sed -i '/^      macaddress:/d' "$NETPLAN_CONFIG"
        ok "MAC сброшен на заводской в конфиге"
    else
        if grep -q '^\s*macaddress:' "$NETPLAN_CONFIG" 2>/dev/null; then
            sed -i "s/^\(\s*\)macaddress:.*/\1macaddress: $new_mac/" "$NETPLAN_CONFIG"
        else
            sed -i "/^    ${WAN_IFACE}:$/a\\      macaddress: $new_mac" "$NETPLAN_CONFIG"
        fi
        ok "MAC-адрес записан в конфиг"
    fi

    info "Применение netplan..."
    if netplan apply 2>&1; then
        ok "Netplan применён"
    else
        err "Ошибка применения netplan"
        return 1
    fi

    sleep 2
    local applied_mac
    applied_mac=$(get_mac "$WAN_IFACE")
    if [ "$applied_mac" = "$new_mac" ]; then
        ok "MAC-адрес применён: $applied_mac"
    else
        warn "MAC в системе: $applied_mac (ожидался: $new_mac)"
        info "Может потребоваться перезагрузка: sudo reboot"
    fi
}

cmd_set_wan_mac() {
    draw_header "MAC-адрес WAN ($WAN_IFACE)"

    local current_mac hw_mac netplan_mac=""
    current_mac=$(get_mac "$WAN_IFACE")
    hw_mac=$(get_hw_mac "$WAN_IFACE")

    if [ -f "$NETPLAN_CONFIG" ] && grep -q 'macaddress:' "$NETPLAN_CONFIG" 2>/dev/null; then
        netplan_mac=$(grep 'macaddress:' "$NETPLAN_CONFIG" | awk '{print $2}' | head -1)
    fi

    print_kv "Текущий MAC:" "$current_mac"
    if [ "$hw_mac" != "-" ]; then
        if [ "$current_mac" = "$hw_mac" ]; then
            print_kv "Заводской MAC:" "$hw_mac ${DIM}(совпадает)${NC}"
        else
            print_kv "Заводской MAC:" "$hw_mac ${YELLOW}(отличается)${NC}"
        fi
    fi
    [ -n "$netplan_mac" ] && print_kv "В конфиге:" "$netplan_mac"

    local can_reset=0
    if [ "$hw_mac" != "-" ] && { [ "$current_mac" != "$hw_mac" ] || [ -n "$netplan_mac" ]; }; then
        can_reset=1
    fi

    echo ""
    echo "  Выберите действие:"
    echo "    1  Случайный MAC"
    echo "    2  Скопировать с LAN-порта"
    echo "    3  Ввести вручную"
    [ "$can_reset" -eq 1 ] && echo "    4  Сбросить на заводской"
    echo "    0  Назад"
    echo ""
    read -p "  > " mac_choice

    local new_mac=""
    case "$mac_choice" in
        1)
            new_mac=$(generate_random_mac)
            echo ""
            print_kv "Сгенерирован:" "${GREEN}$new_mac${NC}"
            ;;
        2)
            echo ""
            echo "  Доступные порты:"
            local pi=1
            for liface in "${LAN_IFACES[@]}"; do
                printf '    %d) %s — %s\n' "$pi" "$liface" "$(get_mac "$liface")"
                pi=$((pi + 1))
            done
            echo ""
            read -p "  Номер порта: " port_num
            if [[ "$port_num" =~ ^[0-9]+$ ]] && [ "$port_num" -ge 1 ] && [ "$port_num" -le "${#LAN_IFACES[@]}" ]; then
                new_mac=$(get_mac "${LAN_IFACES[$((port_num-1))]}")
            else
                err "Неверный номер"; return
            fi
            ;;
        3)
            echo ""
            read -p "  MAC-адрес (XX:XX:XX:XX:XX:XX): " new_mac
            if ! validate_mac "$new_mac"; then
                err "Неверный формат MAC-адреса"; return
            fi
            new_mac=$(echo "$new_mac" | tr '[:upper:]' '[:lower:]')
            ;;
        4)
            if [ "$can_reset" -eq 0 ]; then
                warn "Неверный выбор"; return
            fi
            new_mac="$hw_mac"
            ;;
        0|"") return ;;
        *) warn "Неверный выбор"; return ;;
    esac

    [ -z "$new_mac" ] && { err "MAC не определён"; return; }

    if [ "$new_mac" = "$current_mac" ] && [ -z "$netplan_mac" ]; then
        info "MAC-адрес не изменился"
        return
    fi

    echo ""
    print_kv "Текущий:" "$current_mac"
    print_kv "Новый:" "${GREEN}$new_mac${NC}"
    echo ""
    warn "Интернет-соединение может временно прерваться!"
    echo ""
    read -p "  Применить? [Y/n]: " confirm
    confirm=${confirm:-Y}
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "  Отменено."; return; }

    apply_wan_mac "$new_mac"
    echo ""
}

# ════════════════════════════════════════════════════════════
#  СЕТЕВЫЕ ИНТЕРФЕЙСЫ (подменю)
# ════════════════════════════════════════════════════════════
cmd_interfaces() {
    while true; do
        draw_header "Сетевые интерфейсы" "$GREEN"

        local wan_mac wan_ip wan_carrier wan_status
        wan_mac=$(get_mac "$WAN_IFACE")
        wan_ip=$(get_ip "$WAN_IFACE")
        wan_carrier=$(get_carrier "$WAN_IFACE")

        [ "$wan_carrier" = "1" ] \
            && wan_status="${GREEN}●${NC} подключен" \
            || wan_status="${RED}●${NC} отключен"

        print_kv "WAN ($WAN_IFACE):" "$wan_status   IP: ${wan_ip:-—}   MAC: $wan_mac"

        echo ""
        echo -e "  ${YELLOW}${BOLD}[Настройки WAN]${NC}"
        echo "    1  MAC-адрес            клонирование / подмена"
        echo ""
        echo "    0  Назад"
        echo ""
        read -p "  > " iface_choice

        case "$iface_choice" in
            1) cmd_set_wan_mac ;;
            0|q|"") break ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#  ГЛАВНОЕ МЕНЮ
# ════════════════════════════════════════════════════════════
main_menu() {
    check_root

    while true; do
        local inet_label wan_ip_short lan_ip_short

        if ping -c 1 -W 2 8.8.8.8 &>/dev/null 2>&1; then
            inet_label="${GREEN}●${NC} online"
        else
            inet_label="${RED}●${NC} offline"
        fi

        wan_ip_short=$(get_ip "$WAN_IFACE" || true)
        lan_ip_short=$(get_ip "$BRIDGE_IFACE" || true)

        echo ""
        echo -e "  ${CYAN}${BOLD}▌ NanoPi R5S · роутер${NC}"
        echo -e "  $(rule_line '-')"
        echo -e "  ${inet_label}   |   WAN: ${wan_ip_short:-—}   |   LAN: ${lan_ip_short:-—}"
        echo -e "  $(rule_line '-')"
        echo ""
        echo -e "  ${BOLD}[Просмотр]${NC}"
        echo "    1  Состояние сети         порты, адреса, интернет"
        echo ""
        echo -e "  ${BOLD}[Настройка]${NC}"
        echo "    2  Сетевые интерфейсы     WAN, MAC-адрес"
        echo ""
        echo "    0  Выход"
        echo ""
        read -p "  > " choice

        case "$choice" in
            1) cmd_status ;;
            2) cmd_interfaces ;;
            0|q|"") echo ""; break ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

# ── Запуск ───────────────────────────────────────────────────
case "${1:-}" in
    status) check_root; cmd_status ;;
    *)      main_menu ;;
esac
