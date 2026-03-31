#!/bin/bash
# ============================================================
#  NanoPi R5S — Установка и настройка sing-box
# ============================================================
#  TUN:   прозрачный прокси для всего LAN-трафика
#  Proxy: SOCKS5 + HTTP для устройств, идущих целиком через VPN
#  DNS:   split DNS (direct / vpn)
#
#  Идемпотентный: при повторном запуске обновляет бинарник
#  и восстанавливает nftables-правила, не трогая конфиг.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/singbox-common.sh"

check_root

# ── Баннер ──────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║   NanoPi R5S — sing-box Installation         ║${NC}"
echo -e "${CYAN}${BOLD}║   TUN + Proxy + Split DNS                    ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Проверка prerequisites ──────────────────────────────────
info "Проверка зависимостей..."
if ! grep -q 'iifname "br0" oifname "eth0" accept' /etc/nftables.conf 2>/dev/null; then
    err "nftables не настроен роутером. Сначала запустите 01-router-setup.sh"
    exit 1
fi
ok "01-router-setup.sh выполнен"

NEED_DEPS=0
for pkg in curl jq; do
    command -v "$pkg" &>/dev/null || NEED_DEPS=1
done

if [ "$NEED_DEPS" -eq 1 ]; then
    info "Установка зависимостей (curl, jq)..."
    apt-get update -qq
    apt-get install -y curl jq
    ok "Зависимости установлены"
else
    ok "Зависимости в наличии (curl, jq)"
fi

# ── Определение подсети LAN ───────────────────────────────
LAN_NET=$(ip -4 route show dev br0 2>/dev/null | awk '/proto kernel/ || /scope link/ {print $1; exit}')
if [ -z "$LAN_NET" ]; then
    LAN_NET="192.168.10.0/24"
    warn "Не удалось определить подсеть LAN, используем $LAN_NET"
fi
info "Подсеть LAN: $LAN_NET"

# ── Проверка текущей установки ──────────────────────────────
SINGBOX_INSTALLED=0
CURRENT_VERSION=""
if [ -x "$SINGBOX_BIN" ]; then
    SINGBOX_INSTALLED=1
    CURRENT_VERSION=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | awk '{print $NF}' || echo "unknown")
    info "Установленная версия: $CURRENT_VERSION"
fi

# ── Получение последней версии ──────────────────────────────
info "Проверка последней версии sing-box..."
LATEST_TAG=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')
if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "null" ]; then
    err "Не удалось получить информацию о последней версии sing-box"
    err "Проверьте подключение к интернету"
    exit 1
fi
LATEST_VERSION="${LATEST_TAG#v}"
info "Последняя версия:     $LATEST_VERSION"

# ── Определение архитектуры ─────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
    aarch64) DL_ARCH="arm64" ;;
    x86_64)  DL_ARCH="amd64" ;;
    armv7l)  DL_ARCH="armv7" ;;
    *)       err "Неподдерживаемая архитектура: $ARCH"; exit 1 ;;
esac

# ── Ввод параметров (только при первой установке) ───────────
CONFIG_EXISTS=0
if [ -f "$SINGBOX_CONFIG" ]; then
    CONFIG_EXISTS=1
    warn "Конфиг $SINGBOX_CONFIG уже существует — параметры не запрашиваются"
    warn "Конфиг не будет перезаписан (VPN/правила сохранятся)"

    # Миграция: добавить route_exclude_address если отсутствует
    if ! jq -e '.inbounds[] | select(.type == "tun") | .route_exclude_address' "$SINGBOX_CONFIG" >/dev/null 2>&1; then
        info "Миграция: добавление route_exclude_address ($LAN_NET) в TUN..."
        jq --arg net "$LAN_NET" '
            .inbounds |= map(
                if .type == "tun" then . + {route_exclude_address: [$net]} else . end
            )
        ' "$SINGBOX_CONFIG" > "${SINGBOX_CONFIG}.tmp" && mv "${SINGBOX_CONFIG}.tmp" "$SINGBOX_CONFIG"
        ok "route_exclude_address добавлен"
    fi

    # Миграция: заменить dns-direct type:local на udp (петля с TUN)
    if jq -e '.dns.servers[] | select(.tag == "dns-direct" and .type == "local")' "$SINGBOX_CONFIG" >/dev/null 2>&1; then
        info "Миграция: замена dns-direct local → udp://8.8.8.8..."
        jq '.dns.servers |= map(
            if .tag == "dns-direct" and .type == "local" then
                {tag: "dns-direct", type: "udp", server: "8.8.8.8"}
            else . end
        )' "$SINGBOX_CONFIG" > "${SINGBOX_CONFIG}.tmp" && mv "${SINGBOX_CONFIG}.tmp" "$SINGBOX_CONFIG"
        ok "dns-direct мигрирован"
    fi
fi

DEFAULT_PROXY_PORT="2080"
DEFAULT_TUN_ADDR="172.19.0.1/30"
DEFAULT_DNS_DIRECT="8.8.8.8"
DEFAULT_DNS_VPN="https://1.1.1.1/dns-query"

if [ "$CONFIG_EXISTS" -eq 0 ]; then
    echo ""
    echo -e "${BOLD}Параметры sing-box:${NC}"

    read -p "  Порт SOCKS/HTTP прокси [$DEFAULT_PROXY_PORT]: " PROXY_PORT
    PROXY_PORT=${PROXY_PORT:-$DEFAULT_PROXY_PORT}

    if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || [ "$PROXY_PORT" -lt 1 ] || [ "$PROXY_PORT" -gt 65535 ]; then
        err "Неверный порт: $PROXY_PORT"
        exit 1
    fi

    read -p "  Адрес TUN-интерфейса [$DEFAULT_TUN_ADDR]: " TUN_ADDR
    TUN_ADDR=${TUN_ADDR:-$DEFAULT_TUN_ADDR}

    read -p "  DNS для прямого трафика [$DEFAULT_DNS_DIRECT]: " DNS_DIRECT
    DNS_DIRECT=${DNS_DIRECT:-$DEFAULT_DNS_DIRECT}

    if [ "$DNS_DIRECT" = "local" ]; then
        warn "Тип 'local' несовместим с TUN auto_route (петля DNS)!"
        warn "Рекомендуется IP-адрес DNS (например 8.8.8.8 или 77.88.8.8)"
        read -p "  Продолжить с '$DNS_DIRECT'? [y/N]: " FORCE_LOCAL
        if [ "${FORCE_LOCAL,,}" != "y" ]; then
            read -p "  DNS для прямого трафика [8.8.8.8]: " DNS_DIRECT
            DNS_DIRECT=${DNS_DIRECT:-8.8.8.8}
        fi
    fi

    read -p "  DNS для VPN-трафика (DoH) [$DEFAULT_DNS_VPN]: " DNS_VPN
    DNS_VPN=${DNS_VPN:-$DEFAULT_DNS_VPN}
fi

# ── Подтверждение ───────────────────────────────────────────
echo ""
echo -e "${BOLD}═══ Итог ═══${NC}"
if [ "$SINGBOX_INSTALLED" -eq 1 ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    echo "  Действие:      проверка / восстановление nftables"
elif [ "$SINGBOX_INSTALLED" -eq 1 ]; then
    echo "  Действие:      обновление $CURRENT_VERSION → $LATEST_VERSION"
else
    echo "  Действие:      первая установка $LATEST_VERSION"
fi
echo "  Архитектура:   $ARCH ($DL_ARCH)"
if [ "$CONFIG_EXISTS" -eq 0 ]; then
    echo "  Proxy порт:    $PROXY_PORT"
    echo "  TUN адрес:     $TUN_ADDR"
    echo "  DNS direct:    $DNS_DIRECT"
    echo "  DNS VPN:       $DNS_VPN"
else
    echo "  Конфиг:        сохраняется текущий"
fi
echo ""

read -p "Продолжить? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено."
    exit 0
fi
echo ""

# ── Остановка sing-box перед обновлением ────────────────────
if systemctl is-active --quiet sing-box 2>/dev/null; then
    info "Останавливаем sing-box..."
    systemctl stop sing-box
    ok "sing-box остановлен"
fi

# ── Скачивание и установка бинарника ────────────────────────
if [ "$SINGBOX_INSTALLED" -eq 0 ] || [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
    info "Скачивание sing-box $LATEST_VERSION для $DL_ARCH..."
    TMP_DIR=$(mktemp -d)
    DL_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${LATEST_VERSION}-linux-${DL_ARCH}.tar.gz"

    if ! curl -sL "$DL_URL" -o "$TMP_DIR/sing-box.tar.gz"; then
        err "Ошибка скачивания: $DL_URL"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    tar -xzf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR"
    install -m 755 "$TMP_DIR/sing-box-${LATEST_VERSION}-linux-${DL_ARCH}/sing-box" "$SINGBOX_BIN"
    rm -rf "$TMP_DIR"

    NEW_VER=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | awk '{print $NF}')
    ok "sing-box $NEW_VER установлен → $SINGBOX_BIN"
else
    ok "sing-box $CURRENT_VERSION — актуальная версия"
fi

# ── Создание директорий ─────────────────────────────────────
mkdir -p /etc/sing-box
mkdir -p /var/lib/sing-box

# ── Создание systemd-сервиса ────────────────────────────────
if [ ! -f /etc/systemd/system/sing-box.service ]; then
    info "Создание systemd-сервиса..."
    cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json -D /var/lib/sing-box
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ok "systemd-сервис создан"
else
    ok "systemd-сервис уже существует"
fi

# ── Генерация базового конфига ──────────────────────────────
if [ "$CONFIG_EXISTS" -eq 0 ]; then
    info "Генерация базового конфига..."

    # Формирование DNS-серверов в новом формате sing-box 1.12+
    # dns-direct — для резолвинга обычных доменов (без VPN)
    if [ "$DNS_DIRECT" = "local" ]; then
        DNS_DIRECT_OBJ=$(jq -n '{"tag": "dns-direct", "type": "local"}')
    elif echo "$DNS_DIRECT" | grep -qE '^https://'; then
        DNS_DIRECT_HOST=$(echo "$DNS_DIRECT" | sed 's|https://||' | cut -d/ -f1)
        DNS_DIRECT_OBJ=$(jq -n --arg s "$DNS_DIRECT_HOST" \
            '{"tag": "dns-direct", "type": "https", "server": $s}')
    else
        DNS_DIRECT_OBJ=$(jq -n --arg s "$DNS_DIRECT" \
            '{"tag": "dns-direct", "type": "udp", "server": $s}')
    fi

    # dns-vpn — для резолвинга VPN-доменов (detour добавляется позже через singbox-add-group.sh)
    if echo "$DNS_VPN" | grep -qE '^https://'; then
        DNS_VPN_HOST=$(echo "$DNS_VPN" | sed 's|https://||' | cut -d/ -f1)
        DNS_VPN_OBJ=$(jq -n --arg s "$DNS_VPN_HOST" \
            '{"tag": "dns-vpn", "type": "https", "server": $s}')
    elif echo "$DNS_VPN" | grep -qE '^tls://'; then
        DNS_VPN_HOST=$(echo "$DNS_VPN" | sed 's|tls://||' | cut -d/ -f1)
        DNS_VPN_OBJ=$(jq -n --arg s "$DNS_VPN_HOST" \
            '{"tag": "dns-vpn", "type": "tls", "server": $s}')
    else
        DNS_VPN_OBJ=$(jq -n --arg s "$DNS_VPN" \
            '{"tag": "dns-vpn", "type": "udp", "server": $s}')
    fi

    # Сборка полного конфига через jq (формат sing-box 1.13+)
    jq -n \
        --argjson dns_direct "$DNS_DIRECT_OBJ" \
        --argjson dns_vpn "$DNS_VPN_OBJ" \
        --arg tun_addr "$TUN_ADDR" \
        --argjson proxy_port "$PROXY_PORT" \
        --arg lan_net "$LAN_NET" \
    '{
        log: { level: "info", timestamp: true },
        dns: {
            servers: [$dns_direct, $dns_vpn],
            rules: [],
            final: "dns-direct"
        },
        inbounds: [
            {
                type: "tun",
                tag: "tun-in",
                interface_name: "tun0",
                address: [$tun_addr],
                auto_route: true,
                strict_route: false,
                route_exclude_address: [$lan_net]
            },
            {
                type: "mixed",
                tag: "proxy-in",
                listen: "::",
                listen_port: $proxy_port
            }
        ],
        outbounds: [
            { type: "direct", tag: "direct" },
            { type: "block", tag: "block" }
        ],
        route: {
            rules: [
                { action: "sniff" },
                { protocol: "dns", action: "hijack-dns" }
            ],
            rule_set: [],
            final: "direct",
            auto_detect_interface: true,
            default_mark: 100,
            default_domain_resolver: "dns-direct"
        }
    }' > "$SINGBOX_CONFIG"

    ok "Базовый конфиг создан"
else
    info "Конфиг сохранён без изменений"
fi

# ── sysctl: отключение rp_filter для TUN ──────────────────
info "Настройка sysctl для TUN..."
cat > /etc/sysctl.d/99-singbox.conf <<'SYSCTL'
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYSCTL
sysctl --system >/dev/null 2>&1
ok "sysctl настроен (rp_filter отключён для TUN)"

# ── Модификация nftables ────────────────────────────────────
info "Проверка правил nftables для sing-box TUN..."

NFTABLES_CHANGED=0

if ! grep -q 'oifname "tun0"' /etc/nftables.conf 2>/dev/null; then
    info "Добавление правил tun0 в nftables..."
    sed -i 's|iifname "br0" oifname "eth0" accept|iifname "br0" oifname "eth0" accept\n\n        # sing-box TUN — прозрачный прокси\n        iifname "br0" oifname "tun0" accept\n        iifname "tun0" oifname "br0" accept|' /etc/nftables.conf
    NFTABLES_CHANGED=1
    ok "Правила tun0 добавлены в nftables"
elif ! grep -q 'iifname "tun0"' /etc/nftables.conf 2>/dev/null; then
    info "Добавление обратного правила tun0 → br0..."
    sed -i 's|iifname "br0" oifname "tun0" accept|iifname "br0" oifname "tun0" accept\n        iifname "tun0" oifname "br0" accept|' /etc/nftables.conf
    NFTABLES_CHANGED=1
    ok "Обратное правило tun0 → br0 добавлено"
else
    ok "Правила tun0 уже есть в nftables"
fi

if [ "$NFTABLES_CHANGED" -eq 1 ]; then
    systemctl restart nftables
fi

# ── Валидация конфига ───────────────────────────────────────
info "Валидация конфига..."
if ! validate_config; then
    err "Конфиг невалиден! Проверьте $SINGBOX_CONFIG"
    exit 1
fi

# ── Запуск ──────────────────────────────────────────────────
info "Запуск sing-box..."
systemctl enable sing-box
systemctl start sing-box
sleep 3

# ── Проверки ────────────────────────────────────────────────
echo ""
info "Проверка сервисов..."

if systemctl is-active --quiet sing-box; then
    ok "sing-box — активен"
else
    warn "sing-box — НЕ активен!"
    journalctl -u sing-box --no-pager -n 10
fi

if ip link show tun0 &>/dev/null; then
    ok "tun0 — поднят"
else
    warn "tun0 — не найден"
fi

if grep -q 'iifname "tun0"' /etc/nftables.conf && grep -q 'oifname "tun0"' /etc/nftables.conf; then
    ok "nftables — правила tun0 на месте (br0↔tun0)"
else
    warn "nftables — правила tun0 неполные!"
fi

RP=$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || echo "?")
if [ "$RP" = "0" ]; then
    ok "rp_filter — отключён"
else
    warn "rp_filter = $RP (должен быть 0 для TUN)"
fi

# ── Итог ────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║       sing-box установлен и запущен!         ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "  Версия:        $("$SINGBOX_BIN" version 2>/dev/null | head -1 | awk '{print $NF}')"
echo "  Конфиг:        $SINGBOX_CONFIG"
echo "  TUN:           tun0"
if [ "$CONFIG_EXISTS" -eq 0 ]; then
    echo "  Proxy:         :${PROXY_PORT} (SOCKS5 + HTTP)"
    echo "  DNS direct:    ${DNS_DIRECT}"
    echo "  DNS VPN:       ${DNS_VPN}"
fi
echo "  Маршрутизация: весь трафик → direct (без VPN)"
echo ""
echo -e "${YELLOW}  Следующие шаги:${NC}"
echo "    1. Добавить VLESS-подключение:  sudo ./scripts/singbox-add-vless.sh"
echo "    2. Создать группу (failover):   sudo ./scripts/singbox-add-group.sh"
echo "    3. Добавить правила:            sudo ./scripts/singbox-add-rule.sh"
echo "    4. Применить:                   sudo ./scripts/singbox-apply.sh"
echo ""
