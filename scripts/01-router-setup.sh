#!/bin/bash
# ============================================================
#  NanoPi R5S — Скрипт первичной настройки роутера
# ============================================================
#  WAN:  eth0        — получает интернет по DHCP от провайдера
#  LAN:  eth1 + eth2 — объединены в мост br0, своя подсеть
#  DHCP: isc-dhcp-server на br0
#  NAT:  nftables masquerade eth0
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

# ── Проверка root ───────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    err "Запустите скрипт от root:  sudo $0"
    exit 1
fi

# ── Баннер ──────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║   NanoPi R5S — Router Base Setup             ║${NC}"
echo -e "${CYAN}${BOLD}║   WAN: eth0  │  LAN: eth1 + eth2 → br0      ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Проверка интерфейсов ────────────────────────────────────
info "Проверка сетевых интерфейсов..."
MISSING=0
for iface in eth0 eth1 eth2; do
    if [ -d "/sys/class/net/$iface" ]; then
        ok "$iface найден"
    else
        err "$iface НЕ найден!"
        MISSING=1
    fi
done
if [ "$MISSING" -eq 1 ]; then
    err "Не все интерфейсы доступны. Проверьте оборудование."
    exit 1
fi

# ── Значения по умолчанию ───────────────────────────────────
DEFAULT_LAN_CIDR="192.168.10.1/24"
DEFAULT_RANGE_START="192.168.10.10"
DEFAULT_RANGE_END="192.168.10.200"
DEFAULT_DNS="8.8.8.8, 1.1.1.1"

# ── Ввод параметров ─────────────────────────────────────────
echo ""
echo -e "${BOLD}Настройка LAN-сети:${NC}"
read -p "  LAN IP/CIDR [$DEFAULT_LAN_CIDR]: " LAN_CIDR
LAN_CIDR=${LAN_CIDR:-$DEFAULT_LAN_CIDR}

# Парсинг CIDR
LAN_IP=$(echo "$LAN_CIDR" | cut -d/ -f1)
CIDR_PREFIX=$(echo "$LAN_CIDR" | cut -d/ -f2)

# Валидация IP
if ! echo "$LAN_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    err "Неверный формат IP: $LAN_IP"
    exit 1
fi

# Валидация CIDR
if ! [[ "$CIDR_PREFIX" =~ ^[0-9]+$ ]] || [ "$CIDR_PREFIX" -lt 8 ] || [ "$CIDR_PREFIX" -gt 30 ]; then
    err "Неверный CIDR-префикс: /$CIDR_PREFIX (допустимо: /8 — /30)"
    exit 1
fi

# ── Вычисление маски подсети из CIDR ────────────────────────
cidr_to_mask() {
    local cidr=$1
    local mask=""
    local full_octets=$((cidr / 8))
    local partial=$((cidr % 8))
    for ((i = 0; i < 4; i++)); do
        if [ $i -lt $full_octets ]; then
            mask+="255"
        elif [ $i -eq $full_octets ]; then
            if [ $partial -eq 0 ]; then
                mask+="0"
            else
                mask+="$((256 - (1 << (8 - partial))))"
            fi
        else
            mask+="0"
        fi
        [ $i -lt 3 ] && mask+="."
    done
    echo "$mask"
}

LAN_MASK=$(cidr_to_mask "$CIDR_PREFIX")

# Вычисление адреса сети
IFS='.' read -r a b c d <<< "$LAN_IP"
IFS='.' read -r ma mb mc md <<< "$LAN_MASK"
LAN_NET="$((a & ma)).$((b & mb)).$((c & mc)).$((d & md))"

# DHCP-диапазон
echo ""
echo -e "${BOLD}Настройка DHCP:${NC}"
read -p "  Начало диапазона [$DEFAULT_RANGE_START]: " RANGE_START
RANGE_START=${RANGE_START:-$DEFAULT_RANGE_START}

read -p "  Конец диапазона  [$DEFAULT_RANGE_END]: " RANGE_END
RANGE_END=${RANGE_END:-$DEFAULT_RANGE_END}

read -p "  DNS-серверы [$DEFAULT_DNS]: " DNS_SERVERS
DNS_SERVERS=${DNS_SERVERS:-$DEFAULT_DNS}

# ── Подтверждение ───────────────────────────────────────────
echo ""
echo -e "${BOLD}═══ Итоговая конфигурация ═══${NC}"
echo "  WAN:           eth0 (DHCP от провайдера)"
echo "  LAN bridge:    br0 (eth1 + eth2)"
echo "  LAN IP:        $LAN_CIDR"
echo "  Сеть LAN:      $LAN_NET/$CIDR_PREFIX"
echo "  Маска:         $LAN_MASK"
echo "  DHCP диапазон: $RANGE_START — $RANGE_END"
echo "  DNS:           $DNS_SERVERS"
echo ""
read -p "Продолжить установку? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено."
    exit 0
fi
echo ""

# ── Бэкап существующих конфигов ─────────────────────────────
BACKUP_DIR="/root/router-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
info "Резервная копия конфигов → $BACKUP_DIR"
cp -r /etc/netplan/        "$BACKUP_DIR/netplan"        2>/dev/null || true
cp /etc/nftables.conf      "$BACKUP_DIR/"               2>/dev/null || true
cp /etc/sysctl.d/99-router.conf "$BACKUP_DIR/"          2>/dev/null || true
[ -f /etc/default/isc-dhcp-server ] && cp /etc/default/isc-dhcp-server "$BACKUP_DIR/"
[ -f /etc/dhcp/dhcpd.conf ]        && cp /etc/dhcp/dhcpd.conf        "$BACKUP_DIR/"
ok "Бэкап создан"

# ── Установка пакетов ───────────────────────────────────────
info "Обновление списка пакетов и установка..."
apt-get update -qq
apt-get install -y nftables isc-dhcp-server
ok "Пакеты установлены: nftables, isc-dhcp-server"

# ── Переключение на systemd-networkd ─────────────────────────
# Образ FriendlyELEC использует NetworkManager, а netplan с renderer: networkd
# требует systemd-networkd. Переключаемся.
info "Настройка сетевого стека..."

if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    info "Отключаем NetworkManager (не нужен для роутера)..."
    systemctl stop NetworkManager
    systemctl disable NetworkManager
    ok "NetworkManager отключён"
fi

if ! systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    info "Включаем systemd-networkd..."
    systemctl enable systemd-networkd
    systemctl start systemd-networkd
    ok "systemd-networkd запущен"
else
    ok "systemd-networkd уже активен"
fi

# Включаем systemd-resolved для DNS на WAN
if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl enable systemd-resolved
    systemctl start systemd-resolved
    # Создаём symlink для /etc/resolv.conf если его нет или он битый
    if [ ! -e /etc/resolv.conf ]; then
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
    ok "systemd-resolved запущен"
fi

# ── Netplan: мост br0 (eth1+eth2), WAN на eth0 ─────────────
info "Настройка netplan..."
rm -f /etc/netplan/*.yaml

cat > /etc/netplan/01-router.yaml <<EOF
network:
  version: 2
  renderer: networkd

  ethernets:
    eth0:
      dhcp4: true
      dhcp4-overrides:
        use-dns: true
        use-routes: true
    eth1:
      dhcp4: false
    eth2:
      dhcp4: false

  bridges:
    br0:
      interfaces:
        - eth1
        - eth2
      addresses:
        - ${LAN_CIDR}
      parameters:
        stp: false
        forward-delay: 0
EOF

chmod 600 /etc/netplan/01-router.yaml
netplan apply
ok "Netplan применён"

# Ожидание поднятия br0
info "Ожидание br0..."
for i in $(seq 1 20); do
    if ip link show br0 up 2>/dev/null | grep -q "state UP\|state UNKNOWN"; then
        ok "br0 поднят"
        break
    fi
    sleep 1
done

if ! ip link show br0 &>/dev/null; then
    err "br0 не поднялся за 20 секунд"
    exit 1
fi

# ── IP Forwarding ───────────────────────────────────────────
info "Включение IP forwarding..."
cat > /etc/sysctl.d/99-router.conf <<EOF
# IP forwarding для роутера
net.ipv4.ip_forward = 1
EOF
sysctl -w net.ipv4.ip_forward=1 >/dev/null
ok "IP forwarding включён"

# ── nftables: файрвол + NAT ─────────────────────────────────
info "Настройка nftables (файрвол + NAT)..."

cat > /etc/nftables.conf <<'NFTEOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {

    chain input {
        type filter hook input priority 0; policy drop;

        # Loopback — всегда разрешён
        iifname "lo" accept

        # Установленные/связанные соединения
        ct state established,related accept

        # ICMP (ping и т.д.) — разрешён отовсюду
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # LAN (br0) — полный доступ к роутеру
        iifname "br0" accept

        # WAN (eth0) — SSH (убрать если не нужен доступ извне)
        # iifname "eth0" tcp dport 22 ct state new accept

        # Всё остальное на WAN — drop (policy)
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        # Установленные/связанные соединения
        ct state established,related accept

        # LAN → WAN (выход в интернет)
        iifname "br0" oifname "eth0" accept

        # Трафик внутри LAN через мост
        iifname "br0" oifname "br0" accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {

    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
        # Здесь можно добавить DNAT / проброс портов:
        # iifname "eth0" tcp dport 8080 dnat to 192.168.10.100:80
    }

    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        # Маскарад: LAN → WAN
        oifname "eth0" masquerade
    }
}
NFTEOF

systemctl enable nftables
systemctl restart nftables
ok "nftables настроен (NAT + firewall)"

# ── DHCP-сервер ─────────────────────────────────────────────
info "Настройка DHCP-сервера..."

# Интерфейс для DHCP
sed -i 's/^INTERFACESv4=.*/INTERFACESv4="br0"/' /etc/default/isc-dhcp-server

cat > /etc/dhcp/dhcpd.conf <<EOF
# DHCP-сервер NanoPi R5S Router
# Автоматически создано скриптом 01-router-setup.sh

default-lease-time 3600;       # 1 час
max-lease-time 86400;          # 24 часа
authoritative;

subnet ${LAN_NET} netmask ${LAN_MASK} {
    range ${RANGE_START} ${RANGE_END};
    option routers ${LAN_IP};
    option domain-name-servers ${DNS_SERVERS};
    option domain-name "lan";
    option broadcast-address $(IFS='.' read -r a b c d <<< "${LAN_NET}"; IFS='.' read -r ma mb mc md <<< "${LAN_MASK}"; echo "$((a | (255 - ma))).$((b | (255 - mb))).$((c | (255 - mc))).$((d | (255 - md)))");
}

# Статические привязки (пример):
# host my-server {
#     hardware ethernet AA:BB:CC:DD:EE:FF;
#     fixed-address 192.168.10.5;
# }
EOF

systemctl enable isc-dhcp-server
systemctl restart isc-dhcp-server
ok "DHCP-сервер запущен на br0"

# ── Проверки ────────────────────────────────────────────────
echo ""
info "Проверка сервисов..."

check_service() {
    local svc=$1
    if systemctl is-active --quiet "$svc"; then
        ok "$svc — активен"
    else
        warn "$svc — НЕ активен!"
    fi
}

check_service nftables
check_service isc-dhcp-server

# Проверка NAT
if nft list ruleset | grep -q "masquerade"; then
    ok "NAT masquerade — настроен"
else
    warn "NAT masquerade — не найден в правилах!"
fi

# Проверка forwarding
FWD=$(cat /proc/sys/net/ipv4/ip_forward)
if [ "$FWD" = "1" ]; then
    ok "IP forwarding — включён"
else
    warn "IP forwarding — выключен!"
fi

# ── Итог ────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║       Настройка роутера завершена!           ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "  WAN:           eth0 (DHCP от провайдера)"
echo "  LAN:           br0 (eth1 + eth2)"
echo "  LAN IP:        $LAN_CIDR"
echo "  DHCP:          $RANGE_START — $RANGE_END"
echo "  DNS:           $DNS_SERVERS"
echo "  Firewall:      nftables (NAT + filter)"
echo "  Бэкап:         $BACKUP_DIR"
echo ""
echo -e "${YELLOW}  Для проброса портов отредактируйте:${NC}"
echo "    /etc/nftables.conf → chain prerouting"
echo ""
echo -e "${YELLOW}  Для SSH-доступа с WAN раскомментируйте строку в:${NC}"
echo "    /etc/nftables.conf → chain input"
echo ""
echo -e "${YELLOW}${BOLD}  Рекомендуется перезагрузка:  sudo reboot${NC}"
echo ""
