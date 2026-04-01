#!/bin/bash
# ============================================================
#  NanoPi R5S — Установка / удаление Telegram-бота
# ============================================================
#  install   — установить бота, запросить токен, автозапуск
#  uninstall — остановить, убрать автозапуск, очистить данные
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/singbox-common.sh"

BOT_DIR="/opt/nanopi-bot"
BOT_CONFIG_DIR="/etc/nanopi-bot"
BOT_CONFIG="$BOT_CONFIG_DIR/config.json"
SERVICE_NAME="nanopi-bot"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

check_root

# ── Установка ──────────────────────────────────────────────────
do_install() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║   NanoPi R5S — Telegram Bot Installation      ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    # ── Python ─────────────────────────────────────────────────
    NEED_PY=0
    for pkg in python3 python3-pip python3-venv; do
        dpkg -s "$pkg" &>/dev/null || NEED_PY=1
    done

    if [ "$NEED_PY" -eq 1 ]; then
        info "Установка python3, pip, venv..."
        apt-get update -qq
        apt-get install -y python3 python3-pip python3-venv
    fi
    ok "Python3 установлен ($(python3 --version 2>&1))"

    # ── Токен ──────────────────────────────────────────────────
    TOKEN=""
    if [ -f "$BOT_CONFIG" ]; then
        CURRENT_TOKEN=$(python3 -c "
import json, sys
try:
    t = json.load(open('$BOT_CONFIG')).get('token','')
    print(t if t else '')
except: print('')
" 2>/dev/null || echo "")
        if [ -n "$CURRENT_TOKEN" ]; then
            MASKED="${CURRENT_TOKEN:0:6}...${CURRENT_TOKEN: -4}"
            warn "Токен уже настроен: $MASKED"
            read -p "  Заменить? [y/N]: " REPLACE
            if [[ "$REPLACE" =~ ^[Yy]$ ]]; then
                read -p "  Telegram Bot Token: " TOKEN
            else
                TOKEN="$CURRENT_TOKEN"
            fi
        fi
    fi

    if [ -z "$TOKEN" ]; then
        echo ""
        echo "  Создайте бота через @BotFather в Telegram"
        echo "  и вставьте полученный токен."
        echo ""
        read -p "  Telegram Bot Token: " TOKEN
    fi

    [ -z "$TOKEN" ] && { err "Токен не может быть пустым"; exit 1; }

    # ── Директории ─────────────────────────────────────────────
    mkdir -p "$BOT_DIR" "$BOT_CONFIG_DIR"

    # ── Виртуальное окружение ──────────────────────────────────
    if [ ! -d "$BOT_DIR/venv" ]; then
        info "Создание виртуального окружения..."
        python3 -m venv "$BOT_DIR/venv"
    fi
    info "Установка зависимостей..."
    "$BOT_DIR/venv/bin/pip" install --upgrade pip -q 2>/dev/null
    "$BOT_DIR/venv/bin/pip" install -r "$PROJECT_DIR/telegram-bot/requirements.txt" -q
    ok "Зависимости установлены"

    # ── Копирование файлов ─────────────────────────────────────
    cp "$PROJECT_DIR/telegram-bot/bot.py" "$BOT_DIR/"
    cp "$PROJECT_DIR/telegram-bot/singbox.py" "$BOT_DIR/"
    ok "Файлы бота скопированы → $BOT_DIR/"

    # ── Конфигурация ───────────────────────────────────────────
    ADMIN_ID="null"
    if [ -f "$BOT_CONFIG" ]; then
        ADMIN_ID=$(python3 -c "
import json
try: print(json.load(open('$BOT_CONFIG')).get('admin_id') or 'null')
except: print('null')
" 2>/dev/null || echo "null")
    fi

    cat > "$BOT_CONFIG" <<EOFCFG
{
  "token": "$TOKEN",
  "admin_id": $ADMIN_ID
}
EOFCFG
    chmod 600 "$BOT_CONFIG"
    ok "Конфигурация сохранена"

    # ── Systemd-сервис ─────────────────────────────────────────
    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=NanoPi R5S Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/nanopi-bot/venv/bin/python /opt/nanopi-bot/bot.py
WorkingDirectory=/opt/nanopi-bot
Restart=on-failure
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    ok "Systemd-сервис создан и включён"

    # ── Запуск ─────────────────────────────────────────────────
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "Перезапуск бота..."
        systemctl restart "$SERVICE_NAME"
    else
        info "Запуск бота..."
        systemctl start "$SERVICE_NAME"
    fi
    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "$SERVICE_NAME — активен"
    else
        warn "$SERVICE_NAME — не запустился!"
        journalctl -u "$SERVICE_NAME" --no-pager -n 10
    fi

    # ── Итог ───────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║       Telegram-бот установлен и запущен!      ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Напишите /start вашему боту в Telegram."
    echo "  Первый пользователь станет администратором."
    echo ""
    echo "  Управление сервисом:"
    echo "    sudo systemctl status  $SERVICE_NAME"
    echo "    sudo systemctl restart $SERVICE_NAME"
    echo "    sudo journalctl -u $SERVICE_NAME -f"
    echo ""
}

# ── Удаление ───────────────────────────────────────────────────
do_uninstall() {
    echo ""
    echo -e "${RED}${BOLD}  Удаление Telegram-бота${NC}"
    echo ""
    read -p "  Удалить бота и все настройки? [y/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo "  Отменено."; exit 0; }

    echo ""
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME"
        ok "Сервис остановлен"
    fi

    if [ -f "$SERVICE_FILE" ]; then
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        ok "Systemd-сервис удалён"
    fi

    if [ -d "$BOT_DIR" ]; then
        rm -rf "$BOT_DIR"
        ok "Файлы бота удалены ($BOT_DIR)"
    fi

    if [ -d "$BOT_CONFIG_DIR" ]; then
        rm -rf "$BOT_CONFIG_DIR"
        ok "Конфигурация удалена ($BOT_CONFIG_DIR)"
    fi

    echo ""
    ok "Telegram-бот полностью удалён"
    echo ""
}

# ── Обновление (переустановка без сброса конфига) ──────────────
do_update() {
    echo ""
    info "Обновление файлов бота..."

    mkdir -p "$BOT_DIR"
    cp "$PROJECT_DIR/telegram-bot/bot.py" "$BOT_DIR/"
    cp "$PROJECT_DIR/telegram-bot/singbox.py" "$BOT_DIR/"
    ok "Файлы обновлены"

    if [ -d "$BOT_DIR/venv" ]; then
        "$BOT_DIR/venv/bin/pip" install -r "$PROJECT_DIR/telegram-bot/requirements.txt" -q
        ok "Зависимости обновлены"
    fi

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl restart "$SERVICE_NAME"
        sleep 2
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            ok "Бот перезапущен"
        else
            warn "Бот не запустился!"
            journalctl -u "$SERVICE_NAME" --no-pager -n 10
        fi
    else
        warn "Бот не запущен. Запустите: sudo systemctl start $SERVICE_NAME"
    fi
    echo ""
}

# ── Точка входа ────────────────────────────────────────────────
case "${1:-}" in
    install)             do_install ;;
    uninstall|remove)    do_uninstall ;;
    update)              do_update ;;
    *)
        echo ""
        echo "  Использование: $0 {install|uninstall|update}"
        echo ""
        echo "    install    — установить и запустить бота"
        echo "    uninstall  — остановить и удалить бота"
        echo "    update     — обновить файлы без сброса настроек"
        echo ""
        exit 1
        ;;
esac
