#!/bin/bash
# ============================================================
#  sing-box — Создание группы outbound'ов (urltest / selector)
# ============================================================
#  urltest  — автоматический выбор лучшего по latency + failover
#  selector — ручной выбор через API
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/singbox-common.sh"

check_root
check_singbox
check_jq

echo ""
echo -e "${CYAN}${BOLD}═══ sing-box: Создать группу outbound'ов ═══${NC}"
echo ""

# ── Получение списка VLESS-outbound'ов ──────────────────────
VLESS_TAGS=$(jq -r '.outbounds[] | select(.type == "vless") | .tag' "$SINGBOX_CONFIG")

if [ -z "$VLESS_TAGS" ]; then
    err "Нет VLESS-подключений. Сначала добавьте: sudo ./scripts/singbox-add-vless.sh"
    exit 1
fi

echo "  Доступные VLESS-подключения:"
i=1
declare -a TAG_ARRAY=()
while IFS= read -r tag; do
    TAG_ARRAY+=("$tag")
    SERVER=$(jq -r --arg t "$tag" '.outbounds[] | select(.tag == $t) | "\(.server):\(.server_port)"' "$SINGBOX_CONFIG")
    echo "    $i) $tag  →  $SERVER"
    ((i++))
done <<< "$VLESS_TAGS"
echo ""

# ── Параметры группы ────────────────────────────────────────
read -p "  Тег группы [proxy]: " GROUP_TAG
GROUP_TAG=${GROUP_TAG:-proxy}

# Проверка дублей
if jq -e --arg tag "$GROUP_TAG" '.outbounds[] | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null 2>&1; then
    warn "Группа '$GROUP_TAG' уже существует. Она будет пересоздана."
fi

echo ""
echo "  Тип группы:"
echo "    1) urltest  — автоматический выбор лучшего + failover"
echo "    2) selector — ручной выбор"
read -p "  Выбор [1]: " TYPE_CHOICE
TYPE_CHOICE=${TYPE_CHOICE:-1}
case "$TYPE_CHOICE" in
    1) GROUP_TYPE="urltest" ;;
    2) GROUP_TYPE="selector" ;;
    *) err "Неверный выбор"; exit 1 ;;
esac

# ── Выбор outbound'ов для группы ────────────────────────────
echo ""
echo "  Введите номера подключений через пробел (или 'all' для всех):"
read -p "  Выбор [all]: " SELECTION
SELECTION=${SELECTION:-all}

declare -a SELECTED=()
if [ "$SELECTION" = "all" ]; then
    SELECTED=("${TAG_ARRAY[@]}")
else
    for num in $SELECTION; do
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#TAG_ARRAY[@]}" ]; then
            SELECTED+=("${TAG_ARRAY[$((num-1))]}")
        else
            err "Неверный номер: $num"
            exit 1
        fi
    done
fi

if [ "${#SELECTED[@]}" -eq 0 ]; then
    err "Не выбрано ни одного подключения"
    exit 1
fi

SELECTED_JSON=$(printf '%s\n' "${SELECTED[@]}" | jq -R . | jq -s .)

# ── Параметры urltest ───────────────────────────────────────
HEALTH_URL="https://www.gstatic.com/generate_204"
HEALTH_INTERVAL="3m"
HEALTH_TOLERANCE=50

if [ "$GROUP_TYPE" = "urltest" ]; then
    echo ""
    echo -e "${BOLD}  Настройка health-check:${NC}"

    read -p "  URL проверки [$HEALTH_URL]: " INPUT_URL
    HEALTH_URL=${INPUT_URL:-$HEALTH_URL}

    read -p "  Интервал проверки [$HEALTH_INTERVAL]: " INPUT_INTERVAL
    HEALTH_INTERVAL=${INPUT_INTERVAL:-$HEALTH_INTERVAL}

    read -p "  Tolerance, мс (допустимая разница latency) [$HEALTH_TOLERANCE]: " INPUT_TOL
    HEALTH_TOLERANCE=${INPUT_TOL:-$HEALTH_TOLERANCE}
fi

# ── Настройка proxy-in и DNS ────────────────────────────────
echo ""
read -p "  Использовать '$GROUP_TAG' для proxy-inbound (SOCKS/HTTP → VPN)? [Y/n]: " USE_PROXY
USE_PROXY=${USE_PROXY:-Y}

read -p "  Использовать '$GROUP_TAG' для VPN DNS (split DNS)? [Y/n]: " USE_DNS
USE_DNS=${USE_DNS:-Y}

# ── Показ итога ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══ Новая группа ═══${NC}"
echo "  Тег:          $GROUP_TAG"
echo "  Тип:          $GROUP_TYPE"
echo "  Outbound'ы:   ${SELECTED[*]}"
if [ "$GROUP_TYPE" = "urltest" ]; then
    echo "  Health URL:   $HEALTH_URL"
    echo "  Интервал:     $HEALTH_INTERVAL"
    echo "  Tolerance:    ${HEALTH_TOLERANCE}ms"
fi
[[ "$USE_PROXY" =~ ^[Yy]$ ]] && echo "  Proxy-in:     → $GROUP_TAG"
[[ "$USE_DNS" =~ ^[Yy]$ ]]   && echo "  DNS VPN:      detour → $GROUP_TAG"
echo ""

read -p "Создать? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено."
    exit 0
fi

# ── Сборка JSON ─────────────────────────────────────────────
info "Создание группы..."
backup_config

if [ "$GROUP_TYPE" = "urltest" ]; then
    GROUP_OBJ=$(jq -n \
        --arg tag "$GROUP_TAG" \
        --argjson outbounds "$SELECTED_JSON" \
        --arg url "$HEALTH_URL" \
        --arg interval "$HEALTH_INTERVAL" \
        --argjson tolerance "$HEALTH_TOLERANCE" \
        '{
            type: "urltest",
            tag: $tag,
            outbounds: $outbounds,
            url: $url,
            interval: $interval,
            tolerance: $tolerance
        }')
else
    GROUP_OBJ=$(jq -n \
        --arg tag "$GROUP_TAG" \
        --argjson outbounds "$SELECTED_JSON" \
        '{
            type: "selector",
            tag: $tag,
            outbounds: $outbounds
        }')
fi

# ── Вставка/замена группы в конфиге ─────────────────────────
CONFIG=$(cat "$SINGBOX_CONFIG")

# Удалить старую группу с тем же тегом (если есть)
CONFIG=$(echo "$CONFIG" | jq --arg tag "$GROUP_TAG" '
    .outbounds |= map(select(.tag != $tag))
')

# Вставить новую группу перед системными outbound'ами
CONFIG=$(echo "$CONFIG" | jq --argjson new "$GROUP_OBJ" '
    .outbounds as $ob |
    ($ob | to_entries | map(select(.value.type == "direct" or .value.type == "block" or .value.type == "dns")) | .[0].key // ($ob | length)) as $pos |
    .outbounds = ($ob[:$pos] + [$new] + $ob[$pos:])
')

# ── Настройка proxy-in → группа ─────────────────────────────
if [[ "$USE_PROXY" =~ ^[Yy]$ ]]; then
    # Удалить старое правило proxy-in (если есть)
    CONFIG=$(echo "$CONFIG" | jq '
        .route.rules |= map(select(.inbound != ["proxy-in"]))
    ')
    # Добавить новое правило proxy-in после action-правил (sniff, hijack-dns)
    CONFIG=$(echo "$CONFIG" | jq --arg tag "$GROUP_TAG" '
        .route.rules as $r |
        ($r | to_entries | map(select(.value.action != null)) | .[-1].key // -1) as $action_pos |
        .route.rules = ($r[:$action_pos+1] + [{inbound: ["proxy-in"], outbound: $tag}] + $r[$action_pos+1:])
    ')
    ok "Proxy-in → $GROUP_TAG"
fi

# ── Настройка DNS VPN detour ────────────────────────────────
if [[ "$USE_DNS" =~ ^[Yy]$ ]]; then
    CONFIG=$(echo "$CONFIG" | jq --arg tag "$GROUP_TAG" '
        .dns.servers |= map(
            if .tag == "dns-vpn" then .detour = $tag else . end
        )
    ')
    ok "DNS VPN detour → $GROUP_TAG"
fi

write_config "$CONFIG"
ok "Группа '$GROUP_TAG' создана"

# ── Применение ──────────────────────────────────────────────
offer_apply
