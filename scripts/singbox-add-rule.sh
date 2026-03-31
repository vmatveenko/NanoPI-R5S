#!/bin/bash
# ============================================================
#  sing-box — Добавление правила маршрутизации
# ============================================================
#  Поддерживает:
#    - Ручные правила (domain, domain_suffix, ip_cidr) — высший приоритет
#    - Rule-set (geosite, geoip) — ниже ручных
#  Автоматически зеркалирует DNS-правила для split DNS.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/singbox-common.sh"

check_root
check_singbox
check_jq

echo ""
echo -e "${CYAN}${BOLD}═══ sing-box: Добавить правило маршрутизации ═══${NC}"
echo ""

# ── Выбор типа правила ──────────────────────────────────────
echo "  Тип правила:"
echo "    --- Ручные (высший приоритет) ---"
echo "    1) domain         — точное совпадение домена"
echo "    2) domain_suffix  — суффикс домена (*.example.com)"
echo "    3) domain_keyword — ключевое слово в домене"
echo "    4) ip_cidr        — подсеть IP-адресов"
echo "    --- Rule-set (community списки) ---"
echo "    5) geosite        — категория сайтов (youtube, google, ...)"
echo "    6) geoip          — страна по IP (ru, us, ...)"
read -p "  Выбор [5]: " RULE_CHOICE
RULE_CHOICE=${RULE_CHOICE:-5}

RULE_TYPE=""
IS_RULESET=0
case "$RULE_CHOICE" in
    1) RULE_TYPE="domain" ;;
    2) RULE_TYPE="domain_suffix" ;;
    3) RULE_TYPE="domain_keyword" ;;
    4) RULE_TYPE="ip_cidr" ;;
    5) RULE_TYPE="geosite"; IS_RULESET=1 ;;
    6) RULE_TYPE="geoip"; IS_RULESET=1 ;;
    *) err "Неверный выбор"; exit 1 ;;
esac

# ── Ввод значения ───────────────────────────────────────────
RULE_VALUE=""
RULESET_TAG=""
RULESET_URL=""

if [ "$RULE_TYPE" = "geosite" ]; then
    echo ""
    echo "  Популярные категории geosite:"
    echo "    1) youtube      6) telegram"
    echo "    2) google       7) netflix"
    echo "    3) facebook     8) tiktok"
    echo "    4) instagram    9) openai"
    echo "    5) twitter     10) другое (ввести вручную)"
    read -p "  Выбор [10]: " GEO_CHOICE
    GEO_CHOICE=${GEO_CHOICE:-10}

    case "$GEO_CHOICE" in
        1) RULE_VALUE="youtube" ;;
        2) RULE_VALUE="google" ;;
        3) RULE_VALUE="facebook" ;;
        4) RULE_VALUE="instagram" ;;
        5) RULE_VALUE="twitter" ;;
        6) RULE_VALUE="telegram" ;;
        7) RULE_VALUE="netflix" ;;
        8) RULE_VALUE="tiktok" ;;
        9) RULE_VALUE="openai" ;;
        10)
            read -p "  Имя категории geosite: " RULE_VALUE
            ;;
        *) err "Неверный выбор"; exit 1 ;;
    esac

    RULESET_TAG="geosite-${RULE_VALUE}"
    RULESET_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-${RULE_VALUE}.srs"

elif [ "$RULE_TYPE" = "geoip" ]; then
    echo ""
    echo "  Популярные категории geoip:"
    echo "    1) ru    — Россия"
    echo "    2) us    — США"
    echo "    3) cn    — Китай"
    echo "    4) de    — Германия"
    echo "    5) другое (ввести код страны)"
    read -p "  Выбор [5]: " GEO_CHOICE
    GEO_CHOICE=${GEO_CHOICE:-5}

    case "$GEO_CHOICE" in
        1) RULE_VALUE="ru" ;;
        2) RULE_VALUE="us" ;;
        3) RULE_VALUE="cn" ;;
        4) RULE_VALUE="de" ;;
        5)
            read -p "  Код страны (2 буквы): " RULE_VALUE
            RULE_VALUE=$(echo "$RULE_VALUE" | tr '[:upper:]' '[:lower:]')
            ;;
        *) err "Неверный выбор"; exit 1 ;;
    esac

    RULESET_TAG="geoip-${RULE_VALUE}"
    RULESET_URL="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-${RULE_VALUE}.srs"

else
    echo ""
    case "$RULE_TYPE" in
        domain)         read -p "  Домен (example.com): " RULE_VALUE ;;
        domain_suffix)  read -p "  Суффикс домена (example.com → *.example.com): " RULE_VALUE ;;
        domain_keyword) read -p "  Ключевое слово в домене: " RULE_VALUE ;;
        ip_cidr)        read -p "  IP/CIDR (10.0.0.0/8): " RULE_VALUE ;;
    esac
fi

if [ -z "$RULE_VALUE" ]; then
    err "Значение не может быть пустым"
    exit 1
fi

# ── Выбор outbound ──────────────────────────────────────────
echo ""
echo "  Доступные outbound'ы:"
OUTBOUNDS=$(jq -r '.outbounds[] | select(.type != "dns") | .tag' "$SINGBOX_CONFIG")
i=1
declare -a OB_ARRAY=()
while IFS= read -r ob; do
    OB_ARRAY+=("$ob")
    OB_TYPE=$(jq -r --arg t "$ob" '.outbounds[] | select(.tag == $t) | .type' "$SINGBOX_CONFIG")
    echo "    $i) [$OB_TYPE] $ob"
    ((i++))
done <<< "$OUTBOUNDS"

echo ""
read -p "  Outbound для этого правила (номер): " OB_NUM
if ! [[ "$OB_NUM" =~ ^[0-9]+$ ]] || [ "$OB_NUM" -lt 1 ] || [ "$OB_NUM" -gt "${#OB_ARRAY[@]}" ]; then
    err "Неверный номер"
    exit 1
fi
TARGET_OUTBOUND="${OB_ARRAY[$((OB_NUM-1))]}"

# ── Показ итога ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══ Новое правило ═══${NC}"
if [ "$IS_RULESET" -eq 1 ]; then
    echo "  Тип:       rule-set ($RULE_TYPE)"
    echo "  Категория: $RULE_VALUE"
    echo "  Rule-set:  $RULESET_TAG"
else
    echo "  Тип:       manual ($RULE_TYPE)"
    echo "  Значение:  $RULE_VALUE"
fi
echo "  Outbound:  $TARGET_OUTBOUND"

# Проверяем, нужно ли зеркалировать DNS
DNS_MIRROR=0
TARGET_TYPE=$(jq -r --arg t "$TARGET_OUTBOUND" '.outbounds[] | select(.tag == $t) | .type' "$SINGBOX_CONFIG")
if [ "$TARGET_TYPE" != "direct" ] && [ "$TARGET_TYPE" != "block" ]; then
    DNS_MIRROR=1
    echo "  DNS:       → dns-vpn (автоматическое зеркалирование)"
fi
echo ""

read -p "Добавить? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено."
    exit 0
fi

# ── Применение правила ──────────────────────────────────────
info "Добавление правила..."
backup_config

CONFIG=$(cat "$SINGBOX_CONFIG")

if [ "$IS_RULESET" -eq 1 ]; then
    # ─── Rule-set правило ───────────────────────────────────

    # Добавить rule_set источник если ещё нет
    if ! echo "$CONFIG" | jq -e --arg tag "$RULESET_TAG" '.route.rule_set[]? | select(.tag == $tag)' >/dev/null 2>&1; then
        CONFIG=$(echo "$CONFIG" | jq --arg tag "$RULESET_TAG" --arg url "$RULESET_URL" '
            .route.rule_set += [{
                type: "remote",
                tag: $tag,
                format: "binary",
                url: $url,
                download_detour: "direct",
                update_interval: "72h"
            }]
        ')
        ok "Rule-set '$RULESET_TAG' добавлен"
    else
        info "Rule-set '$RULESET_TAG' уже существует"
    fi

    # Проверить что такое правило ещё не существует
    if echo "$CONFIG" | jq -e --arg rs "$RULESET_TAG" --arg ob "$TARGET_OUTBOUND" \
        '.route.rules[] | select(.rule_set? == [$rs] and .outbound == $ob)' >/dev/null 2>&1; then
        warn "Правило '$RULESET_TAG → $TARGET_OUTBOUND' уже существует"
    else
        # Добавить routing rule (в конец, перед final)
        CONFIG=$(echo "$CONFIG" | jq --arg rs "$RULESET_TAG" --arg ob "$TARGET_OUTBOUND" '
            .route.rules += [{rule_set: [$rs], outbound: $ob}]
        ')
    fi

    # DNS-зеркалирование
    if [ "$DNS_MIRROR" -eq 1 ]; then
        if ! echo "$CONFIG" | jq -e --arg rs "$RULESET_TAG" \
            '.dns.rules[]? | select(.rule_set? == [$rs])' >/dev/null 2>&1; then
            CONFIG=$(echo "$CONFIG" | jq --arg rs "$RULESET_TAG" '
                .dns.rules += [{rule_set: [$rs], server: "dns-vpn"}]
            ')
            ok "DNS-правило для '$RULESET_TAG' добавлено"
        fi
    fi

else
    # ─── Ручное правило ─────────────────────────────────────

    # Определяем позицию вставки: после DNS/proxy-in, перед rule_set правилами
    # Ручные правила имеют приоритет над rule-set
    NEW_RULE=$(jq -n --arg type "$RULE_TYPE" --arg val "$RULE_VALUE" --arg ob "$TARGET_OUTBOUND" '
        {($type): [$val], outbound: $ob}
    ')

    CONFIG=$(echo "$CONFIG" | jq --argjson new "$NEW_RULE" '
        .route.rules as $r |
        ($r | to_entries | map(select(.value.rule_set != null)) | .[0].key // ($r | length)) as $rs_pos |
        .route.rules = ($r[:$rs_pos] + [$new] + $r[$rs_pos:])
    ')

    # DNS-зеркалирование для ручных правил
    if [ "$DNS_MIRROR" -eq 1 ]; then
        DNS_RULE=$(jq -n --arg type "$RULE_TYPE" --arg val "$RULE_VALUE" '
            {($type): [$val], server: "dns-vpn"}
        ')
        CONFIG=$(echo "$CONFIG" | jq --argjson new "$DNS_RULE" '
            .dns.rules += [$new]
        ')
        ok "DNS-правило для '$RULE_VALUE' добавлено"
    fi
fi

write_config "$CONFIG"
ok "Правило добавлено: $RULE_TYPE:$RULE_VALUE → $TARGET_OUTBOUND"

# ── Применение ──────────────────────────────────────────────
offer_apply
