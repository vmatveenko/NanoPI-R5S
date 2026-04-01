#!/usr/bin/env python3
"""NanoPi R5S — Telegram Management Bot.

First user to /start becomes the admin. All others are denied access.
"""

import json
import logging
import os
import subprocess
import asyncio
from functools import wraps
from html import escape as esc

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, CallbackQueryHandler,
    MessageHandler, filters, ContextTypes,
)
from telegram.constants import ParseMode

import singbox

# ── Configuration ──────────────────────────────────────────────

BOT_CONFIG = "/etc/nanopi-bot/config.json"

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    level=logging.INFO,
)
log = logging.getLogger("nanopi-bot")


def load_config() -> dict:
    with open(BOT_CONFIG) as f:
        return json.load(f)


def save_config(cfg: dict):
    with open(BOT_CONFIG, "w") as f:
        json.dump(cfg, f, indent=2)


# ── Async wrapper for blocking calls ──────────────────────────

async def run(func, *args, **kwargs):
    return await asyncio.to_thread(func, *args, **kwargs)


# ── Admin middleware ───────────────────────────────────────────

def admin_only(func):
    @wraps(func)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        uid = update.effective_user.id
        cfg = load_config()
        admin = cfg.get("admin_id")

        if admin is None:
            cfg["admin_id"] = uid
            save_config(cfg)
            log.info("Admin registered: %d (%s)", uid, update.effective_user.full_name)
        elif admin != uid:
            if update.callback_query:
                await update.callback_query.answer("Доступ запрещён", show_alert=True)
            else:
                await update.effective_message.reply_text("Доступ запрещён.")
            return

        return await func(update, context)
    return wrapper


# ── Keyboards ──────────────────────────────────────────────────

def kb_main():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("▸ sing-box — Прокси и VPN", callback_data="m:sb")],
        [InlineKeyboardButton("▸ Система", callback_data="m:sys")],
    ])


def kb_singbox():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("Статус", callback_data="sb:status"),
         InlineKeyboardButton("✓ Применить", callback_data="sb:apply")],
        [InlineKeyboardButton("+ Сервер", callback_data="sb:add_vless"),
         InlineKeyboardButton("+ Группа", callback_data="sb:add_group")],
        [InlineKeyboardButton("+ Правило", callback_data="sb:add_rule")],
        [InlineKeyboardButton("− Сервер/группа", callback_data="sb:del_ob"),
         InlineKeyboardButton("− Правило", callback_data="sb:del_rule")],
        [InlineKeyboardButton("◂ Назад", callback_data="m:back")],
    ])


def kb_back_sb():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("◂ sing-box", callback_data="sb:menu")],
    ])


def kb_after_change():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("✓ Применить", callback_data="sb:apply"),
         InlineKeyboardButton("◂ sing-box", callback_data="sb:menu")],
    ])


def kb_system():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("Информация", callback_data="sys:info")],
        [InlineKeyboardButton("Перезагрузка", callback_data="sys:reboot")],
        [InlineKeyboardButton("◂ Назад", callback_data="m:back")],
    ])


def kb_cancel():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("✕ Отмена", callback_data="cancel")],
    ])


# ═══════════════════════════════════════════════════════════════
#  COMMAND: /start
# ═══════════════════════════════════════════════════════════════

@admin_only
async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    ctx.user_data.clear()
    await update.message.reply_text(
        "◼ <b>NanoPi R5S</b>\n\nПанель управления.\nВыберите раздел.",
        parse_mode=ParseMode.HTML,
        reply_markup=kb_main(),
    )


# ═══════════════════════════════════════════════════════════════
#  CALLBACK ROUTER
# ═══════════════════════════════════════════════════════════════

@admin_only
async def on_callback(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    d = q.data

    # ── Navigation ─────────────────────────────────────────────
    if d == "m:sb":
        await q.answer(); await _show_sb_menu(q)
    elif d == "m:sys":
        await q.answer(); await _show_sys_menu(q)
    elif d == "m:back":
        await q.answer(); ctx.user_data.clear()
        await q.edit_message_text(
            "◼ <b>NanoPi R5S</b>\n\nПанель управления.\nВыберите раздел.",
            parse_mode=ParseMode.HTML, reply_markup=kb_main())

    elif d == "sb:menu":
        await q.answer(); ctx.user_data.pop("state", None)
        await _show_sb_menu(q)

    # ── sing-box: status / apply ───────────────────────────────
    elif d == "sb:status":
        await q.answer(); await _sb_status(q)
    elif d == "sb:apply":
        await q.answer(); await _sb_apply(q)

    # ── Add VLESS ──────────────────────────────────────────────
    elif d == "sb:add_vless":
        await q.answer(); await _vless_start(q, ctx)
    elif d == "vless:tpl":
        await q.answer(); await _vless_template(q, ctx)
    elif d == "vless:confirm":
        await q.answer(); await _vless_do(q, ctx, apply_after=False)
    elif d == "vless:apply":
        await q.answer(); await _vless_do(q, ctx, apply_after=True)

    # ── Add Group ──────────────────────────────────────────────
    elif d == "sb:add_group":
        await q.answer(); await _grp_start(q, ctx)
    elif d.startswith("grp:t:"):
        await q.answer(); await _grp_toggle(q, ctx, int(d[6:]))
    elif d == "grp:all":
        await q.answer(); await _grp_all(q, ctx)
    elif d == "grp:next":
        await q.answer(); await _grp_ask_tag(q, ctx)
    elif d.startswith("grp:type:"):
        await q.answer(); await _grp_set_type(q, ctx, d[9:])
    elif d == "grp:confirm":
        await q.answer(); await _grp_do(q, ctx)

    # ── Add Rule ───────────────────────────────────────────────
    elif d == "sb:add_rule":
        await q.answer(); await _rule_start(q, ctx)
    elif d.startswith("rule:t:"):
        await q.answer(); await _rule_set_type(q, ctx, d[7:])
    elif d.startswith("rule:geo:"):
        await q.answer(); await _rule_set_geo(q, ctx, d[9:])
    elif d.startswith("rule:gip:"):
        await q.answer(); await _rule_set_geoip(q, ctx, d[9:])
    elif d.startswith("rule:ob:"):
        await q.answer(); await _rule_set_outbound(q, ctx, d[8:])
    elif d == "rule:confirm":
        await q.answer(); await _rule_do(q, ctx)

    # ── Delete outbound ────────────────────────────────────────
    elif d == "sb:del_ob":
        await q.answer(); await _del_ob_start(q, ctx)
    elif d.startswith("dob:"):
        await q.answer(); await _del_ob_select(q, ctx, d[4:])
    elif d == "dob_y":
        await q.answer(); await _del_ob_do(q, ctx)

    # ── Delete rule ────────────────────────────────────────────
    elif d == "sb:del_rule":
        await q.answer(); await _del_rule_start(q, ctx)
    elif d.startswith("drl:"):
        await q.answer(); await _del_rule_select(q, ctx, int(d[4:]))
    elif d == "drl_y":
        await q.answer(); await _del_rule_do(q, ctx)

    # ── System ─────────────────────────────────────────────────
    elif d == "sys:info":
        await q.answer(); await _sys_info(q)
    elif d == "sys:reboot":
        await q.answer(); await _sys_reboot_ask(q)
    elif d == "sys:reboot_y":
        await q.answer(); await _sys_reboot_do(q)

    # ── Cancel (universal) ─────────────────────────────────────
    elif d == "cancel":
        await q.answer()
        ctx.user_data.clear()
        await _show_sb_menu(q)
    else:
        await q.answer()


# ═══════════════════════════════════════════════════════════════
#  TEXT ROUTER
# ═══════════════════════════════════════════════════════════════

@admin_only
async def on_text(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    state = ctx.user_data.get("state")
    if state == "vless_input":
        await _vless_process(update, ctx)
    elif state == "vless_tag":
        await _vless_set_tag(update, ctx)
    elif state == "grp_tag":
        await _grp_set_tag(update, ctx)
    elif state == "rule_custom":
        await _rule_set_custom(update, ctx)


# ═══════════════════════════════════════════════════════════════
#  sing-box MENU
# ═══════════════════════════════════════════════════════════════

async def _show_sb_menu(q):
    try:
        active = await run(singbox.is_service_active)
        ver = await run(singbox.get_version)
        tun = await run(singbox.is_tun_up)
        svc = "● active" if active else "○ inactive"
        t = "● UP" if tun else "○ DOWN"
        line = f"{svc}  |  v{ver}  |  TUN: {t}"
    except Exception:
        line = "○ статус недоступен"

    await q.edit_message_text(
        f"◼ <b>sing-box</b> — Управление\n\n<code>{esc(line)}</code>",
        parse_mode=ParseMode.HTML, reply_markup=kb_singbox(),
    )


# ═══════════════════════════════════════════════════════════════
#  STATUS
# ═══════════════════════════════════════════════════════════════

async def _sb_status(q):
    try:
        st = await run(singbox.get_status)
    except FileNotFoundError:
        await q.edit_message_text(
            "sing-box не установлен или конфиг не найден.",
            reply_markup=kb_back_sb())
        return
    except Exception as e:
        await q.edit_message_text(
            f"Ошибка: <code>{esc(str(e))}</code>",
            parse_mode=ParseMode.HTML, reply_markup=kb_back_sb())
        return

    svc = "● active" if st["active"] else "○ inactive"
    tun = "● UP" if st["tun_up"] else "○ DOWN"

    lines = [
        "◼ <b>Статус sing-box</b>\n",
        f"Сервис:  {svc}",
        f"Версия:  <code>{esc(st['version'])}</code>",
        f"TUN:     <code>{esc(st['tun_iface'])} ({esc(st['tun_addr'])})</code> {tun}",
        f"Proxy:   <code>:{esc(st['proxy_port'])}</code> (SOCKS5 + HTTP)",
    ]

    if st["outbounds"]:
        lines.append("\n<b>━━ Серверы и группы ━━</b>")
        for i, ob in enumerate(st["outbounds"], 1):
            det = f"\n   <i>{esc(ob['detail'])}</i>" if ob.get("detail") else ""
            lines.append(f"<code>{i:2d}.</code> [{esc(ob['type'])}] "
                         f"<b>{esc(ob['tag'])}</b>{det}")

    if st["rules"]:
        lines.append("\n<b>━━ Маршрутизация ━━</b>")
        for i, r in enumerate(st["rules"], 1):
            mark = " <i>[manual]</i>" if r.get("kind") == "manual" else ""
            lines.append(f"<code>{i:2d}.</code> {esc(r['left'])} → "
                         f"{esc(r['right'])}{mark}")
        lines.append(f"<code> *</code> final → {esc(st['final_route'])}")

    if st["dns_servers"]:
        lines.append("\n<b>━━ DNS ━━</b>")
        for ds in st["dns_servers"]:
            srv = f"{ds['type']}://{ds['server']}" if ds["server"] else ds["type"]
            lines.append(f"<code>{esc(ds['tag'])}</code>: {esc(srv)} "
                         f"(detour: {esc(ds['detour'])})")
        for dr in st["dns_rules"]:
            lines.append(f"  {esc(dr['left'])} → {esc(dr['right'])}")
        lines.append(f"  final → {esc(st['dns_final'])}")

    text = "\n".join(lines)
    if len(text) > 4000:
        text = text[:3990] + "\n<i>...обрезано</i>"

    await q.edit_message_text(text, parse_mode=ParseMode.HTML, reply_markup=kb_back_sb())


# ═══════════════════════════════════════════════════════════════
#  APPLY
# ═══════════════════════════════════════════════════════════════

async def _sb_apply(q):
    await q.edit_message_text(
        "◼ <b>Применение конфигурации</b>\n\n"
        "⏳ Проверка и перезапуск...",
        parse_mode=ParseMode.HTML)

    try:
        ok, msg = await run(singbox.apply_config)
        tun = await run(singbox.is_tun_up)
        if ok:
            t = "● UP" if tun else "○ DOWN"
            text = f"◼ <b>Конфигурация применена</b>\n\n✓ {esc(msg)}\nTUN: {t}"
        else:
            text = f"◼ <b>Ошибка применения</b>\n\n✕ <code>{esc(msg)}</code>"
    except Exception as e:
        text = f"◼ <b>Ошибка</b>\n\n<code>{esc(str(e))}</code>"

    await q.edit_message_text(text, parse_mode=ParseMode.HTML, reply_markup=kb_back_sb())


# ═══════════════════════════════════════════════════════════════
#  ADD VLESS
# ═══════════════════════════════════════════════════════════════

async def _vless_start(q, ctx):
    ctx.user_data["state"] = "vless_input"
    await q.edit_message_text(
        "◼ <b>Добавить VLESS-сервер</b>\n\n"
        "Вставьте <b>VLESS URI</b> (<code>vless://...</code>)\n"
        "или нажмите «Шаблон» для ручного ввода.",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("Шаблон ручного ввода", callback_data="vless:tpl")],
            [InlineKeyboardButton("✕ Отмена", callback_data="cancel")],
        ]))


async def _vless_template(q, ctx):
    ctx.user_data["state"] = "vless_input"
    tpl = (
        "tag=Имя-сервера\n"
        "server=vpn.example.com\n"
        "port=443\n"
        "uuid=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\n"
        "flow=xtls-rprx-vision\n"
        "security=reality\n"
        "sni=google.com\n"
        "fingerprint=chrome\n"
        "reality_pubkey=PUBLIC_KEY\n"
        "reality_shortid=\n"
        "transport=tcp"
    )
    await q.edit_message_text(
        "◼ <b>Ручной ввод</b>\n\n"
        "Скопируйте, заполните и отправьте:\n\n"
        f"<code>{tpl}</code>\n\n"
        "<i>Необязательные поля можно удалить.</i>",
        parse_mode=ParseMode.HTML, reply_markup=kb_cancel())


async def _vless_process(update: Update, ctx):
    text = update.message.text.strip()
    try:
        await update.message.delete()
    except Exception:
        pass

    try:
        if text.startswith("vless://"):
            params = singbox.parse_vless_uri(text)
        else:
            params = singbox.parse_vless_manual(text)
    except Exception as e:
        await update.effective_chat.send_message(
            f"✕ Ошибка: <code>{esc(str(e))}</code>\n\nПопробуйте ещё раз.",
            parse_mode=ParseMode.HTML, reply_markup=kb_cancel())
        return

    if not params.get("tag"):
        ctx.user_data["state"] = "vless_tag"
        ctx.user_data["vless"] = params
        await update.effective_chat.send_message(
            "Введите <b>тег</b> (имя) для сервера:",
            parse_mode=ParseMode.HTML, reply_markup=kb_cancel())
        return

    ctx.user_data["vless"] = params
    ctx.user_data["state"] = None
    await _vless_confirm_msg(update.effective_chat, params)


async def _vless_set_tag(update: Update, ctx):
    tag = update.message.text.strip()
    try:
        await update.message.delete()
    except Exception:
        pass
    params = ctx.user_data.get("vless", {})
    params["tag"] = tag
    ctx.user_data["state"] = None
    await _vless_confirm_msg(update.effective_chat, params)


async def _vless_confirm_msg(chat, params):
    uuid = params.get("uuid", "")
    uid = f"{uuid[:8]}...{uuid[-4:]}" if len(uuid) > 12 else uuid
    sec = params.get("security", "none")

    lines = [
        "◼ <b>Подтверждение</b>\n",
        f"Тег:       <code>{esc(params['tag'])}</code>",
        f"Сервер:    <code>{esc(str(params['server']))}:{params['port']}</code>",
        f"UUID:      <code>{esc(uid)}</code>",
    ]
    if params.get("flow"):
        lines.append(f"Flow:      <code>{esc(params['flow'])}</code>")
    lines.append(f"Security:  <code>{esc(sec)}</code>")
    if params.get("sni"):
        lines.append(f"SNI:       <code>{esc(params['sni'])}</code>")
    if sec == "reality" and params.get("reality_pubkey"):
        pk = params["reality_pubkey"]
        lines.append(f"Reality:   <code>{esc(pk[:16])}...</code>")
    lines.append(f"Transport: <code>{esc(params.get('transport', 'tcp'))}</code>")

    await chat.send_message(
        "\n".join(lines),
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("✓ Добавить", callback_data="vless:confirm"),
             InlineKeyboardButton("✓ + Применить", callback_data="vless:apply")],
            [InlineKeyboardButton("✕ Отмена", callback_data="cancel")],
        ]))


async def _vless_do(q, ctx, apply_after: bool):
    params = ctx.user_data.pop("vless", None)
    if not params:
        await q.edit_message_text("Нет данных.", reply_markup=kb_back_sb())
        return
    try:
        result = await run(singbox.add_vless, params)
        text = f"✓ {esc(result)}"
        if apply_after:
            ok, msg = await run(singbox.apply_config)
            sym = "✓" if ok else "✕"
            text += f"\n{sym} {esc(msg)}"
    except Exception as e:
        text = f"✕ Ошибка: <code>{esc(str(e))}</code>"

    ctx.user_data.pop("state", None)
    await q.edit_message_text(text, parse_mode=ParseMode.HTML, reply_markup=kb_after_change())


# ═══════════════════════════════════════════════════════════════
#  ADD GROUP
# ═══════════════════════════════════════════════════════════════

async def _grp_start(q, ctx):
    try:
        servers = await run(singbox.get_vless_servers)
    except Exception as e:
        await q.edit_message_text(
            f"Ошибка: <code>{esc(str(e))}</code>",
            parse_mode=ParseMode.HTML, reply_markup=kb_back_sb())
        return

    if not servers:
        await q.edit_message_text(
            "Нет VLESS-серверов.\nСначала добавьте сервер.",
            reply_markup=kb_back_sb())
        return

    ctx.user_data["grp_srv"] = servers
    ctx.user_data["grp_sel"] = set()
    await _grp_render(q, ctx)


async def _grp_render(q, ctx):
    servers = ctx.user_data["grp_srv"]
    sel = ctx.user_data["grp_sel"]

    buttons = []
    for i, s in enumerate(servers):
        mark = "☑" if i in sel else "☐"
        label = f"{mark} {s['tag']}  {s['server']}:{s['port']}"
        if len(label) > 55:
            label = label[:52] + "..."
        buttons.append([InlineKeyboardButton(label, callback_data=f"grp:t:{i}")])
    buttons.append([
        InlineKeyboardButton("Все", callback_data="grp:all"),
        InlineKeyboardButton("Далее ▸", callback_data="grp:next"),
    ])
    buttons.append([InlineKeyboardButton("✕ Отмена", callback_data="cancel")])

    await q.edit_message_text(
        f"◼ <b>Создать группу</b>\n\nВыберите серверы ({len(sel)} выбрано):",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup(buttons))


async def _grp_toggle(q, ctx, idx):
    sel = ctx.user_data.setdefault("grp_sel", set())
    sel.symmetric_difference_update({idx})
    await _grp_render(q, ctx)


async def _grp_all(q, ctx):
    ctx.user_data["grp_sel"] = set(range(len(ctx.user_data.get("grp_srv", []))))
    await _grp_render(q, ctx)


async def _grp_ask_tag(q, ctx):
    if not ctx.user_data.get("grp_sel"):
        await q.answer("Выберите хотя бы один сервер", show_alert=True)
        return
    ctx.user_data["state"] = "grp_tag"
    await q.edit_message_text(
        "◼ <b>Создать группу</b>\n\n"
        "Введите <b>тег</b> (имя) группы.\n\n"
        "<i>По умолчанию: proxy</i>",
        parse_mode=ParseMode.HTML, reply_markup=kb_cancel())


async def _grp_set_tag(update: Update, ctx):
    tag = update.message.text.strip() or "proxy"
    try:
        await update.message.delete()
    except Exception:
        pass
    ctx.user_data["grp_tag"] = tag
    ctx.user_data["state"] = None

    await update.effective_chat.send_message(
        f"◼ <b>Группа: {esc(tag)}</b>\n\nТип группы:",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("urltest — автовыбор + failover",
                                  callback_data="grp:type:urltest")],
            [InlineKeyboardButton("selector — ручной выбор",
                                  callback_data="grp:type:selector")],
            [InlineKeyboardButton("✕ Отмена", callback_data="cancel")],
        ]))


async def _grp_set_type(q, ctx, gtype):
    ctx.user_data["grp_type"] = gtype
    servers = ctx.user_data.get("grp_srv", [])
    sel = ctx.user_data.get("grp_sel", set())
    tag = ctx.user_data.get("grp_tag", "proxy")
    members = [servers[i]["tag"] for i in sorted(sel)]

    await q.edit_message_text(
        f"◼ <b>Подтверждение</b>\n\n"
        f"Тег:      <code>{esc(tag)}</code>\n"
        f"Тип:      <code>{esc(gtype)}</code>\n"
        f"Серверы:  <code>{esc(', '.join(members))}</code>",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("✓ Создать", callback_data="grp:confirm")],
            [InlineKeyboardButton("✕ Отмена", callback_data="cancel")],
        ]))


async def _grp_do(q, ctx):
    servers = ctx.user_data.get("grp_srv", [])
    sel = ctx.user_data.get("grp_sel", set())
    tag = ctx.user_data.get("grp_tag", "proxy")
    gtype = ctx.user_data.get("grp_type", "urltest")
    members = [servers[i]["tag"] for i in sorted(sel)]

    try:
        result = await run(singbox.add_group, tag, gtype, members)
        text = f"✓ {esc(result)}"
    except Exception as e:
        text = f"✕ Ошибка: <code>{esc(str(e))}</code>"

    for k in ("grp_srv", "grp_sel", "grp_tag", "grp_type", "state"):
        ctx.user_data.pop(k, None)
    await q.edit_message_text(text, parse_mode=ParseMode.HTML, reply_markup=kb_after_change())


# ═══════════════════════════════════════════════════════════════
#  ADD RULE
# ═══════════════════════════════════════════════════════════════

GEOSITE_CATS = [
    "youtube", "google", "facebook", "instagram", "twitter", "amazon",
    "microsoft", "apple", "telegram", "whatsapp", "tiktok", "netflix",
    "openai", "discord", "steam", "paypal", "spotify", "twitch",
    "github", "stackoverflow", "reddit", "linkedin", "wikipedia",
]

GEOIP_COUNTRIES = [
    ("ru", "Россия"), ("us", "США"), ("de", "Германия"), ("cn", "Китай"),
    ("nl", "Нидерланды"), ("jp", "Япония"), ("ua", "Украина"),
]


async def _rule_start(q, ctx):
    ctx.user_data.pop("state", None)
    await q.edit_message_text(
        "◼ <b>Добавить правило</b>\n\n"
        "<b>Ручные (высший приоритет):</b>\n"
        "  domain, domain_suffix, domain_keyword, ip_cidr\n\n"
        "<b>Rule-set (community):</b>\n"
        "  geosite, geoip\n\n"
        "Выберите тип:",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("domain", callback_data="rule:t:domain"),
             InlineKeyboardButton("domain_suffix", callback_data="rule:t:domain_suffix")],
            [InlineKeyboardButton("domain_keyword", callback_data="rule:t:domain_keyword"),
             InlineKeyboardButton("ip_cidr", callback_data="rule:t:ip_cidr")],
            [InlineKeyboardButton("geosite", callback_data="rule:t:geosite"),
             InlineKeyboardButton("geoip", callback_data="rule:t:geoip")],
            [InlineKeyboardButton("✕ Отмена", callback_data="cancel")],
        ]))


async def _rule_set_type(q, ctx, rtype):
    ctx.user_data["rule_type"] = rtype

    if rtype == "geosite":
        rows = []
        row = []
        for cat in GEOSITE_CATS:
            row.append(InlineKeyboardButton(cat, callback_data=f"rule:geo:{cat}"))
            if len(row) == 3:
                rows.append(row); row = []
        if row:
            rows.append(row)
        rows.append([InlineKeyboardButton("Другое...", callback_data="rule:geo:_")])
        rows.append([InlineKeyboardButton("✕ Отмена", callback_data="cancel")])
        await q.edit_message_text(
            "◼ <b>geosite</b> — категория:",
            parse_mode=ParseMode.HTML,
            reply_markup=InlineKeyboardMarkup(rows))

    elif rtype == "geoip":
        rows = [
            [InlineKeyboardButton(f"{c} — {n}", callback_data=f"rule:gip:{c}")]
            for c, n in GEOIP_COUNTRIES
        ]
        rows.append([InlineKeyboardButton("Другое...", callback_data="rule:gip:_")])
        rows.append([InlineKeyboardButton("✕ Отмена", callback_data="cancel")])
        await q.edit_message_text(
            "◼ <b>geoip</b> — страна:",
            parse_mode=ParseMode.HTML,
            reply_markup=InlineKeyboardMarkup(rows))

    else:
        ctx.user_data["state"] = "rule_custom"
        hints = {
            "domain": "домен (example.com)",
            "domain_suffix": "суффикс (.example.com)",
            "domain_keyword": "ключевое слово",
            "ip_cidr": "IP/CIDR (10.0.0.0/8)",
        }
        await q.edit_message_text(
            f"◼ <b>{esc(rtype)}</b>\n\nВведите {hints.get(rtype, 'значение')}:",
            parse_mode=ParseMode.HTML, reply_markup=kb_cancel())


async def _rule_set_geo(q, ctx, val):
    if val == "_":
        ctx.user_data["state"] = "rule_custom"
        ctx.user_data["rule_type"] = "geosite"
        await q.edit_message_text(
            "◼ <b>geosite</b>\n\nВведите имя категории:",
            parse_mode=ParseMode.HTML, reply_markup=kb_cancel())
        return
    ctx.user_data["rule_val"] = val
    await _rule_ask_outbound(q, ctx)


async def _rule_set_geoip(q, ctx, val):
    if val == "_":
        ctx.user_data["state"] = "rule_custom"
        ctx.user_data["rule_type"] = "geoip"
        await q.edit_message_text(
            "◼ <b>geoip</b>\n\nВведите код страны (2 буквы):",
            parse_mode=ParseMode.HTML, reply_markup=kb_cancel())
        return
    ctx.user_data["rule_val"] = val
    await _rule_ask_outbound(q, ctx)


async def _rule_set_custom(update: Update, ctx):
    val = update.message.text.strip()
    try:
        await update.message.delete()
    except Exception:
        pass
    if not val:
        return
    ctx.user_data["rule_val"] = val
    ctx.user_data["state"] = None
    await _rule_ask_outbound_msg(update.effective_chat, ctx)


async def _rule_ask_outbound(q, ctx):
    try:
        obs = await run(singbox.get_outbounds_for_rule)
    except Exception as e:
        await q.edit_message_text(
            f"Ошибка: <code>{esc(str(e))}</code>",
            parse_mode=ParseMode.HTML, reply_markup=kb_back_sb())
        return

    rtype = ctx.user_data.get("rule_type", "")
    rval = ctx.user_data.get("rule_val", "")
    buttons = _outbound_buttons(obs)
    await q.edit_message_text(
        f"◼ <b>{esc(rtype)}: {esc(rval)}</b>\n\nOutbound:",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup(buttons))


async def _rule_ask_outbound_msg(chat, ctx):
    try:
        obs = await run(singbox.get_outbounds_for_rule)
    except Exception as e:
        await chat.send_message(
            f"Ошибка: <code>{esc(str(e))}</code>",
            parse_mode=ParseMode.HTML, reply_markup=kb_back_sb())
        return

    rtype = ctx.user_data.get("rule_type", "")
    rval = ctx.user_data.get("rule_val", "")
    buttons = _outbound_buttons(obs)
    await chat.send_message(
        f"◼ <b>{esc(rtype)}: {esc(rval)}</b>\n\nOutbound:",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup(buttons))


def _outbound_buttons(obs):
    buttons = [
        [InlineKeyboardButton(f"[{o['type']}] {o['tag']}", callback_data=f"rule:ob:{o['tag']}")]
        for o in obs
    ]
    buttons.append([InlineKeyboardButton("✕ Отмена", callback_data="cancel")])
    return buttons


async def _rule_set_outbound(q, ctx, tag):
    ctx.user_data["rule_ob"] = tag
    rtype = ctx.user_data.get("rule_type", "")
    rval = ctx.user_data.get("rule_val", "")

    await q.edit_message_text(
        f"◼ <b>Подтверждение</b>\n\n"
        f"Тип:       <code>{esc(rtype)}</code>\n"
        f"Значение:  <code>{esc(rval)}</code>\n"
        f"Outbound:  <code>{esc(tag)}</code>",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("✓ Добавить", callback_data="rule:confirm")],
            [InlineKeyboardButton("✕ Отмена", callback_data="cancel")],
        ]))


async def _rule_do(q, ctx):
    rtype = ctx.user_data.pop("rule_type", None)
    rval = ctx.user_data.pop("rule_val", None)
    ob = ctx.user_data.pop("rule_ob", None)

    try:
        result = await run(singbox.add_rule, rtype, rval, ob)
        text = f"✓ {esc(result)}"
    except Exception as e:
        text = f"✕ Ошибка: <code>{esc(str(e))}</code>"

    ctx.user_data.pop("state", None)
    await q.edit_message_text(text, parse_mode=ParseMode.HTML, reply_markup=kb_after_change())


# ═══════════════════════════════════════════════════════════════
#  DELETE OUTBOUND
# ═══════════════════════════════════════════════════════════════

async def _del_ob_start(q, ctx):
    try:
        obs = await run(singbox.get_deletable_outbounds)
    except Exception as e:
        await q.edit_message_text(
            f"Ошибка: <code>{esc(str(e))}</code>",
            parse_mode=ParseMode.HTML, reply_markup=kb_back_sb())
        return

    if not obs:
        await q.edit_message_text(
            "Нет серверов/групп для удаления.", reply_markup=kb_back_sb())
        return

    buttons = [
        [InlineKeyboardButton(f"[{o['type']}] {o['tag']}", callback_data=f"dob:{o['tag']}")]
        for o in obs
    ]
    buttons.append([InlineKeyboardButton("✕ Отмена", callback_data="cancel")])

    await q.edit_message_text(
        "◼ <b>Удалить сервер/группу</b>\n\nВыберите:",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup(buttons))


async def _del_ob_select(q, ctx, tag):
    ctx.user_data["del_ob"] = tag
    await q.edit_message_text(
        f"Удалить <b>{esc(tag)}</b>?\n\n"
        f"Связанные правила маршрутизации тоже будут удалены.",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("✓ Удалить", callback_data="dob_y")],
            [InlineKeyboardButton("✕ Отмена", callback_data="cancel")],
        ]))


async def _del_ob_do(q, ctx):
    tag = ctx.user_data.pop("del_ob", None)
    if not tag:
        await _show_sb_menu(q); return
    try:
        result = await run(singbox.delete_outbound, tag)
        text = f"✓ {esc(result)}"
    except Exception as e:
        text = f"✕ Ошибка: <code>{esc(str(e))}</code>"
    await q.edit_message_text(text, parse_mode=ParseMode.HTML, reply_markup=kb_after_change())


# ═══════════════════════════════════════════════════════════════
#  DELETE RULE
# ═══════════════════════════════════════════════════════════════

async def _del_rule_start(q, ctx):
    try:
        rules = await run(singbox.get_deletable_rules)
    except Exception as e:
        await q.edit_message_text(
            f"Ошибка: <code>{esc(str(e))}</code>",
            parse_mode=ParseMode.HTML, reply_markup=kb_back_sb())
        return

    if not rules:
        await q.edit_message_text(
            "Нет пользовательских правил.", reply_markup=kb_back_sb())
        return

    buttons = []
    for r in rules:
        label = f"{r['label']} → {r['outbound']}"
        if len(label) > 55:
            label = label[:52] + "..."
        buttons.append([InlineKeyboardButton(label, callback_data=f"drl:{r['index']}")])
    buttons.append([InlineKeyboardButton("✕ Отмена", callback_data="cancel")])

    await q.edit_message_text(
        "◼ <b>Удалить правило</b>\n\nВыберите:",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup(buttons))


async def _del_rule_select(q, ctx, idx):
    ctx.user_data["del_rule"] = idx
    try:
        rules = await run(singbox.get_deletable_rules)
        rule = next((r for r in rules if r["index"] == idx), None)
        label = f"{rule['label']} → {rule['outbound']}" if rule else f"#{idx}"
    except Exception:
        label = f"#{idx}"

    await q.edit_message_text(
        f"Удалить правило?\n\n<code>{esc(label)}</code>",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("✓ Удалить", callback_data="drl_y")],
            [InlineKeyboardButton("✕ Отмена", callback_data="cancel")],
        ]))


async def _del_rule_do(q, ctx):
    idx = ctx.user_data.pop("del_rule", None)
    if idx is None:
        await _show_sb_menu(q); return
    try:
        result = await run(singbox.delete_rule, idx)
        text = f"✓ {esc(result)}"
    except Exception as e:
        text = f"✕ Ошибка: <code>{esc(str(e))}</code>"
    await q.edit_message_text(text, parse_mode=ParseMode.HTML, reply_markup=kb_after_change())


# ═══════════════════════════════════════════════════════════════
#  SYSTEM
# ═══════════════════════════════════════════════════════════════

async def _show_sys_menu(q):
    await q.edit_message_text(
        "◼ <b>Система</b>\n\nУправление устройством.",
        parse_mode=ParseMode.HTML, reply_markup=kb_system())


async def _sys_info(q):
    try:
        info = await run(_collect_sys_info)
    except Exception as e:
        await q.edit_message_text(
            f"Ошибка: <code>{esc(str(e))}</code>",
            parse_mode=ParseMode.HTML,
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("◂ Назад", callback_data="m:sys")]]))
        return

    lines = [
        "◼ <b>Информация о системе</b>\n",
        f"Hostname:  <code>{esc(info['hostname'])}</code>",
        f"Uptime:    <code>{esc(info['uptime'])}</code>",
        f"CPU:       <code>{esc(info['cpu'])}</code>",
        f"RAM:       <code>{esc(info['ram'])}</code>",
        f"Disk:      <code>{esc(info['disk'])}</code>",
        f"Temp:      <code>{esc(info['temp'])}</code>",
    ]
    if info.get("ips"):
        lines.append("\n<b>Сетевые интерфейсы:</b>")
        for iface, ip in info["ips"]:
            lines.append(f"  <code>{esc(iface)}: {esc(ip)}</code>")

    await q.edit_message_text(
        "\n".join(lines),
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("◂ Назад", callback_data="m:sys")]]))


def _collect_sys_info() -> dict:
    def sh(cmd):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=5, shell=True)
            return r.stdout.strip()
        except Exception:
            return "?"

    hostname = sh("hostname")
    uptime = sh("uptime -p")
    cpu = sh("top -bn1 | grep 'Cpu(s)' | awk '{printf \"%.1f%%\", $2+$4}'") or "?"
    ram = sh("free -m | awk 'NR==2{printf \"%d/%dMB (%.0f%%)\", $3,$2,$3*100/$2}'") or "?"
    disk = sh("df -h / | awk 'NR==2{printf \"%s/%s (%s)\", $3,$2,$5}'") or "?"

    temp = "?"
    raw = sh("cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null")
    if raw and raw != "?":
        try:
            temp = f"{int(raw) / 1000:.1f} C"
        except (ValueError, ZeroDivisionError):
            pass

    ips = []
    for line in sh("ip -4 -o addr show | awk '{print $2, $4}'").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] != "lo":
            ips.append((parts[0], parts[1]))

    return {
        "hostname": hostname, "uptime": uptime, "cpu": cpu,
        "ram": ram, "disk": disk, "temp": temp, "ips": ips,
    }


async def _sys_reboot_ask(q):
    await q.edit_message_text(
        "◼ <b>Перезагрузка</b>\n\nПерезагрузить устройство?",
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("✓ Перезагрузить", callback_data="sys:reboot_y")],
            [InlineKeyboardButton("✕ Отмена", callback_data="m:sys")],
        ]))


async def _sys_reboot_do(q):
    await q.edit_message_text("Перезагрузка...")
    subprocess.Popen(["shutdown", "-r", "now"])


# ═══════════════════════════════════════════════════════════════
#  ENTRY POINT
# ═══════════════════════════════════════════════════════════════

def main():
    cfg = load_config()
    token = cfg.get("token")
    if not token:
        log.error("Token not found in %s", BOT_CONFIG)
        return

    app = Application.builder().token(token).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CallbackQueryHandler(on_callback))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))

    log.info("Bot started")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
