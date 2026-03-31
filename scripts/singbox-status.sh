#!/bin/bash
# ============================================================
#  sing-box — Показ текущей конфигурации и статуса
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/singbox-common.sh"

check_root
check_singbox
check_jq

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║           sing-box Status                    ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Сервис ──────────────────────────────────────────────────
VERSION=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | awk '{print $NF}' || echo "?")

if systemctl is-active --quiet sing-box 2>/dev/null; then
    echo -e "  Сервис:      ${GREEN}active (running)${NC}"
else
    echo -e "  Сервис:      ${RED}inactive${NC}"
fi
echo "  Версия:      $VERSION"

# ── Inbound'ы ───────────────────────────────────────────────
TUN_ADDR=$(jq -r '.inbounds[] | select(.type == "tun") | .address[0] // .inet4_address // "?"' "$SINGBOX_CONFIG" 2>/dev/null)
TUN_IFACE=$(jq -r '.inbounds[] | select(.type == "tun") | .interface_name // "tun0"' "$SINGBOX_CONFIG" 2>/dev/null)
PROXY_PORT=$(jq -r '.inbounds[] | select(.type == "mixed") | .listen_port // "?"' "$SINGBOX_CONFIG" 2>/dev/null)

echo "  TUN:         $TUN_IFACE ($TUN_ADDR)"
echo "  Proxy:       :${PROXY_PORT} (SOCKS5 + HTTP)"

if ip link show "$TUN_IFACE" &>/dev/null; then
    echo -e "  TUN статус:  ${GREEN}UP${NC}"
else
    echo -e "  TUN статус:  ${RED}DOWN${NC}"
fi

# ── Outbound'ы ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══ Outbound'ы ═══${NC}"

i=1
jq -r '.outbounds[] | "\(.type)\t\(.tag)\t\(.server // "")\t\(.server_port // "")\t\(.outbounds // [] | join(", "))"' "$SINGBOX_CONFIG" 2>/dev/null | \
while IFS=$'\t' read -r type tag server port members; do
    case "$type" in
        vless)
            printf "  %2d. [${CYAN}%-10s${NC}] %-20s → %s:%s\n" "$i" "$type" "$tag" "$server" "$port"
            ;;
        urltest|selector)
            printf "  %2d. [${YELLOW}%-10s${NC}] %-20s → %s\n" "$i" "$type" "$tag" "$members"
            ;;
        direct)
            printf "  %2d. [${GREEN}%-10s${NC}] %s\n" "$i" "$type" "$tag"
            ;;
        block)
            printf "  %2d. [${RED}%-10s${NC}] %s\n" "$i" "$type" "$tag"
            ;;
        dns)
            printf "  %2d. [%-10s] %s\n" "$i" "$type" "$tag"
            ;;
        *)
            printf "  %2d. [%-10s] %s\n" "$i" "$type" "$tag"
            ;;
    esac
    ((i++))
done

# ── Правила маршрутизации ───────────────────────────────────
echo ""
echo -e "${BOLD}═══ Правила маршрутизации ═══${NC}"

RULES_COUNT=$(jq '.route.rules | length' "$SINGBOX_CONFIG")
i=1
for ((idx=0; idx<RULES_COUNT; idx++)); do
    RULE=$(jq -c ".route.rules[$idx]" "$SINGBOX_CONFIG")
    OUTBOUND=$(echo "$RULE" | jq -r '.outbound // empty')
    ACTION=$(echo "$RULE" | jq -r '.action // empty')

    # Определяем тип правила для красивого отображения
    if [ -n "$ACTION" ] && [ "$ACTION" != "route" ]; then
        PROTO=$(echo "$RULE" | jq -r '.protocol // ""')
        if [ -n "$PROTO" ]; then
            printf "  %2d. protocol: %-13s action: %s\n" "$i" "$PROTO" "$ACTION"
        else
            printf "  %2d. action: %s\n" "$i" "$ACTION"
        fi
    elif echo "$RULE" | jq -e '.protocol' >/dev/null 2>&1; then
        PROTO=$(echo "$RULE" | jq -r '.protocol')
        printf "  %2d. protocol: %-20s → %s\n" "$i" "$PROTO" "$OUTBOUND"
    elif echo "$RULE" | jq -e '.inbound' >/dev/null 2>&1; then
        INBOUND=$(echo "$RULE" | jq -r '.inbound | join(", ")')
        printf "  %2d. inbound: %-21s → %s\n" "$i" "$INBOUND" "$OUTBOUND"
    elif echo "$RULE" | jq -e '.rule_set' >/dev/null 2>&1; then
        RS=$(echo "$RULE" | jq -r '.rule_set | join(", ")')
        printf "  %2d. rule-set: %-20s → %s\n" "$i" "$RS" "$OUTBOUND"
    elif echo "$RULE" | jq -e '.domain' >/dev/null 2>&1; then
        DOMAINS=$(echo "$RULE" | jq -r '.domain | join(", ")')
        printf "  %2d. domain: %-21s → %s  ${YELLOW}[manual]${NC}\n" "$i" "$DOMAINS" "$OUTBOUND"
    elif echo "$RULE" | jq -e '.domain_suffix' >/dev/null 2>&1; then
        DS=$(echo "$RULE" | jq -r '.domain_suffix | join(", ")')
        printf "  %2d. domain_suffix: %-14s → %s  ${YELLOW}[manual]${NC}\n" "$i" "$DS" "$OUTBOUND"
    elif echo "$RULE" | jq -e '.domain_keyword' >/dev/null 2>&1; then
        DK=$(echo "$RULE" | jq -r '.domain_keyword | join(", ")')
        printf "  %2d. domain_keyword: %-13s → %s  ${YELLOW}[manual]${NC}\n" "$i" "$DK" "$OUTBOUND"
    elif echo "$RULE" | jq -e '.ip_cidr' >/dev/null 2>&1; then
        IC=$(echo "$RULE" | jq -r '.ip_cidr | join(", ")')
        printf "  %2d. ip_cidr: %-20s → %s  ${YELLOW}[manual]${NC}\n" "$i" "$IC" "$OUTBOUND"
    else
        printf "  %2d. (другое)                      → %s\n" "$i" "$OUTBOUND"
    fi
    ((i++))
done

FINAL=$(jq -r '.route.final // "direct"' "$SINGBOX_CONFIG")
printf "  %2d. * (final)                      → %s\n" "$i" "$FINAL"

# ── DNS ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══ DNS ═══${NC}"

jq -r '.dns.servers[] | @json' "$SINGBOX_CONFIG" 2>/dev/null | \
while read -r DNS_ENTRY; do
    D_TAG=$(echo "$DNS_ENTRY" | jq -r '.tag // "?"')
    D_TYPE=$(echo "$DNS_ENTRY" | jq -r '.type // "?"')
    D_SERVER=$(echo "$DNS_ENTRY" | jq -r '.server // ""')
    D_DETOUR=$(echo "$DNS_ENTRY" | jq -r '.detour // "-"')
    if [ -n "$D_SERVER" ]; then
        printf "  %-14s %s://%s  (detour: %s)\n" "$D_TAG:" "$D_TYPE" "$D_SERVER" "$D_DETOUR"
    else
        printf "  %-14s %s  (detour: %s)\n" "$D_TAG:" "$D_TYPE" "$D_DETOUR"
    fi
done

DNS_RULES_COUNT=$(jq '.dns.rules | length' "$SINGBOX_CONFIG" 2>/dev/null)
if [ "$DNS_RULES_COUNT" -gt 0 ]; then
    echo ""
    echo "  Правила DNS:"
    for ((idx=0; idx<DNS_RULES_COUNT; idx++)); do
        DR=$(jq -c ".dns.rules[$idx]" "$SINGBOX_CONFIG")
        SERVER=$(echo "$DR" | jq -r '.server')
        if echo "$DR" | jq -e '.rule_set' >/dev/null 2>&1; then
            RS=$(echo "$DR" | jq -r '.rule_set | join(", ")')
            echo "    rule-set: $RS → $SERVER"
        elif echo "$DR" | jq -e '.domain' >/dev/null 2>&1; then
            D=$(echo "$DR" | jq -r '.domain | join(", ")')
            echo "    domain: $D → $SERVER"
        elif echo "$DR" | jq -e '.domain_suffix' >/dev/null 2>&1; then
            DS=$(echo "$DR" | jq -r '.domain_suffix | join(", ")')
            echo "    domain_suffix: $DS → $SERVER"
        else
            echo "    (другое) → $SERVER"
        fi
    done
fi

DNS_FINAL=$(jq -r '.dns.final // "dns-direct"' "$SINGBOX_CONFIG")
echo "    * (final) → $DNS_FINAL"

# ── Rule-sets ───────────────────────────────────────────────
RS_COUNT=$(jq '.route.rule_set | length' "$SINGBOX_CONFIG" 2>/dev/null)
if [ "$RS_COUNT" -gt 0 ]; then
    echo ""
    echo -e "${BOLD}═══ Rule-sets ═══${NC}"
    jq -r '.route.rule_set[] | "  \(.tag) (\(.type))"' "$SINGBOX_CONFIG"
fi

echo ""
