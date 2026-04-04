#!/bin/bash
# ============================================================
#  sing-box — Единый скрипт управления
# ============================================================
#  Объединяет: статус, добавление серверов/групп/правил,
#  удаление, применение конфигурации.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/scripts/singbox-common.sh"

DISABLED_RULES_FILE="/etc/sing-box/disabled-rules.json"

# Инициализация файла отключённых правил
[ ! -f "$DISABLED_RULES_FILE" ] && echo '{}' > "$DISABLED_RULES_FILE"

# Генерация уникального ключа для правила маршрутизации
rule_key() {
    local rule="$1"
    if echo "$rule" | jq -e '.rule_set' >/dev/null 2>&1; then
        echo "rule-set:$(echo "$rule" | jq -r '.rule_set | join(",")')"
    elif echo "$rule" | jq -e '.domain' >/dev/null 2>&1; then
        echo "domain:$(echo "$rule" | jq -r '.domain | join(",")')"
    elif echo "$rule" | jq -e '.domain_suffix' >/dev/null 2>&1; then
        echo "domain_suffix:$(echo "$rule" | jq -r '.domain_suffix | join(",")')"
    elif echo "$rule" | jq -e '.domain_keyword' >/dev/null 2>&1; then
        echo "domain_keyword:$(echo "$rule" | jq -r '.domain_keyword | join(",")')"
    elif echo "$rule" | jq -e '.ip_cidr' >/dev/null 2>&1; then
        echo "ip_cidr:$(echo "$rule" | jq -r '.ip_cidr | join(",")')"
    else
        echo ""
    fi
}

# Проверка: отключено ли правило
is_rule_disabled() {
    local key="$1"
    [ -z "$key" ] && return 1
    jq -e --arg k "$key" 'has($k)' "$DISABLED_RULES_FILE" >/dev/null 2>&1
}

# ── Глобальные массивы для print_user_rules ──────────────────
_UR_INDICES=()
_UR_KEYS=()
_UR_COUNT=0

print_user_rules() {
    _UR_INDICES=()
    _UR_KEYS=()
    _UR_COUNT=0

    local rules_count ri=1
    rules_count=$(jq '.route.rules | length' "$SINGBOX_CONFIG")

    for ((idx=0; idx<rules_count; idx++)); do
        local rule action outbound
        rule=$(jq -c ".route.rules[$idx]" "$SINGBOX_CONFIG")
        action=$(echo "$rule" | jq -r '.action // empty')
        outbound=$(echo "$rule" | jq -r '.outbound // empty')

        [ -n "$action" ] && [ "$action" != "route" ] && continue
        echo "$rule" | jq -e '.inbound' >/dev/null 2>&1 && continue

        local label="" mark="" key=""
        if echo "$rule" | jq -e '.rule_set' >/dev/null 2>&1; then
            label="rule-set: $(echo "$rule" | jq -r '.rule_set | join(", ")')"
        elif echo "$rule" | jq -e '.domain' >/dev/null 2>&1; then
            label="domain: $(echo "$rule" | jq -r '.domain | join(", ")')"
            mark=" [manual]"
        elif echo "$rule" | jq -e '.domain_suffix' >/dev/null 2>&1; then
            label="domain_suffix: $(echo "$rule" | jq -r '.domain_suffix | join(", ")')"
            mark=" [manual]"
        elif echo "$rule" | jq -e '.domain_keyword' >/dev/null 2>&1; then
            label="domain_keyword: $(echo "$rule" | jq -r '.domain_keyword | join(", ")')"
            mark=" [manual]"
        elif echo "$rule" | jq -e '.ip_cidr' >/dev/null 2>&1; then
            label="ip_cidr: $(echo "$rule" | jq -r '.ip_cidr | join(", ")')"
            mark=" [manual]"
        else
            label="(другое)"
        fi

        key=$(rule_key "$rule")
        _UR_COUNT=$((_UR_COUNT + 1))
        _UR_INDICES+=("$idx")
        _UR_KEYS+=("$key")

        if [ -n "$key" ] && is_rule_disabled "$key"; then
            printf "   ${WHITE}%d  %-40s -> %s ${RED}[ВЫКЛ]${RESET}\n" "$ri" "$label" "$outbound"
        else
            printf "   ${WHITE}%d  %-40s -> %s%s${RESET}\n" "$ri" "$label" "$outbound" "$mark"
        fi
        ri=$((ri + 1))
    done

    local final
    final=$(jq -r '.route.final // "direct"' "$SINGBOX_CONFIG")
    printf "   •  ${YELLOW}%-40s -> %s${RESET}\n" "*final" "$final"
}

switch_dns_mirror() {
    local rule="$1" target_server="$2" config="$3"
    if echo "$rule" | jq -e '.rule_set' >/dev/null 2>&1; then
        local rs
        rs=$(echo "$rule" | jq -r '.rule_set[0]')
        echo "$config" | jq --arg rs "$rs" --arg srv "$target_server" \
            '.dns.rules |= map(if .rule_set == [$rs] then .server = $srv else . end)'
    elif echo "$rule" | jq -e '.domain' >/dev/null 2>&1; then
        local d
        d=$(echo "$rule" | jq -c '.domain')
        echo "$config" | jq --argjson d "$d" --arg srv "$target_server" \
            '.dns.rules |= map(if .domain == $d then .server = $srv else . end)'
    elif echo "$rule" | jq -e '.domain_suffix' >/dev/null 2>&1; then
        local ds
        ds=$(echo "$rule" | jq -c '.domain_suffix')
        echo "$config" | jq --argjson ds "$ds" --arg srv "$target_server" \
            '.dns.rules |= map(if .domain_suffix == $ds then .server = $srv else . end)'
    elif echo "$rule" | jq -e '.domain_keyword' >/dev/null 2>&1; then
        local dk
        dk=$(echo "$rule" | jq -c '.domain_keyword')
        echo "$config" | jq --argjson dk "$dk" --arg srv "$target_server" \
            '.dns.rules |= map(if .domain_keyword == $dk then .server = $srv else . end)'
    elif echo "$rule" | jq -e '.ip_cidr' >/dev/null 2>&1; then
        local ic
        ic=$(echo "$rule" | jq -c '.ip_cidr')
        echo "$config" | jq --argjson ic "$ic" --arg srv "$target_server" \
            '.dns.rules |= map(if .ip_cidr == $ic then .server = $srv else . end)'
    else
        echo "$config"
    fi
}

delete_dns_mirror() {
    local rule="$1" config="$2"
    if echo "$rule" | jq -e '.rule_set' >/dev/null 2>&1; then
        local rs
        rs=$(echo "$rule" | jq -r '.rule_set[0]')
        echo "$config" | jq --arg rs "$rs" '.dns.rules |= map(select(.rule_set != [$rs]))'
    elif echo "$rule" | jq -e '.domain' >/dev/null 2>&1; then
        local d
        d=$(echo "$rule" | jq -c '.domain')
        echo "$config" | jq --argjson d "$d" '.dns.rules |= map(select(.domain != $d))'
    elif echo "$rule" | jq -e '.domain_suffix' >/dev/null 2>&1; then
        local ds
        ds=$(echo "$rule" | jq -c '.domain_suffix')
        echo "$config" | jq --argjson ds "$ds" '.dns.rules |= map(select(.domain_suffix != $ds))'
    elif echo "$rule" | jq -e '.domain_keyword' >/dev/null 2>&1; then
        local dk
        dk=$(echo "$rule" | jq -c '.domain_keyword')
        echo "$config" | jq --argjson dk "$dk" '.dns.rules |= map(select(.domain_keyword != $dk))'
    elif echo "$rule" | jq -e '.ip_cidr' >/dev/null 2>&1; then
        local ic
        ic=$(echo "$rule" | jq -c '.ip_cidr')
        echo "$config" | jq --argjson ic "$ic" '.dns.rules |= map(select(.ip_cidr != $ic))'
    else
        echo "$config"
    fi
}

# ── UI helpers ───────────────────────────────────────────────
DIM='\033[2m'
UI_MIN_WIDTH=64
UI_MAX_WIDTH=100
UI_PAD=2

term_width() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    if ! [[ "$cols" =~ ^[0-9]+$ ]]; then
        cols=80
    fi
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

truncate_text() {
    local s="${1:-}" max="${2:-20}"
    local ellipsis="..."
    [ "$max" -le 0 ] && { printf ''; return; }
    if [ ${#s} -le "$max" ]; then
        printf '%s' "$s"
    elif [ "$max" -le 3 ]; then
        printf '%.*s' "$max" "$s"
    else
        printf '%s%s' "${s:0:max-3}" "$ellipsis"
    fi
}

print_kv() {
    local key="$1" value="$2" key_w=16
    printf '  %-*s %b\n' "$key_w" "$key" "$value"
}

print_note() {
    printf '  %b\n' "$1"
}

print_item() {
    local idx="$1" kind="$2" title="$3" detail="${4:-}" color="${5:-$NC}"
    local cols kind_w title_w idx_txt title_txt detail_txt
    cols=$(term_width)
    kind_w=10
    idx_txt=$(printf '%2s' "$idx")
    title_w=$((cols - UI_PAD * 2 - 2 - 2 - kind_w - 2))
    [ "$title_w" -lt 12 ] && title_w=12
    title_txt=$(truncate_text "$title" "$title_w")
    printf '  %b%s%b  %-*s  %s\n' "$color" "$idx_txt" "$NC" "$kind_w" "[$kind]" "$title_txt"
    if [ -n "$detail" ]; then
        detail_txt=$(truncate_text "$detail" $((cols - UI_PAD * 2 - 4)))
        printf '      %b%s%b\n' "$DIM" "$detail_txt" "$NC"
    fi
}

# Список VLESS outbound'ов (как в cmd_status). Если передано имя массива — дополняет его тегами по порядку.
print_vless_servers_list() {
    local ob_count si=1 oi ob_type ob_tag ob_server ob_port
    ob_count=$(jq '.outbounds | length' "$SINGBOX_CONFIG")
    if [ -n "${1:-}" ]; then
        local -n _vl_tags_ref="$1"
    fi
    for ((oi=0; oi<ob_count; oi++)); do
        ob_type=$(jq -r ".outbounds[$oi].type" "$SINGBOX_CONFIG")
        ob_tag=$(jq -r ".outbounds[$oi].tag" "$SINGBOX_CONFIG")
        [ "$ob_type" != "vless" ] && continue
        ob_server=$(jq -r ".outbounds[$oi].server // \"\"" "$SINGBOX_CONFIG")
        ob_port=$(jq -r ".outbounds[$oi].server_port // \"\"" "$SINGBOX_CONFIG")
        printf "    ${WHITE}%d  [vless]       %s → %s:%s${RESET}\n" "$si" "$ob_tag" "$ob_server" "$ob_port"
        [ -n "${1:-}" ] && _vl_tags_ref+=("$ob_tag")
        si=$((si + 1))
    done
}

print_route_rule() {
    local idx="$1" left="$2" right="$3" mark="${4:-}" color="${5:-$NC}"
    local cols left_w left_txt suffix=''
    cols=$(term_width)
    left_w=$((cols - UI_PAD * 2 - 2 - 2 - 4 - 3 - 16))
    [ "$left_w" -lt 18 ] && left_w=18
    [ -n "$mark" ] && suffix=" $mark"
    left_txt=$(truncate_text "$left" "$left_w")
    printf '  %b%2s%b  %-*s -> %s%s\n' "$color" "$idx" "$NC" "$left_w" "$left_txt" "$right" "$suffix"
}

draw_header() {
    local title="$1" color="${2:-$CYAN}"
    echo
    print_note "${color}${BOLD}▌ ${title}${RESET}"
    print_note "${color}$(rule_line '=')${RESET}"
}

draw_section() {
    echo
    print_note "${BOLD}$1${RESET}"
    print_note "${DIM}$(rule_line '-')${RESET}"
}

separator() {
    print_note "${DIM}$(rule_line '.')${RESET}"
}

urldecode() {
    printf '%b' "${1//%/\\x}"
}
# ════════════════════════════════════════════════════════════
#  СТАТУС
# ════════════════════════════════════════════════════════════
cmd_status() {
    echo ""
    echo -e "  ${CYAN}${BOLD}▌ Статус${RESET}"
    echo -e "  ------------------------------------------------------------------------"

    local version
    version=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | awk '{print $NF}' || echo "?")

    local svc_status
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        svc_status="${GREEN}active${RESET}"
    else
        svc_status="${RED}inactive${RESET}"
    fi

    local tun_iface tun_addr proxy_port tun_status
    tun_iface=$(jq -r '.inbounds[] | select(.type == "tun") | .interface_name // "tun0"' "$SINGBOX_CONFIG" 2>/dev/null)
    tun_addr=$(jq -r '.inbounds[] | select(.type == "tun") | .address[0] // "?"' "$SINGBOX_CONFIG" 2>/dev/null)
    proxy_port=$(jq -r '.inbounds[] | select(.type == "mixed") | .listen_port // "?"' "$SINGBOX_CONFIG" 2>/dev/null)

    if ip link show "$tun_iface" &>/dev/null; then
        tun_status="${GREEN}UP${RESET}"
    else
        tun_status="${RED}DOWN${RESET}"
    fi

    echo -e "  Сервис:           $svc_status"
    echo -e "  Версия:           $version"
    echo -e "  TUN:              $tun_iface ($tun_addr)"
    echo -e "  TUN статус:       $tun_status"
    echo -e "  Proxy-in:         :${proxy_port} (SOCKS5/HTTP)"

    # ── Серверы (vless) ──
    echo ""
    echo -e "  ${BOLD}Серверы${RESET}"
    echo -e "  ------------------------------------------------------------------------"
    local ob_count
    ob_count=$(jq '.outbounds | length' "$SINGBOX_CONFIG")
    print_vless_servers_list

    # ── Группы (urltest/selector) — только если есть ──
    local has_groups=0
    for ((oi=0; oi<ob_count; oi++)); do
        local ot
        ot=$(jq -r ".outbounds[$oi].type" "$SINGBOX_CONFIG")
        if [ "$ot" = "urltest" ] || [ "$ot" = "selector" ]; then
            has_groups=1; break
        fi
    done
    if [ "$has_groups" -eq 1 ]; then
        echo ""
        echo -e "  ${BOLD}Группы${RESET}"
        echo -e "  ------------------------------------------------------------------------"
        local gi=1
        for ((oi=0; oi<ob_count; oi++)); do
            local ob_type ob_tag ob_members
            ob_type=$(jq -r ".outbounds[$oi].type" "$SINGBOX_CONFIG")
            [ "$ob_type" != "urltest" ] && [ "$ob_type" != "selector" ] && continue
            ob_tag=$(jq -r ".outbounds[$oi].tag" "$SINGBOX_CONFIG")
            ob_members=$(jq -r "(.outbounds[$oi].outbounds // []) | join(\", \")" "$SINGBOX_CONFIG")
            printf "   %d  [%-10s]  %s → %s\n" "$gi" "$ob_type" "$ob_tag" "$ob_members"
            gi=$((gi + 1))
        done
    fi

    # ── Служебные outbound'ы ──
    echo ""
    echo -e "  ${BOLD}Служебные outbound'ы${RESET}"
    echo -e "  ------------------------------------------------------------------------"
    for ((oi=0; oi<ob_count; oi++)); do
        local ob_type ob_tag
        ob_type=$(jq -r ".outbounds[$oi].type" "$SINGBOX_CONFIG")
        ob_tag=$(jq -r ".outbounds[$oi].tag" "$SINGBOX_CONFIG")
        case "$ob_type" in
            direct|block|dns) printf "   •  [%s]  %s\n" "$ob_type" "$ob_tag" ;;
        esac
    done

    # ── Правила маршрутизации ──
    local rules_count ri=1
    rules_count=$(jq '.route.rules | length' "$SINGBOX_CONFIG")

    # Системные правила
    echo ""
    echo -e "  ${BOLD}Системные правила${RESET}"
    echo -e "  ------------------------------------------------------------------------"
    for ((idx=0; idx<rules_count; idx++)); do
        local rule action outbound
        rule=$(jq -c ".route.rules[$idx]" "$SINGBOX_CONFIG")
        action=$(echo "$rule" | jq -r '.action // empty')
        outbound=$(echo "$rule" | jq -r '.outbound // empty')

        if [ -n "$action" ] && [ "$action" != "route" ]; then
            local proto
            proto=$(echo "$rule" | jq -r '.protocol // empty')
            if [ -n "$proto" ]; then
                printf "   %d  %-40s -> %s\n" "$ri" "protocol: $proto" "$action"
            else
                printf "   %d  action: %s\n" "$ri" "$action"
            fi
            ri=$((ri + 1))
        elif echo "$rule" | jq -e '.inbound' >/dev/null 2>&1; then
            local inb
            inb=$(echo "$rule" | jq -r '.inbound | join(", ")')
            printf "   %d  %-40s -> %s\n" "$ri" "inbound: $inb" "$outbound"
            ri=$((ri + 1))
        fi
    done

    # Пользовательские правила
    echo ""
    echo -e "  ${BOLD}Пользовательские правила${RESET}"
    echo -e "  ------------------------------------------------------------------------"
    print_user_rules

    # ── DNS ──
    echo ""
    echo -e "  ${BOLD}DNS${RESET}"
    echo -e "  ------------------------------------------------------------------------"
    local dns_servers_count
    dns_servers_count=$(jq '.dns.servers | length' "$SINGBOX_CONFIG" 2>/dev/null)
    for ((di=0; di<dns_servers_count; di++)); do
        local d_tag d_type d_server d_detour detail
        d_tag=$(jq -r ".dns.servers[$di].tag // \"?\"" "$SINGBOX_CONFIG")
        d_type=$(jq -r ".dns.servers[$di].type // \"?\"" "$SINGBOX_CONFIG")
        d_server=$(jq -r ".dns.servers[$di].server // \"\"" "$SINGBOX_CONFIG")
        d_detour=$(jq -r ".dns.servers[$di].detour // \"-\"" "$SINGBOX_CONFIG")
        if [ -n "$d_server" ]; then
            detail="${d_type}://${d_server} (detour: ${d_detour})"
        else
            detail="${d_type} (detour: ${d_detour})"
        fi
        printf "   %d  [dns]         %s → %s\n" "$((di + 1))" "$d_tag" "$detail"
    done

    # DNS-правила
    local dns_rules_count
    dns_rules_count=$(jq '.dns.rules | length' "$SINGBOX_CONFIG" 2>/dev/null)
    if [ "$dns_rules_count" -gt 0 ]; then
        echo ""
        echo -e "  ${BOLD}DNS-правила${RESET}"
        echo -e "  ------------------------------------------------------------------------"
        for ((idx=0; idx<dns_rules_count; idx++)); do
            local dr server left
            dr=$(jq -c ".dns.rules[$idx]" "$SINGBOX_CONFIG")
            server=$(echo "$dr" | jq -r '.server')
            if echo "$dr" | jq -e '.rule_set' >/dev/null 2>&1; then
                left="rule-set: $(echo "$dr" | jq -r '.rule_set | join(", ")')"
            elif echo "$dr" | jq -e '.domain' >/dev/null 2>&1; then
                left="domain: $(echo "$dr" | jq -r '.domain | join(", ")')"
            elif echo "$dr" | jq -e '.domain_suffix' >/dev/null 2>&1; then
                left="domain_suffix: $(echo "$dr" | jq -r '.domain_suffix | join(", ")')"
            else
                left="(другое)"
            fi
            printf "   %d  %-40s -> %s\n" "$((idx + 1))" "$left" "$server"
        done
    fi

    echo ""
    local dns_final
    dns_final=$(jq -r '.dns.final // "dns-direct"' "$SINGBOX_CONFIG")
    echo -e "  DNS по умолчанию:  $dns_final"

    # Наборы правил
    local rs_count
    rs_count=$(jq '.route.rule_set | length' "$SINGBOX_CONFIG" 2>/dev/null)
    if [ "$rs_count" -gt 0 ]; then
        echo ""
        echo -e "  ${BOLD}Наборы правил${RESET}"
        echo -e "  ------------------------------------------------------------------------"
        while IFS= read -r line; do
            echo "   •  $line"
        done < <(jq -r '.route.rule_set[] | "\(.tag) [\(.type)]"' "$SINGBOX_CONFIG")
    fi

    echo ""
}

# ════════════════════════════════════════════════════════════
#  ДОБАВИТЬ VLESS
# ════════════════════════════════════════════════════════════
cmd_add_vless() {
    draw_header "Добавить VLESS-сервер"

    local VLESS_TAG="" VLESS_SERVER="" VLESS_PORT=""
    local VLESS_UUID="" VLESS_FLOW="" VLESS_SECURITY="none"
    local VLESS_SNI="" VLESS_FINGERPRINT="chrome"
    local VLESS_REALITY_PUBKEY="" VLESS_REALITY_SHORTID=""
    local VLESS_TRANSPORT="tcp" VLESS_WS_PATH="" VLESS_WS_HOST=""
    local VLESS_GRPC_SERVICE="" VLESS_ALPN=""

    echo ""
    echo "  Способ добавления:"
    echo "    1) Вставить VLESS URI (vless://...)"
    echo "    2) Ввести параметры вручную"
    read -p "  Выбор [1]: " input_method
    input_method=${input_method:-1}

    case "$input_method" in
        1)
            echo ""
            read -p "  VLESS URI: " vless_uri
            if [[ ! "$vless_uri" == vless://* ]]; then
                err "URI должен начинаться с vless://"; return
            fi
            # Парсинг URI
            local uri="${vless_uri#vless://}"
            if [[ "$uri" == *"#"* ]]; then
                VLESS_TAG=$(urldecode "${uri##*#}")
                uri="${uri%%#*}"
            fi
            VLESS_UUID="${uri%%@*}"; uri="${uri#*@}"
            local hostport params=""
            if [[ "$uri" == *"?"* ]]; then
                hostport="${uri%%\?*}"; params="${uri#*\?}"
            else hostport="$uri"; fi
            if [[ "$hostport" == "["* ]]; then
                VLESS_SERVER="${hostport%%]*}"; VLESS_SERVER="${VLESS_SERVER#[}"
                VLESS_PORT="${hostport##*]:}"
            else
                VLESS_SERVER="${hostport%%:*}"; VLESS_PORT="${hostport##*:}"
            fi
            if [ -n "$params" ]; then
                IFS='&' read -ra PAIRS <<< "$params"
                for pair in "${PAIRS[@]}"; do
                    local key="${pair%%=*}" value
                    value=$(urldecode "${pair#*=}")
                    case "$key" in
                        type)        VLESS_TRANSPORT="$value" ;;
                        security)    VLESS_SECURITY="$value" ;;
                        sni)         VLESS_SNI="$value" ;;
                        fp)          VLESS_FINGERPRINT="$value" ;;
                        flow)        VLESS_FLOW="$value" ;;
                        pbk)         VLESS_REALITY_PUBKEY="$value" ;;
                        sid)         VLESS_REALITY_SHORTID="$value" ;;
                        path)        VLESS_WS_PATH="$value" ;;
                        host)        VLESS_WS_HOST="$value" ;;
                        serviceName) VLESS_GRPC_SERVICE="$value" ;;
                        alpn)        VLESS_ALPN="$value" ;;
                    esac
                done
            fi
            [ -z "$VLESS_TAG" ] && read -p "  Тег (имя): " VLESS_TAG
            ;;
        2)
            echo ""
            read -p "  Тег (имя): " VLESS_TAG
            [ -z "$VLESS_TAG" ] && { err "Тег не может быть пустым"; return; }
            read -p "  Сервер: " VLESS_SERVER
            [ -z "$VLESS_SERVER" ] && { err "Адрес не может быть пустым"; return; }
            read -p "  Порт [443]: " VLESS_PORT; VLESS_PORT=${VLESS_PORT:-443}
            read -p "  UUID: " VLESS_UUID
            [ -z "$VLESS_UUID" ] && { err "UUID не может быть пустым"; return; }
            read -p "  Flow []: " VLESS_FLOW
            echo "  Безопасность:  1) none  2) tls  3) reality"
            read -p "  Выбор [1]: " sec; sec=${sec:-1}
            case "$sec" in 1) VLESS_SECURITY="none";; 2) VLESS_SECURITY="tls";; 3) VLESS_SECURITY="reality";; *) err "Неверно"; return;; esac
            if [ "$VLESS_SECURITY" != "none" ]; then
                read -p "  SNI: " VLESS_SNI
                read -p "  Fingerprint [chrome]: " VLESS_FINGERPRINT; VLESS_FINGERPRINT=${VLESS_FINGERPRINT:-chrome}
                read -p "  ALPN (через запятую) []: " VLESS_ALPN
            fi
            if [ "$VLESS_SECURITY" = "reality" ]; then
                read -p "  Reality public key: " VLESS_REALITY_PUBKEY
                [ -z "$VLESS_REALITY_PUBKEY" ] && { err "Public key обязателен"; return; }
                read -p "  Reality short ID []: " VLESS_REALITY_SHORTID
            fi
            echo "  Транспорт:  1) tcp  2) ws  3) grpc"
            read -p "  Выбор [1]: " tr; tr=${tr:-1}
            case "$tr" in
                1) VLESS_TRANSPORT="tcp" ;;
                2) VLESS_TRANSPORT="ws"; read -p "  WS path [/]: " VLESS_WS_PATH; VLESS_WS_PATH=${VLESS_WS_PATH:-/}; read -p "  WS host []: " VLESS_WS_HOST ;;
                3) VLESS_TRANSPORT="grpc"; read -p "  gRPC service [grpc]: " VLESS_GRPC_SERVICE; VLESS_GRPC_SERVICE=${VLESS_GRPC_SERVICE:-grpc} ;;
                *) err "Неверно"; return ;;
            esac
            ;;
        *) err "Неверный выбор"; return ;;
    esac

    if [ -z "$VLESS_TAG" ] || [ -z "$VLESS_SERVER" ] || [ -z "$VLESS_PORT" ] || [ -z "$VLESS_UUID" ]; then
        err "Не все обязательные поля заполнены"; return
    fi
    if jq -e --arg tag "$VLESS_TAG" '.outbounds[] | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null 2>&1; then
        err "Outbound '$VLESS_TAG' уже существует"; return
    fi

    draw_section "Подтверждение"
    printf "  %-14s %s\n" "Тег:" "$VLESS_TAG"
    printf "  %-14s %s:%s\n" "Сервер:" "$VLESS_SERVER" "$VLESS_PORT"
    printf "  %-14s %s...%s\n" "UUID:" "${VLESS_UUID:0:8}" "${VLESS_UUID: -4}"
    [ -n "$VLESS_FLOW" ]       && printf "  %-14s %s\n" "Flow:" "$VLESS_FLOW"
    printf "  %-14s %s\n" "Security:" "$VLESS_SECURITY"
    [ -n "$VLESS_SNI" ]        && printf "  %-14s %s\n" "SNI:" "$VLESS_SNI"
    [ "$VLESS_SECURITY" = "reality" ] && printf "  %-14s %s...\n" "Reality PK:" "${VLESS_REALITY_PUBKEY:0:16}"
    printf "  %-14s %s\n" "Транспорт:" "$VLESS_TRANSPORT"
    echo ""

    read -p "  Добавить? [Y/n]: " confirm; confirm=${confirm:-Y}
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "  Отменено."; return; }

    backup_config

    local OUTBOUND
    OUTBOUND=$(jq -n --arg tag "$VLESS_TAG" --arg server "$VLESS_SERVER" \
        --argjson port "$VLESS_PORT" --arg uuid "$VLESS_UUID" \
        '{type: "vless", tag: $tag, server: $server, server_port: $port, uuid: $uuid}')
    [ -n "$VLESS_FLOW" ] && OUTBOUND=$(echo "$OUTBOUND" | jq --arg f "$VLESS_FLOW" '. + {flow: $f}')

    if [ "$VLESS_SECURITY" = "tls" ] || [ "$VLESS_SECURITY" = "reality" ]; then
        local TLS_OBJ
        TLS_OBJ=$(jq -n '{enabled: true}')
        [ -n "$VLESS_SNI" ] && TLS_OBJ=$(echo "$TLS_OBJ" | jq --arg s "$VLESS_SNI" '. + {server_name: $s}')
        [ -n "$VLESS_FINGERPRINT" ] && TLS_OBJ=$(echo "$TLS_OBJ" | jq --arg f "$VLESS_FINGERPRINT" '. + {utls: {enabled: true, fingerprint: $f}}')
        if [ -n "$VLESS_ALPN" ]; then
            local alpn_arr
            alpn_arr=$(echo "$VLESS_ALPN" | tr ',' '\n' | jq -R . | jq -s .)
            TLS_OBJ=$(echo "$TLS_OBJ" | jq --argjson a "$alpn_arr" '. + {alpn: $a}')
        fi
        [ "$VLESS_SECURITY" = "reality" ] && TLS_OBJ=$(echo "$TLS_OBJ" | jq \
            --arg pk "$VLESS_REALITY_PUBKEY" --arg sid "$VLESS_REALITY_SHORTID" \
            '. + {reality: {enabled: true, public_key: $pk, short_id: $sid}}')
        OUTBOUND=$(echo "$OUTBOUND" | jq --argjson tls "$TLS_OBJ" '. + {tls: $tls}')
    fi

    case "$VLESS_TRANSPORT" in
        ws)
            local tr_obj
            tr_obj=$(jq -n --arg p "${VLESS_WS_PATH:-/}" '{type: "ws", path: $p}')
            [ -n "$VLESS_WS_HOST" ] && tr_obj=$(echo "$tr_obj" | jq --arg h "$VLESS_WS_HOST" '. + {headers: {Host: $h}}')
            OUTBOUND=$(echo "$OUTBOUND" | jq --argjson t "$tr_obj" '. + {transport: $t}')
            ;;
        grpc)
            OUTBOUND=$(echo "$OUTBOUND" | jq --arg sn "${VLESS_GRPC_SERVICE:-grpc}" '. + {transport: {type: "grpc", service_name: $sn}}')
            ;;
    esac

    local NEW_CONFIG
    NEW_CONFIG=$(jq --argjson new "$OUTBOUND" '
        .outbounds as $ob |
        ($ob | to_entries | map(select(.value.type == "direct" or .value.type == "block" or .value.type == "dns")) | .[0].key // ($ob | length)) as $pos |
        .outbounds = ($ob[:$pos] + [$new] + $ob[$pos:])
    ' "$SINGBOX_CONFIG")
    write_config "$NEW_CONFIG"
    ok "VLESS '$VLESS_TAG' добавлен"
    echo ""
    offer_apply_inline
}

# ════════════════════════════════════════════════════════════
#  СОЗДАТЬ ГРУППУ
# ════════════════════════════════════════════════════════════
cmd_add_group() {
    echo ""
    echo -e "  ${GREEN}${BOLD}Sing-box → Создание группы${RESET}"
    echo -e "  ${GREEN}--------------------------------------------------------${RESET}"


    local vless_tags
    vless_tags=$(jq -r '.outbounds[] | select(.type == "vless") | .tag' "$SINGBOX_CONFIG")
    if [ -z "$vless_tags" ]; then
        echo ""
        err "Нет VLESS-серверов. Сначала добавьте сервер."; return
    fi

    echo ""
    echo -e "  ${CYAN}VLESS-серверы:${RESET}"
    declare -a tag_arr=()
    print_vless_servers_list tag_arr

    echo ""
    read -p "  Введите тег группы (Enter — отмена): " group_tag
    [ -z "$group_tag" ] && return

    if jq -e --arg t "$group_tag" '.outbounds[] | select(.tag == $t)' "$SINGBOX_CONFIG" >/dev/null 2>&1; then
        warn "Группа '$group_tag' будет пересоздана"
    fi

    echo ""
    echo -e "  ${CYAN}Тип группы:${RESET}"
    echo -e "    ${WHITE}1 urltest   — автовыбор лучшего + failover${RESET}"
    echo -e "    ${WHITE}2 selector  — ручной выбор${RESET}"
    echo ""
    read -p "  Выбор (Enter — отмена): " type_ch
    [ -z "$type_ch" ] && return
    local group_type
    case "$type_ch" in 1) group_type="urltest";; 2) group_type="selector";; *) err "Неверно"; return;; esac

    echo ""
    read -p "  Укажите номера серверов через пробел (Enter — все серверы): " sel
    sel=${sel:-all}
    declare -a selected=()
    if [ "$sel" = "all" ]; then
        selected=("${tag_arr[@]}")
    else
        for num in $sel; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#tag_arr[@]}" ]; then
                selected+=("${tag_arr[$((num-1))]}")
            else err "Неверный номер: $num"; return; fi
        done
    fi
    [ "${#selected[@]}" -eq 0 ] && { err "Не выбрано серверов"; return; }

    local sel_json health_url="https://www.gstatic.com/generate_204" health_int="3m" health_tol=50
    sel_json=$(printf '%s\n' "${selected[@]}" | jq -R . | jq -s .)

    if [ "$group_type" = "urltest" ]; then
        echo ""
        echo -e "  ${BOLD}Проверка доступности узлов (urltest)${RESET}"
        echo -e "  ${DIM}Sing-box периодически открывает URL через каждый сервер и мерит задержку (RTT).${RESET}"
        echo -e "  ${DIM}Интервал: ${WHITE}30s${DIM}, ${WHITE}3m${DIM}, ${WHITE}1h${DIM} — или только число (= минуты). Tolerance, мс — не переключать узел, если разница RTT меньше порога (анти-дрожание).${RESET}"
        echo ""
        read -p "  URL для замера (Enter — встроенный по умолчанию): " inp; health_url=${inp:-$health_url}
        read -p "  Интервал между проверками [${health_int}]: " inp; health_int=${inp:-$health_int}
        [[ "$health_int" =~ ^[0-9]+$ ]] && health_int="${health_int}m"
        read -p "  Допуск задержки, мс [${health_tol}]: " inp; health_tol=${inp:-$health_tol}
    fi

    echo ""
    read -p "  Proxy-in → '$group_tag'? [Y/n]: " use_proxy; use_proxy=${use_proxy:-Y}
    read -p "  VPN DNS detour → '$group_tag'? [Y/n]: " use_dns; use_dns=${use_dns:-Y}

    draw_section "Подтверждение"
    printf "  %-16s %s\n" "Тег:" "$group_tag"
    printf "  %-16s %s\n" "Тип:" "$group_type"
    printf "  %-16s %s\n" "Серверы:" "${selected[*]}"
    echo ""

    read -p "  Создать? [Y/n]: " confirm; confirm=${confirm:-Y}
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "  Отменено."; return; }

    backup_config

    local group_obj config
    if [ "$group_type" = "urltest" ]; then
        group_obj=$(jq -n --arg tag "$group_tag" --argjson ob "$sel_json" \
            --arg url "$health_url" --arg int "$health_int" --argjson tol "$health_tol" \
            '{type:"urltest",tag:$tag,outbounds:$ob,url:$url,interval:$int,tolerance:$tol}')
    else
        group_obj=$(jq -n --arg tag "$group_tag" --argjson ob "$sel_json" \
            '{type:"selector",tag:$tag,outbounds:$ob}')
    fi

    config=$(cat "$SINGBOX_CONFIG")
    config=$(echo "$config" | jq --arg tag "$group_tag" '.outbounds |= map(select(.tag != $tag))')
    config=$(echo "$config" | jq --argjson new "$group_obj" '
        .outbounds as $ob |
        ($ob | to_entries | map(select(.value.type == "direct" or .value.type == "block" or .value.type == "dns")) | .[0].key // ($ob | length)) as $pos |
        .outbounds = ($ob[:$pos] + [$new] + $ob[$pos:])
    ')

    if [[ "$use_proxy" =~ ^[Yy]$ ]]; then
        config=$(echo "$config" | jq '.route.rules |= map(select(.inbound != ["proxy-in"]))')
        config=$(echo "$config" | jq --arg tag "$group_tag" '
            .route.rules as $r |
            ($r | to_entries | map(select(.value.action != null)) | .[-1].key // -1) as $pos |
            .route.rules = ($r[:$pos+1] + [{inbound:["proxy-in"],outbound:$tag}] + $r[$pos+1:])
        ')
        ok "Proxy-in → $group_tag"
    fi

    if [[ "$use_dns" =~ ^[Yy]$ ]]; then
        config=$(echo "$config" | jq --arg tag "$group_tag" '
            .dns.servers |= map(if .tag == "dns-vpn" then .detour = $tag else . end)
        ')
        ok "DNS VPN detour → $group_tag"
    fi

    write_config "$config"
    ok "Группа '$group_tag' создана"
    echo ""
    offer_apply_inline
}

# ════════════════════════════════════════════════════════════
#  ДОБАВИТЬ ПРАВИЛО
# ════════════════════════════════════════════════════════════
cmd_add_rule() {
    
    echo ""
    echo -e "  ${GREEN}${BOLD}Sing-box → Маршрутизация → Добавить правило${RESET}"
    echo -e "  ${GREEN}--------------------------------------------------------${RESET}"
    echo ""
    echo -e "  ${WHITE}${BOLD}Тип правила:${RESET}"
    echo ""
    echo -e "    ${CYAN}Ручные (высший приоритет):${RESET}"
    echo -e "     ${WHITE}1 domain          точное совпадение${RESET}"
    echo -e "     ${WHITE}2 domain_suffix   суффикс (*.example.com)${RESET}"
    echo -e "     ${WHITE}3 domain_keyword  ключевое слово${RESET}"
    echo -e "     ${WHITE}4 ip_cidr         подсеть IP${RESET}"
    echo ""
    echo -e "    ${CYAN}Rule-set (community списки):${RESET}"
    echo -e "     ${WHITE}5 geosite         категория (youtube, google...)${RESET}"
    echo -e "     ${WHITE}6 geoip           страна по IP (ru, us...)${RESET}"
    echo ""
    read -p "  > " rule_ch
    [ -z "$rule_ch" ] && return

    local rule_type="" is_ruleset=0
    case "$rule_ch" in
        1) rule_type="domain";; 2) rule_type="domain_suffix";;
        3) rule_type="domain_keyword";; 4) rule_type="ip_cidr";;
        5) rule_type="geosite"; is_ruleset=1;; 6) rule_type="geoip"; is_ruleset=1;;
        *) err "Неверный выбор"; return;;
    esac

    local rule_value="" ruleset_tag="" ruleset_url=""

    if [ "$rule_type" = "geosite" ]; then
        echo ""
        echo -e "  ${CYAN}Категории geosite:${RESET}"
        echo -e "     ${WHITE}1 youtube      9 telegram    17 spotify${RESET}"
        echo -e "     ${WHITE}2 google      10 whatsapp    18 twitch${RESET}"
        echo -e "     ${WHITE}3 facebook    11 tiktok      19 github${RESET}"
        echo -e "     ${WHITE}4 instagram   12 netflix     20 stackoverflow${RESET}"
        echo -e "     ${WHITE}5 twitter     13 openai      21 reddit${RESET}"
        echo -e "     ${WHITE}6 amazon      14 discord     22 linkedin${RESET}"
        echo -e "     ${WHITE}7 microsoft   15 steam       23 wikipedia${RESET}"
        echo -e "     ${WHITE}8 apple       16 paypal      24 другое (ввести вручную)${RESET}"
        echo ""
        echo -e "  ${DIM}Полный список: github.com/SagerNet/sing-geosite/tree/rule-set${RESET}"
        echo ""
        read -p "  > " gc
        [ -z "$gc" ] && return
        case "$gc" in
            1)  rule_value="youtube";;       2)  rule_value="google";;
            3)  rule_value="facebook";;      4)  rule_value="instagram";;
            5)  rule_value="twitter";;       6)  rule_value="amazon";;
            7)  rule_value="microsoft";;     8)  rule_value="apple";;
            9)  rule_value="telegram";;      10) rule_value="whatsapp";;
            11) rule_value="tiktok";;        12) rule_value="netflix";;
            13) rule_value="openai";;        14) rule_value="discord";;
            15) rule_value="steam";;         16) rule_value="paypal";;
            17) rule_value="spotify";;       18) rule_value="twitch";;
            19) rule_value="github";;        20) rule_value="stackoverflow";;
            21) rule_value="reddit";;        22) rule_value="linkedin";;
            23) rule_value="wikipedia";;
            24) read -p "  Имя категории: " rule_value;;
            *) err "Неверно"; return;;
        esac
        ruleset_tag="geosite-${rule_value}"
        ruleset_url="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-${rule_value}.srs"
    elif [ "$rule_type" = "geoip" ]; then
        echo ""
        echo "  Страны geoip:"
        echo "     1) ru — Россия       5) nl — Нидерланды"
        echo "     2) us — США          6) jp — Япония"
        echo "     3) de — Германия     7) ua — Украина"
        echo "     4) cn — Китай        8) другое (ввести код)"
        echo ""
        echo -e "  ${DIM}Полный список: github.com/SagerNet/sing-geoip${RESET}"
        echo ""
        read -p "  Выбор [8]: " gc; gc=${gc:-8}
        case "$gc" in
            1) rule_value="ru";; 2) rule_value="us";; 3) rule_value="de";;
            4) rule_value="cn";; 5) rule_value="nl";; 6) rule_value="jp";;
            7) rule_value="ua";;
            8) read -p "  Код страны (2 буквы): " rule_value; rule_value=$(echo "$rule_value" | tr '[:upper:]' '[:lower:]');;
            *) err "Неверно"; return;;
        esac
        ruleset_tag="geoip-${rule_value}"
        ruleset_url="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-${rule_value}.srs"
    else
        echo ""
        case "$rule_type" in
            domain)         read -p "  Домен — полное совпадение имени (напр. youtube.com): " rule_value;;
            domain_suffix)  read -p "  Суффикс — хост оканчивается на него, со всех поддоменов (напр. google.com): " rule_value;;
            domain_keyword) read -p "  Ключевое слово — если оно есть в имени хоста (напр. google): " rule_value;;
            ip_cidr)        read -p "  IP или подсеть в нотации CIDR (напр. 192.168.1.0/24 или 10.0.0.5): " rule_value;;
        esac
    fi
    [ -z "$rule_value" ] && { err "Значение пусто"; return; }

    # Выбор outbound
    echo ""
    echo -e "  ${GREEN}Доступные outbound-подключения:${RESET}"
    local outbounds i=1
    outbounds=$(jq -r '.outbounds[] | select(.type != "dns") | .tag' "$SINGBOX_CONFIG")
    declare -a ob_arr=()
    while IFS= read -r ob; do
        ob_arr+=("$ob")
        local ob_type
        ob_type=$(jq -r --arg t "$ob" '.outbounds[] | select(.tag == $t) | .type' "$SINGBOX_CONFIG")
        printf "    ${WHITE}%d  [%s] %s${RESET}\n" "$i" "$ob_type" "$ob"
        i=$((i + 1))
    done <<< "$outbounds"
    echo ""
    read -p "  > " ob_num
    [ -z "$ob_num" ] && return
    if ! [[ "$ob_num" =~ ^[0-9]+$ ]] || [ "$ob_num" -lt 1 ] || [ "$ob_num" -gt "${#ob_arr[@]}" ]; then
        err "Неверный номер"; return
    fi
    local target="${ob_arr[$((ob_num-1))]}"

    local dns_mirror=0
    local target_type
    target_type=$(jq -r --arg t "$target" '.outbounds[] | select(.tag == $t) | .type' "$SINGBOX_CONFIG")
    [ "$target_type" != "direct" ] && [ "$target_type" != "block" ] && dns_mirror=1

    
    echo -e ""
    echo -e "  ${YELLOW}${BOLD}Подтвердите действие${RESET}"
    echo -e "  ${YELLOW}--------------------------------------------------------${RESET}"

    if [ "$is_ruleset" -eq 1 ]; then
        printf "    ${WHITE}Тип:       rule-set (%s)${RESET}\n" "$rule_type"
        printf "    ${WHITE}Категория: %s${RESET}\n" "$rule_value"
    else
        printf "    ${WHITE}Тип:       manual (%s)${RESET}\n" "$rule_type"
        printf "    ${WHITE}Значение:  %s${RESET}\n" "$rule_value"
    fi
    printf "    ${WHITE}Outbound:  %s${RESET}\n" "$target"
    [ "$dns_mirror" -eq 1 ] && printf "    ${WHITE}DNS:       → dns-vpn (авто)${RESET}\n"
    echo ""

    read -p "  Добавить правило? [Y/n]: " confirm; confirm=${confirm:-Y}
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "  Отменено."; return; }
    echo ""

    backup_config
    local config
    config=$(cat "$SINGBOX_CONFIG")

    if [ "$is_ruleset" -eq 1 ]; then
        if ! echo "$config" | jq -e --arg tag "$ruleset_tag" '.route.rule_set[]? | select(.tag == $tag)' >/dev/null 2>&1; then
            config=$(echo "$config" | jq --arg tag "$ruleset_tag" --arg url "$ruleset_url" '
                .route.rule_set += [{type:"remote",tag:$tag,format:"binary",url:$url,download_detour:"direct",update_interval:"72h"}]
            ')
            ok "Rule-set '$ruleset_tag' добавлен"
        fi
        if ! echo "$config" | jq -e --arg rs "$ruleset_tag" --arg ob "$target" \
            '.route.rules[] | select(.rule_set? == [$rs] and .outbound == $ob)' >/dev/null 2>&1; then
            config=$(echo "$config" | jq --arg rs "$ruleset_tag" --arg ob "$target" \
                '.route.rules += [{rule_set:[$rs],outbound:$ob}]')
        fi
        if [ "$dns_mirror" -eq 1 ]; then
            if ! echo "$config" | jq -e --arg rs "$ruleset_tag" '.dns.rules[]? | select(.rule_set? == [$rs])' >/dev/null 2>&1; then
                config=$(echo "$config" | jq --arg rs "$ruleset_tag" '.dns.rules += [{rule_set:[$rs],server:"dns-vpn"}]')
                ok "DNS-правило для '$ruleset_tag' добавлено"
            fi
        fi
    else
        local new_rule
        new_rule=$(jq -n --arg type "$rule_type" --arg val "$rule_value" --arg ob "$target" \
            '{($type):[$val],outbound:$ob}')
        config=$(echo "$config" | jq --argjson new "$new_rule" '
            .route.rules as $r |
            ($r | to_entries | map(select(.value.rule_set != null)) | .[0].key // ($r | length)) as $pos |
            .route.rules = ($r[:$pos] + [$new] + $r[$pos:])
        ')
        if [ "$dns_mirror" -eq 1 ]; then
            local dns_rule
            dns_rule=$(jq -n --arg type "$rule_type" --arg val "$rule_value" '{($type):[$val],server:"dns-vpn"}')
            config=$(echo "$config" | jq --argjson new "$dns_rule" '.dns.rules += [$new]')
            ok "DNS-правило добавлено"
        fi
    fi

    write_config "$config"
    ok "Правило: $rule_type:$rule_value → $target"
    echo ""
}

# ════════════════════════════════════════════════════════════
#  МАРШРУТИЗАЦИЯ (подменю)
# ════════════════════════════════════════════════════════════
cmd_routing() {
    local changed=0

    while true; do
        echo ""
        echo -e "  ${GREEN}${BOLD}Sing-box → Маршрутизация${RESET}"
        echo -e "  ${GREEN}--------------------------------------------------------${RESET}"

        print_user_rules

        [ "$_UR_COUNT" -eq 0 ] && echo "   (нет правил)"

        echo ""
        echo -e "  ${CYAN}[Действия]${RESET}"
        echo -e "    ${WHITE}1  Добавить правило     2  Изменить правило     3  Удалить правило${RESET}"
        echo -e "    ${WHITE}4  Изменить активность  5  Переместить правило  0  Назад${RESET}"
        echo ""
        read -p "  > " act

        case "$act" in
        1) # ── Добавить правило ──
            cmd_add_rule
            changed=1
            ;;

        3) # ── Удалить правило ──
            [ "$_UR_COUNT" -eq 0 ] && { warn "Нет правил"; continue; }
            echo ""
            read -p "  Выберите номер правила: " num
            [ -z "$num" ] || [ "$num" = "0" ] && continue
            if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$_UR_COUNT" ]; then
                echo ""
                err "Неверный номер"; continue
            fi

            local del_idx="${_UR_INDICES[$((num-1))]}"
            local del_key="${_UR_KEYS[$((num-1))]}"
            local del_rule
            del_rule=$(jq -c ".route.rules[$del_idx]" "$SINGBOX_CONFIG")

            backup_config
            local config
            config=$(jq --argjson idx "$del_idx" '.route.rules |= .[:$idx] + .[$idx+1:]' "$SINGBOX_CONFIG")
            config=$(delete_dns_mirror "$del_rule" "$config")

            if [ -n "$del_key" ] && is_rule_disabled "$del_key"; then
                jq --arg k "$del_key" 'del(.[$k])' "$DISABLED_RULES_FILE" > "${DISABLED_RULES_FILE}.tmp"
                mv "${DISABLED_RULES_FILE}.tmp" "$DISABLED_RULES_FILE"
            fi

            write_config "$config"
            echo ""
            ok "Правило удалено"
            changed=1
            ;;

        4) # ── Вкл/выкл ──
            [ "$_UR_COUNT" -eq 0 ] && { warn "Нет правил"; continue; }
            echo ""
            read -p "  Выберите номер правила: " num
            [ "$num" = "0" ] && continue
            if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$_UR_COUNT" ]; then
                echo ""
                err "Неверный номер"; continue
            fi

            local tog_idx="${_UR_INDICES[$((num-1))]}"
            local tog_key="${_UR_KEYS[$((num-1))]}"
            [ -z "$tog_key" ] && { echo ""; err "Правило без ключа"; continue; }

            local tog_rule
            tog_rule=$(jq -c ".route.rules[$tog_idx]" "$SINGBOX_CONFIG")
            local tog_outbound
            tog_outbound=$(echo "$tog_rule" | jq -r '.outbound')

            backup_config
            local config
            config=$(cat "$SINGBOX_CONFIG")

            if is_rule_disabled "$tog_key"; then
                local orig_outbound
                orig_outbound=$(jq -r --arg k "$tog_key" '.[$k]' "$DISABLED_RULES_FILE")
                config=$(echo "$config" | jq --argjson idx "$tog_idx" --arg ob "$orig_outbound" \
                    '.route.rules[$idx].outbound = $ob')
                config=$(switch_dns_mirror "$tog_rule" "dns-vpn" "$config")
                jq --arg k "$tog_key" 'del(.[$k])' "$DISABLED_RULES_FILE" > "${DISABLED_RULES_FILE}.tmp"
                mv "${DISABLED_RULES_FILE}.tmp" "$DISABLED_RULES_FILE"
                write_config "$config"
                echo ""
                ok "Включено: $tog_key -> $orig_outbound"
            else
                jq --arg k "$tog_key" --arg v "$tog_outbound" '. + {($k): $v}' \
                    "$DISABLED_RULES_FILE" > "${DISABLED_RULES_FILE}.tmp"
                mv "${DISABLED_RULES_FILE}.tmp" "$DISABLED_RULES_FILE"
                config=$(echo "$config" | jq --argjson idx "$tog_idx" \
                    '.route.rules[$idx].outbound = "direct"')
                config=$(switch_dns_mirror "$tog_rule" "dns-direct" "$config")
                write_config "$config"
                echo ""
                ok "Отключено: $tog_key -> direct (было: $tog_outbound)"
            fi
            changed=1
            ;;

        5) # ── Переместить ──
            [ "$_UR_COUNT" -lt 2 ] && { warn "Недостаточно правил"; continue; }
            echo ""
            read -p "  Выберите номер правила: " src_num
            if ! [[ "$src_num" =~ ^[0-9]+$ ]] || [ "$src_num" -lt 1 ] || [ "$src_num" -gt "$_UR_COUNT" ]; then
                echo ""
                err "Неверный номер"; continue
            fi
            read -p "  Укажите позицию для перемещения (1-${_UR_COUNT}): " tgt_num
            if ! [[ "$tgt_num" =~ ^[0-9]+$ ]] || [ "$tgt_num" -lt 1 ] || [ "$tgt_num" -gt "$_UR_COUNT" ]; then
                echo ""
                err "Неверная позиция"; continue
            fi
            [ "$src_num" -eq "$tgt_num" ] && { info "Позиция не изменилась"; continue; }

            local src_abs="${_UR_INDICES[$((src_num-1))]}"

            backup_config
            local config rule_json
            rule_json=$(jq -c ".route.rules[$src_abs]" "$SINGBOX_CONFIG")
            config=$(jq --argjson idx "$src_abs" \
                '.route.rules |= .[:$idx] + .[$idx+1:]' "$SINGBOX_CONFIG")

            local new_count new_ur=0 insert_abs
            new_count=$(echo "$config" | jq '.route.rules | length')
            insert_abs=$new_count
            for ((ni=0; ni<new_count; ni++)); do
                local nr na
                nr=$(echo "$config" | jq -c ".route.rules[$ni]")
                na=$(echo "$nr" | jq -r '.action // empty')
                [ -n "$na" ] && [ "$na" != "route" ] && continue
                echo "$nr" | jq -e '.inbound' >/dev/null 2>&1 && continue
                new_ur=$((new_ur + 1))
                if [ "$new_ur" -eq "$tgt_num" ]; then
                    insert_abs=$ni; break
                fi
            done

            config=$(echo "$config" | jq --argjson idx "$insert_abs" --argjson rule "$rule_json" \
                '.route.rules |= .[:$idx] + [$rule] + .[$idx:]')
            write_config "$config"
            echo ""
            ok "Правило перемещено на позицию: $tgt_num"
            changed=1
            ;;

        2) # ── Изменить outbound ──
            [ "$_UR_COUNT" -eq 0 ] && { warn "Нет правил"; continue; }
            echo ""
            read -p "  Выберите номер правила: " num
            [ "$num" = "0" ] && continue
            if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$_UR_COUNT" ]; then
                continue
            fi

            local edit_idx="${_UR_INDICES[$((num-1))]}"
            local edit_key="${_UR_KEYS[$((num-1))]}"
            local edit_rule old_outbound
            edit_rule=$(jq -c ".route.rules[$edit_idx]" "$SINGBOX_CONFIG")
            old_outbound=$(echo "$edit_rule" | jq -r '.outbound')
            echo ""
            echo -e "  ${GREEN}Доступные outbound-подключения:${RESET}"
            local outbounds oi=1
            outbounds=$(jq -r '.outbounds[] | select(.type != "dns") | .tag' "$SINGBOX_CONFIG")
            declare -a ob_arr=()
            while IFS= read -r ob; do
                ob_arr+=("$ob")
                local ob_type
                ob_type=$(jq -r --arg t "$ob" '.outbounds[] | select(.tag == $t) | .type' "$SINGBOX_CONFIG")
                printf "    ${WHITE}%d  [%s] %s${RESET}\n" "$oi" "$ob_type" "$ob"
                oi=$((oi + 1))
            done <<< "$outbounds"

            echo ""
            read -p "  > " ob_num
            if ! [[ "$ob_num" =~ ^[0-9]+$ ]] || [ "$ob_num" -lt 1 ] || [ "$ob_num" -gt "${#ob_arr[@]}" ]; then
                err "Неверный номер"; continue
            fi
            local new_outbound="${ob_arr[$((ob_num-1))]}"

            local new_ob_type new_dns_server="dns-vpn"
            new_ob_type=$(jq -r --arg t "$new_outbound" '.outbounds[] | select(.tag == $t) | .type' "$SINGBOX_CONFIG")
            [ "$new_ob_type" = "direct" ] || [ "$new_ob_type" = "block" ] && new_dns_server="dns-direct"

            backup_config

            if [ -n "$edit_key" ] && is_rule_disabled "$edit_key"; then
                jq --arg k "$edit_key" --arg v "$new_outbound" '.[$k] = $v' \
                    "$DISABLED_RULES_FILE" > "${DISABLED_RULES_FILE}.tmp"
                mv "${DISABLED_RULES_FILE}.tmp" "$DISABLED_RULES_FILE"
                echo ""
                ok "Outbound изменён (при включении будет: $new_outbound)"
            else
                local config
                config=$(cat "$SINGBOX_CONFIG")
                config=$(echo "$config" | jq --argjson idx "$edit_idx" --arg ob "$new_outbound" \
                    '.route.rules[$idx].outbound = $ob')
                config=$(switch_dns_mirror "$edit_rule" "$new_dns_server" "$config")
                write_config "$config"
                echo ""
                ok "Outbound: $old_outbound -> $new_outbound"
            fi
            changed=1
            ;;

        0|q|"")
            if [ "$changed" -eq 1 ]; then
                echo ""
                offer_apply_inline
            fi
            break
            ;;
        *) warn "Неверный выбор" ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#  ПРИМЕНИТЬ
# ════════════════════════════════════════════════════════════
cmd_apply() {
    draw_header "Применить конфигурацию" "$GREEN"
    echo ""
    apply_config
    sleep 1
    if ip link show tun0 &>/dev/null; then
        ok "tun0 — UP"
    else
        warn "tun0 — не найден"
    fi
    echo ""
}

offer_apply_inline() {
    read -p "  Применить сейчас? [Y/n]: " a; a=${a:-Y}
    if [[ "$a" =~ ^[Yy]$ ]]; then
        echo ""
        apply_config
    else
        info "Для применения: выберите пункт 5 в меню"
    fi
}

# ════════════════════════════════════════════════════════════
#  УДАЛИТЬ СЕРВЕР / ГРУППУ
# ════════════════════════════════════════════════════════════
cmd_delete_outbound() {
    draw_header "Удалить сервер / группу" "$RED"

    local custom_obs
    custom_obs=$(jq -r '.outbounds[] | select(.type != "direct" and .type != "block" and .type != "dns") | .tag' "$SINGBOX_CONFIG")
    if [ -z "$custom_obs" ]; then
        warn "Нет серверов/групп для удаления"; return
    fi

    echo ""
    local i=1
    declare -a del_arr=()
    while IFS= read -r tag; do
        del_arr+=("$tag")
        local ob_type
        ob_type=$(jq -r --arg t "$tag" '.outbounds[] | select(.tag == $t) | .type' "$SINGBOX_CONFIG")
        print_item "$i" "$ob_type" "$tag" ""
        i=$((i + 1))
    done <<< "$custom_obs"
    echo ""
    read -p "  Номер для удаления (0 — отмена): " num
    [ "$num" = "0" ] && return
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#del_arr[@]}" ]; then
        err "Неверный номер"; return
    fi

    local del_tag="${del_arr[$((num-1))]}"
    echo ""
    read -p "  Удалить '$del_tag'? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "  Отменено."; return; }

    backup_config
    local config
    config=$(cat "$SINGBOX_CONFIG")
    # Удалить сам outbound
    config=$(echo "$config" | jq --arg tag "$del_tag" '.outbounds |= map(select(.tag != $tag))')
    # Удалить из списков участников других групп
    config=$(echo "$config" | jq --arg tag "$del_tag" '
        .outbounds |= map(if .outbounds then .outbounds |= map(select(. != $tag)) else . end)
    ')
    # Удалить правила маршрутизации, ссылающиеся на этот outbound
    config=$(echo "$config" | jq --arg tag "$del_tag" '
        .route.rules |= map(select(.outbound != $tag))
    ')
    # Удалить detour из DNS-серверов, ссылающихся на этот outbound
    config=$(echo "$config" | jq --arg tag "$del_tag" '
        .dns.servers |= map(if .detour == $tag then del(.detour) else . end)
    ')

    write_config "$config"
    ok "'$del_tag' удалён"
    echo ""
    offer_apply_inline
}

# ════════════════════════════════════════════════════════════
#  ОБНОВЛЕНИЕ СКРИПТОВ
# ════════════════════════════════════════════════════════════
cmd_update_scripts() {
    local repo_dir="$HOME/nanopi-router"
    echo ""
    echo -e "  ${YELLOW}${BOLD}Обновление скриптов из Git...${RESET}"
    echo ""
    cd "$repo_dir" || { err "Каталог $repo_dir не найден"; return; }
    git reset --hard
    git pull
    chmod +x scripts/*.sh *.sh
    echo ""
    ok "Скрипты обновлены. Перезапуск..."
    exec sudo "$repo_dir/singbox.sh"
}

# ════════════════════════════════════════════════════════════
#  ГЛАВНОЕ МЕНЮ
# ════════════════════════════════════════════════════════════
main_menu() {
    check_root
    check_singbox
    check_jq

    while true; do
        local svc_label svc_color ver tun_label tun_color

        if systemctl is-active --quiet sing-box 2>/dev/null; then
            svc_label="active";  svc_color="${GREEN}"
        else
            svc_label="inactive"; svc_color="${RED}"
        fi

        ver=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | awk '{print $NF}' || echo "?")

        if ip link show tun0 &>/dev/null; then
            tun_label="UP";   tun_color="${GREEN}"
        else
            tun_label="DOWN"; tun_color="${RED}"
        fi

        echo ""
        echo -e "  ${GREEN}${BOLD}Sing-box Управление${RESET}"
        echo -e "  ${GREEN}--------------------------------------------------------${RESET}"
        echo -e "   ${GREEN}● ${WHITE}service: ${GREEN}${svc_label}${RESET}   |   ${WHITE}version: v${ver}${RESET}   |   ${WHITE}TUN: ${GREEN}${tun_label}${RESET}"
        echo ""
        echo -e "  ${CYAN}[Просмотр]${RESET}"
        echo -e "    ${WHITE}1  Статус${RESET}"
        echo ""
        echo -e "  ${CYAN}[Настройка]${RESET}"
        echo -e "    ${WHITE}2  Добавить сервер      VLESS${RESET}"
        echo -e "    ${WHITE}3  Создать группу       urltest / selector${RESET}"
        echo -e "    ${WHITE}4  Маршрутизация        правила трафика${RESET}"
        echo -e "    ${WHITE}5  Применить            проверка и перезапуск${RESET}"
        echo ""
        echo -e "  ${CYAN}[Удаление]${RESET}"
        echo -e "    ${WHITE}6  Удалить сервер/группу${RESET}"
        echo ""
        echo -e "  ${CYAN}[Другое]${RESET}"
        echo -e "    ${WHITE}7  Обновить скрипты${RESET}"
        echo ""
        echo -e "    ${WHITE}0  Выход${RESET}"
        echo ""
        read -p "  > " choice

        case "$choice" in
            1) cmd_status ;;
            2) cmd_add_vless ;;
            3) cmd_add_group ;;
            4) cmd_routing ;;
            5) cmd_apply ;;
            6) cmd_delete_outbound ;;
            7) cmd_update_scripts ;;
            0|q|"") echo ""; break ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

# Запуск с аргументом или интерактивно
case "${1:-}" in
    status)  check_root; check_singbox; check_jq; cmd_status ;;
    apply)   check_root; check_singbox; check_jq; cmd_apply ;;
    *)       main_menu ;;
esac
