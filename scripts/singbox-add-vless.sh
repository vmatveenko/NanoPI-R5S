#!/bin/bash
# ============================================================
#  sing-box — Добавление VLESS-подключения
# ============================================================
#  Поддерживает импорт из VLESS URI или ручной ввод параметров.
#  Поддерживает TLS, Reality, WebSocket, gRPC транспорт.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/singbox-common.sh"

check_root
check_singbox
check_jq

# ── Баннер ──────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}═══ sing-box: Добавить VLESS-подключение ═══${NC}"
echo ""

# ── Вспомогательные функции ─────────────────────────────────
urldecode() {
    local encoded="$1"
    printf '%b' "${encoded//%/\\x}"
}

# ── Переменные VLESS ────────────────────────────────────────
VLESS_TAG=""
VLESS_SERVER=""
VLESS_PORT=""
VLESS_UUID=""
VLESS_FLOW=""
VLESS_SECURITY="none"
VLESS_SNI=""
VLESS_FINGERPRINT="chrome"
VLESS_REALITY_PUBKEY=""
VLESS_REALITY_SHORTID=""
VLESS_TRANSPORT="tcp"
VLESS_WS_PATH=""
VLESS_WS_HOST=""
VLESS_GRPC_SERVICE=""
VLESS_ALPN=""

# ── Парсинг VLESS URI ──────────────────────────────────────
parse_vless_uri() {
    local uri="$1"
    uri="${uri#vless://}"

    if [[ "$uri" == *"#"* ]]; then
        VLESS_TAG=$(urldecode "${uri##*#}")
        uri="${uri%%#*}"
    fi

    VLESS_UUID="${uri%%@*}"
    uri="${uri#*@}"

    local hostport params=""
    if [[ "$uri" == *"?"* ]]; then
        hostport="${uri%%\?*}"
        params="${uri#*\?}"
    else
        hostport="$uri"
    fi

    if [[ "$hostport" == "["* ]]; then
        VLESS_SERVER="${hostport%%]*}"
        VLESS_SERVER="${VLESS_SERVER#[}"
        VLESS_PORT="${hostport##*]:}"
    else
        VLESS_SERVER="${hostport%%:*}"
        VLESS_PORT="${hostport##*:}"
    fi

    if [ -n "$params" ]; then
        IFS='&' read -ra PAIRS <<< "$params"
        for pair in "${PAIRS[@]}"; do
            local key="${pair%%=*}"
            local value
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
}

# ── Ручной ввод параметров ──────────────────────────────────
manual_input() {
    read -p "  Тег (имя подключения): " VLESS_TAG
    if [ -z "$VLESS_TAG" ]; then
        err "Тег не может быть пустым"
        exit 1
    fi

    read -p "  Адрес сервера: " VLESS_SERVER
    if [ -z "$VLESS_SERVER" ]; then
        err "Адрес не может быть пустым"
        exit 1
    fi

    read -p "  Порт [443]: " VLESS_PORT
    VLESS_PORT=${VLESS_PORT:-443}

    read -p "  UUID: " VLESS_UUID
    if [ -z "$VLESS_UUID" ]; then
        err "UUID не может быть пустым"
        exit 1
    fi

    read -p "  Flow (пусто / xtls-rprx-vision) []: " VLESS_FLOW

    echo ""
    echo "  Безопасность:"
    echo "    1) none"
    echo "    2) tls"
    echo "    3) reality"
    read -p "  Выбор [1]: " SEC_CHOICE
    SEC_CHOICE=${SEC_CHOICE:-1}
    case "$SEC_CHOICE" in
        1) VLESS_SECURITY="none" ;;
        2) VLESS_SECURITY="tls" ;;
        3) VLESS_SECURITY="reality" ;;
        *) err "Неверный выбор"; exit 1 ;;
    esac

    if [ "$VLESS_SECURITY" = "tls" ] || [ "$VLESS_SECURITY" = "reality" ]; then
        read -p "  SNI (server name): " VLESS_SNI
        read -p "  Fingerprint [chrome]: " VLESS_FINGERPRINT
        VLESS_FINGERPRINT=${VLESS_FINGERPRINT:-chrome}
        read -p "  ALPN (через запятую, пусто для пропуска) []: " VLESS_ALPN
    fi

    if [ "$VLESS_SECURITY" = "reality" ]; then
        read -p "  Reality public key: " VLESS_REALITY_PUBKEY
        if [ -z "$VLESS_REALITY_PUBKEY" ]; then
            err "Public key обязателен для Reality"
            exit 1
        fi
        read -p "  Reality short ID []: " VLESS_REALITY_SHORTID
    fi

    echo ""
    echo "  Транспорт:"
    echo "    1) tcp"
    echo "    2) ws (WebSocket)"
    echo "    3) grpc"
    read -p "  Выбор [1]: " TR_CHOICE
    TR_CHOICE=${TR_CHOICE:-1}
    case "$TR_CHOICE" in
        1) VLESS_TRANSPORT="tcp" ;;
        2) VLESS_TRANSPORT="ws"
           read -p "  WebSocket path [/]: " VLESS_WS_PATH
           VLESS_WS_PATH=${VLESS_WS_PATH:-/}
           read -p "  WebSocket host (пусто для пропуска): " VLESS_WS_HOST
           ;;
        3) VLESS_TRANSPORT="grpc"
           read -p "  gRPC service name [grpc]: " VLESS_GRPC_SERVICE
           VLESS_GRPC_SERVICE=${VLESS_GRPC_SERVICE:-grpc}
           ;;
        *) err "Неверный выбор"; exit 1 ;;
    esac
}

# ── Выбор способа ввода ─────────────────────────────────────
echo "  Способ добавления:"
echo "    1) Вставить VLESS URI (ссылка vless://...)"
echo "    2) Ввести параметры вручную"
read -p "  Выбор [1]: " INPUT_METHOD
INPUT_METHOD=${INPUT_METHOD:-1}

case "$INPUT_METHOD" in
    1)
        echo ""
        read -p "  Вставьте VLESS URI: " VLESS_URI
        if [[ ! "$VLESS_URI" == vless://* ]]; then
            err "URI должен начинаться с vless://"
            exit 1
        fi
        parse_vless_uri "$VLESS_URI"

        if [ -z "$VLESS_TAG" ]; then
            read -p "  Тег (имя подключения): " VLESS_TAG
        fi
        ;;
    2)
        echo ""
        manual_input
        ;;
    *)
        err "Неверный выбор"
        exit 1
        ;;
esac

# ── Валидация ───────────────────────────────────────────────
if [ -z "$VLESS_TAG" ] || [ -z "$VLESS_SERVER" ] || [ -z "$VLESS_PORT" ] || [ -z "$VLESS_UUID" ]; then
    err "Не все обязательные поля заполнены (тег, сервер, порт, UUID)"
    exit 1
fi

# Проверка дублей
if jq -e --arg tag "$VLESS_TAG" '.outbounds[] | select(.tag == $tag)' "$SINGBOX_CONFIG" >/dev/null 2>&1; then
    err "Outbound с тегом '$VLESS_TAG' уже существует"
    exit 1
fi

# ── Показ итога ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══ Новое подключение ═══${NC}"
echo "  Тег:        $VLESS_TAG"
echo "  Сервер:     $VLESS_SERVER:$VLESS_PORT"
echo "  UUID:       ${VLESS_UUID:0:8}...${VLESS_UUID: -4}"
[ -n "$VLESS_FLOW" ]       && echo "  Flow:       $VLESS_FLOW"
echo "  Security:   $VLESS_SECURITY"
[ -n "$VLESS_SNI" ]        && echo "  SNI:        $VLESS_SNI"
[ -n "$VLESS_FINGERPRINT" ] && echo "  Fingerprint: $VLESS_FINGERPRINT"
if [ "$VLESS_SECURITY" = "reality" ]; then
    echo "  Reality PK: ${VLESS_REALITY_PUBKEY:0:12}..."
    [ -n "$VLESS_REALITY_SHORTID" ] && echo "  Reality SID: $VLESS_REALITY_SHORTID"
fi
echo "  Транспорт:  $VLESS_TRANSPORT"
[ "$VLESS_TRANSPORT" = "ws" ]   && echo "  WS path:    $VLESS_WS_PATH"
[ "$VLESS_TRANSPORT" = "grpc" ] && echo "  gRPC svc:   $VLESS_GRPC_SERVICE"
echo ""

read -p "Добавить? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено."
    exit 0
fi

# ── Сборка JSON ─────────────────────────────────────────────
info "Создание outbound..."
backup_config

OUTBOUND=$(jq -n \
    --arg tag "$VLESS_TAG" \
    --arg server "$VLESS_SERVER" \
    --argjson port "$VLESS_PORT" \
    --arg uuid "$VLESS_UUID" \
    '{type: "vless", tag: $tag, server: $server, server_port: $port, uuid: $uuid}')

# Flow
if [ -n "$VLESS_FLOW" ]; then
    OUTBOUND=$(echo "$OUTBOUND" | jq --arg flow "$VLESS_FLOW" '. + {flow: $flow}')
fi

# TLS / Reality
if [ "$VLESS_SECURITY" = "tls" ] || [ "$VLESS_SECURITY" = "reality" ]; then
    TLS_OBJ=$(jq -n '{enabled: true}')

    if [ -n "$VLESS_SNI" ]; then
        TLS_OBJ=$(echo "$TLS_OBJ" | jq --arg sni "$VLESS_SNI" '. + {server_name: $sni}')
    fi

    if [ -n "$VLESS_FINGERPRINT" ]; then
        TLS_OBJ=$(echo "$TLS_OBJ" | jq --arg fp "$VLESS_FINGERPRINT" \
            '. + {utls: {enabled: true, fingerprint: $fp}}')
    fi

    if [ -n "$VLESS_ALPN" ]; then
        ALPN_ARR=$(echo "$VLESS_ALPN" | tr ',' '\n' | jq -R . | jq -s .)
        TLS_OBJ=$(echo "$TLS_OBJ" | jq --argjson alpn "$ALPN_ARR" '. + {alpn: $alpn}')
    fi

    if [ "$VLESS_SECURITY" = "reality" ]; then
        TLS_OBJ=$(echo "$TLS_OBJ" | jq \
            --arg pubkey "$VLESS_REALITY_PUBKEY" \
            --arg shortid "$VLESS_REALITY_SHORTID" \
            '. + {reality: {enabled: true, public_key: $pubkey, short_id: $shortid}}')
    fi

    OUTBOUND=$(echo "$OUTBOUND" | jq --argjson tls "$TLS_OBJ" '. + {tls: $tls}')
fi

# Transport
case "$VLESS_TRANSPORT" in
    ws)
        TR_OBJ=$(jq -n --arg path "${VLESS_WS_PATH:-/}" '{type: "ws", path: $path}')
        if [ -n "$VLESS_WS_HOST" ]; then
            TR_OBJ=$(echo "$TR_OBJ" | jq --arg host "$VLESS_WS_HOST" \
                '. + {headers: {Host: $host}}')
        fi
        OUTBOUND=$(echo "$OUTBOUND" | jq --argjson transport "$TR_OBJ" '. + {transport: $transport}')
        ;;
    grpc)
        TR_OBJ=$(jq -n --arg sn "${VLESS_GRPC_SERVICE:-grpc}" '{type: "grpc", service_name: $sn}')
        OUTBOUND=$(echo "$OUTBOUND" | jq --argjson transport "$TR_OBJ" '. + {transport: $transport}')
        ;;
esac

# ── Вставка в конфиг ───────────────────────────────────────
# Вставляем VLESS-outbound перед системными (direct, block, dns)
NEW_CONFIG=$(jq --argjson new "$OUTBOUND" '
    .outbounds as $ob |
    ($ob | to_entries | map(select(.value.type == "direct" or .value.type == "block" or .value.type == "dns")) | .[0].key // ($ob | length)) as $pos |
    .outbounds = ($ob[:$pos] + [$new] + $ob[$pos:])
' "$SINGBOX_CONFIG")

write_config "$NEW_CONFIG"
ok "VLESS-outbound '$VLESS_TAG' добавлен"

# ── Применение ──────────────────────────────────────────────
offer_apply
