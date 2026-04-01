#!/usr/bin/env python3
"""sing-box configuration management for NanoPi R5S Telegram bot."""

import json
import os
import shutil
import subprocess
import time
from datetime import datetime
from typing import Any, Dict, List, Tuple
from urllib.parse import unquote

SINGBOX_CONFIG = "/etc/sing-box/config.json"
SINGBOX_BACKUP_DIR = "/root/singbox-backup"
SINGBOX_BIN = "/usr/local/bin/sing-box"


# ── Config I/O ─────────────────────────────────────────────────

def read_config() -> dict:
    with open(SINGBOX_CONFIG, "r") as f:
        return json.load(f)


def write_config(config: dict) -> None:
    tmp = SINGBOX_CONFIG + ".tmp"
    with open(tmp, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    os.replace(tmp, SINGBOX_CONFIG)


def backup_config() -> None:
    os.makedirs(SINGBOX_BACKUP_DIR, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    shutil.copy2(SINGBOX_CONFIG, os.path.join(SINGBOX_BACKUP_DIR, f"config-{ts}.json"))


# ── Service status ─────────────────────────────────────────────

def get_version() -> str:
    try:
        r = subprocess.run([SINGBOX_BIN, "version"], capture_output=True, text=True, timeout=5)
        parts = r.stdout.strip().split()
        return parts[-1] if parts else "?"
    except Exception:
        return "?"


def is_service_active() -> bool:
    try:
        return subprocess.run(
            ["systemctl", "is-active", "--quiet", "sing-box"], timeout=5
        ).returncode == 0
    except Exception:
        return False


def is_tun_up(iface: str = "tun0") -> bool:
    try:
        return subprocess.run(
            ["ip", "link", "show", iface], capture_output=True, timeout=5
        ).returncode == 0
    except Exception:
        return False


def validate_config() -> Tuple[bool, str]:
    try:
        r = subprocess.run(
            [SINGBOX_BIN, "check", "-c", SINGBOX_CONFIG],
            capture_output=True, text=True, timeout=10,
        )
        return (True, "") if r.returncode == 0 else (False, r.stderr or r.stdout)
    except Exception as e:
        return False, str(e)


def apply_config() -> Tuple[bool, str]:
    ok, err = validate_config()
    if not ok:
        return False, f"Конфиг невалиден:\n{err}"
    try:
        subprocess.run(["systemctl", "restart", "sing-box"], timeout=10, check=True)
        time.sleep(2)
        if is_service_active():
            return True, "sing-box перезапущен"
        r = subprocess.run(
            ["journalctl", "-u", "sing-box", "--no-pager", "-n", "10"],
            capture_output=True, text=True, timeout=5,
        )
        return False, f"sing-box не запустился\n{r.stdout}"
    except Exception as e:
        return False, str(e)


def service_action(action: str) -> Tuple[bool, str]:
    """Start / stop / restart sing-box."""
    try:
        subprocess.run(["systemctl", action, "sing-box"], timeout=10, check=True)
        time.sleep(1)
        active = is_service_active()
        if action == "stop":
            return not active, f"sing-box {'остановлен' if not active else 'не остановился'}"
        return active, f"sing-box {'запущен' if active else 'не запустился'}"
    except Exception as e:
        return False, str(e)


# ── Full status ────────────────────────────────────────────────

def _join(val: Any) -> str:
    return ", ".join(val) if isinstance(val, list) else str(val)


def get_status() -> dict:
    config = read_config()

    tun_iface, tun_addr, proxy_port = "tun0", "?", "?"
    for inb in config.get("inbounds", []):
        if inb.get("type") == "tun":
            tun_iface = inb.get("interface_name", "tun0")
            addrs = inb.get("address", [])
            tun_addr = addrs[0] if addrs else "?"
        elif inb.get("type") == "mixed":
            proxy_port = str(inb.get("listen_port", "?"))

    outbounds = []
    for ob in config.get("outbounds", []):
        entry: Dict[str, Any] = {"type": ob.get("type"), "tag": ob.get("tag")}
        if ob["type"] == "vless":
            entry["detail"] = f'{ob.get("server", "")}:{ob.get("server_port", "")}'
        elif ob["type"] in ("urltest", "selector"):
            entry["detail"] = ", ".join(ob.get("outbounds", []))
        outbounds.append(entry)

    rules: List[Dict[str, str]] = []
    for rule in config.get("route", {}).get("rules", []):
        action = rule.get("action")
        outbound = rule.get("outbound", "")
        r: Dict[str, str] = {}

        if action and action != "route":
            proto = rule.get("protocol", "")
            r = {"left": f"protocol: {proto}" if proto else "action",
                 "right": action, "kind": "action"}
        elif "inbound" in rule:
            r = {"left": f"inbound: {_join(rule['inbound'])}",
                 "right": outbound, "kind": "system"}
        else:
            for key, prefix in [
                ("rule_set", "rule-set"), ("domain", "domain"),
                ("domain_suffix", "domain_suffix"), ("domain_keyword", "domain_keyword"),
                ("ip_cidr", "ip_cidr"),
            ]:
                if key in rule:
                    kind = "ruleset" if key == "rule_set" else "manual"
                    r = {"left": f"{prefix}: {_join(rule[key])}",
                         "right": outbound, "kind": kind}
                    break
            else:
                r = {"left": "(другое)", "right": outbound, "kind": "other"}
        rules.append(r)

    dns_servers = [
        {"tag": s.get("tag", "?"), "type": s.get("type", "?"),
         "server": s.get("server", ""), "detour": s.get("detour", "-")}
        for s in config.get("dns", {}).get("servers", [])
    ]

    dns_rules: List[Dict[str, str]] = []
    for dr in config.get("dns", {}).get("rules", []):
        server = dr.get("server", "")
        for key, prefix in [
            ("rule_set", "rule-set"), ("domain", "domain"),
            ("domain_suffix", "domain_suffix"),
        ]:
            if key in dr:
                dns_rules.append({"left": f"{prefix}: {_join(dr[key])}", "right": server})
                break
        else:
            dns_rules.append({"left": "(другое)", "right": server})

    return {
        "version": get_version(),
        "active": is_service_active(),
        "tun_iface": tun_iface, "tun_addr": tun_addr,
        "tun_up": is_tun_up(tun_iface),
        "proxy_port": proxy_port,
        "outbounds": outbounds,
        "rules": rules,
        "final_route": config.get("route", {}).get("final", "direct"),
        "dns_servers": dns_servers,
        "dns_rules": dns_rules,
        "dns_final": config.get("dns", {}).get("final", "dns-direct"),
        "rule_sets": [
            {"tag": rs.get("tag", "?"), "type": rs.get("type", "?")}
            for rs in config.get("route", {}).get("rule_set", [])
        ],
    }


# ── VLESS parsing ──────────────────────────────────────────────

def parse_vless_uri(uri: str) -> dict:
    if not uri.startswith("vless://"):
        raise ValueError("URI должен начинаться с vless://")

    body = uri[8:]
    tag = ""
    if "#" in body:
        body, frag = body.rsplit("#", 1)
        tag = unquote(frag)

    uuid_part, rest = body.split("@", 1)
    params_str = ""
    if "?" in rest:
        hostport, params_str = rest.split("?", 1)
    else:
        hostport = rest

    if hostport.startswith("["):
        server = hostport[1:hostport.index("]")]
        port = int(hostport[hostport.index("]:") + 2:])
    else:
        parts = hostport.rsplit(":", 1)
        server, port = parts[0], int(parts[1])

    kv: Dict[str, str] = {}
    if params_str:
        for pair in params_str.split("&"):
            if "=" in pair:
                k, v = pair.split("=", 1)
                kv[k] = unquote(v)

    return {
        "tag": tag, "server": server, "port": port, "uuid": uuid_part,
        "flow": kv.get("flow", ""),
        "security": kv.get("security", "none"),
        "sni": kv.get("sni", ""),
        "fingerprint": kv.get("fp", "chrome"),
        "reality_pubkey": kv.get("pbk", ""),
        "reality_shortid": kv.get("sid", ""),
        "transport": kv.get("type", "tcp"),
        "ws_path": kv.get("path", ""),
        "ws_host": kv.get("host", ""),
        "grpc_service": kv.get("serviceName", ""),
        "alpn": kv.get("alpn", ""),
    }


def parse_vless_manual(text: str) -> dict:
    """Parse key=value text into VLESS params."""
    kv: Dict[str, str] = {}
    for line in text.strip().splitlines():
        line = line.strip()
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip()

    for short, full in [("fp", "fingerprint"), ("pbk", "reality_pubkey"), ("sid", "reality_shortid")]:
        if short in kv and full not in kv:
            kv[full] = kv.pop(short)

    for field in ("tag", "server", "port", "uuid"):
        if field not in kv:
            raise ValueError(f"Обязательное поле отсутствует: {field}")

    kv["port"] = int(kv["port"])
    defaults = {
        "flow": "", "security": "none", "sni": "", "fingerprint": "chrome",
        "reality_pubkey": "", "reality_shortid": "", "transport": "tcp",
        "ws_path": "", "ws_host": "", "grpc_service": "", "alpn": "",
    }
    for k, v in defaults.items():
        kv.setdefault(k, v)
    return kv


def build_vless_outbound(p: dict) -> dict:
    ob: Dict[str, Any] = {
        "type": "vless", "tag": p["tag"],
        "server": p["server"], "server_port": p["port"], "uuid": p["uuid"],
    }
    if p.get("flow"):
        ob["flow"] = p["flow"]

    sec = p.get("security", "none")
    if sec in ("tls", "reality"):
        tls: Dict[str, Any] = {"enabled": True}
        if p.get("sni"):
            tls["server_name"] = p["sni"]
        if p.get("fingerprint"):
            tls["utls"] = {"enabled": True, "fingerprint": p["fingerprint"]}
        if p.get("alpn"):
            tls["alpn"] = [a.strip() for a in p["alpn"].split(",")]
        if sec == "reality":
            tls["reality"] = {
                "enabled": True,
                "public_key": p["reality_pubkey"],
                "short_id": p.get("reality_shortid", ""),
            }
        ob["tls"] = tls

    tr = p.get("transport", "tcp")
    if tr == "ws":
        t: Dict[str, Any] = {"type": "ws", "path": p.get("ws_path") or "/"}
        if p.get("ws_host"):
            t["headers"] = {"Host": p["ws_host"]}
        ob["transport"] = t
    elif tr == "grpc":
        ob["transport"] = {"type": "grpc", "service_name": p.get("grpc_service") or "grpc"}

    return ob


def add_vless(params: dict) -> str:
    config = read_config()
    for ob in config.get("outbounds", []):
        if ob.get("tag") == params["tag"]:
            raise ValueError(f"Outbound '{params['tag']}' уже существует")

    backup_config()
    outbound = build_vless_outbound(params)
    outs = config["outbounds"]
    pos = next(
        (i for i, o in enumerate(outs) if o.get("type") in ("direct", "block", "dns")),
        len(outs),
    )
    outs.insert(pos, outbound)
    write_config(config)
    return f"VLESS '{params['tag']}' добавлен"


def get_vless_servers() -> List[dict]:
    config = read_config()
    return [
        {"tag": ob["tag"], "server": ob.get("server", ""), "port": ob.get("server_port", "")}
        for ob in config.get("outbounds", []) if ob.get("type") == "vless"
    ]


# ── Groups ─────────────────────────────────────────────────────

def add_group(
    tag: str, group_type: str, members: List[str],
    health_url: str = "https://www.gstatic.com/generate_204",
    health_interval: str = "3m",
    health_tolerance: int = 50,
    set_proxy_in: bool = True,
    set_dns_detour: bool = True,
) -> str:
    config = read_config()
    backup_config()

    config["outbounds"] = [o for o in config["outbounds"] if o.get("tag") != tag]

    group: Dict[str, Any] = {"type": group_type, "tag": tag, "outbounds": members}
    if group_type == "urltest":
        group.update(url=health_url, interval=health_interval, tolerance=health_tolerance)

    outs = config["outbounds"]
    pos = next(
        (i for i, o in enumerate(outs) if o.get("type") in ("direct", "block", "dns")),
        len(outs),
    )
    outs.insert(pos, group)

    if set_proxy_in:
        config["route"]["rules"] = [
            r for r in config["route"]["rules"] if r.get("inbound") != ["proxy-in"]
        ]
        rules = config["route"]["rules"]
        insert = 0
        for i, r in enumerate(rules):
            if r.get("action") and r["action"] != "route":
                insert = i + 1
        rules.insert(insert, {"inbound": ["proxy-in"], "outbound": tag})

    if set_dns_detour:
        for ds in config.get("dns", {}).get("servers", []):
            if ds.get("tag") == "dns-vpn":
                ds["detour"] = tag

    write_config(config)
    return f"Группа '{tag}' ({group_type}) создана"


# ── Rules ──────────────────────────────────────────────────────

def get_outbounds_for_rule() -> List[dict]:
    config = read_config()
    return [
        {"tag": o["tag"], "type": o.get("type", "?")}
        for o in config.get("outbounds", []) if o.get("type") != "dns"
    ]


def add_rule(rule_type: str, value: str, outbound: str) -> str:
    config = read_config()
    backup_config()

    is_rs = rule_type in ("geosite", "geoip")
    dns_mirror = any(
        o.get("tag") == outbound and o.get("type") not in ("direct", "block")
        for o in config.get("outbounds", [])
    )

    if is_rs:
        rs_tag = f"{rule_type}-{value}"
        rs_url = (
            f"https://raw.githubusercontent.com/SagerNet/sing-{rule_type}"
            f"/rule-set/{rs_tag}.srs"
        )
        rsets = config.setdefault("route", {}).setdefault("rule_set", [])
        if not any(r.get("tag") == rs_tag for r in rsets):
            rsets.append({
                "type": "remote", "tag": rs_tag, "format": "binary",
                "url": rs_url, "download_detour": "direct", "update_interval": "72h",
            })

        rr = config["route"]["rules"]
        if not any(r.get("rule_set") == [rs_tag] and r.get("outbound") == outbound for r in rr):
            rr.append({"rule_set": [rs_tag], "outbound": outbound})

        if dns_mirror:
            dr = config.setdefault("dns", {}).setdefault("rules", [])
            if not any(r.get("rule_set") == [rs_tag] for r in dr):
                dr.append({"rule_set": [rs_tag], "server": "dns-vpn"})
    else:
        new_rule = {rule_type: [value], "outbound": outbound}
        rr = config["route"]["rules"]
        pos = next((i for i, r in enumerate(rr) if "rule_set" in r), len(rr))
        rr.insert(pos, new_rule)
        if dns_mirror:
            dr = config.setdefault("dns", {}).setdefault("rules", [])
            dr.append({rule_type: [value], "server": "dns-vpn"})

    write_config(config)
    return f"Правило: {rule_type}:{value} → {outbound}"


# ── Delete ─────────────────────────────────────────────────────

def get_deletable_outbounds() -> List[dict]:
    config = read_config()
    return [
        {"tag": o["tag"], "type": o.get("type", "?")}
        for o in config.get("outbounds", [])
        if o.get("type") not in ("direct", "block", "dns")
    ]


def delete_outbound(tag: str) -> str:
    config = read_config()
    backup_config()

    config["outbounds"] = [o for o in config["outbounds"] if o.get("tag") != tag]
    for o in config["outbounds"]:
        if "outbounds" in o:
            o["outbounds"] = [t for t in o["outbounds"] if t != tag]
    config["route"]["rules"] = [
        r for r in config["route"]["rules"] if r.get("outbound") != tag
    ]
    for ds in config.get("dns", {}).get("servers", []):
        if ds.get("detour") == tag:
            ds.pop("detour", None)

    write_config(config)
    return f"'{tag}' удалён"


def get_deletable_rules() -> List[dict]:
    config = read_config()
    result = []
    for i, rule in enumerate(config.get("route", {}).get("rules", [])):
        action = rule.get("action")
        if action and action != "route":
            continue
        if "inbound" in rule:
            continue

        outbound = rule.get("outbound", "")
        label = "(другое)"
        for key, prefix in [
            ("rule_set", "rule-set"), ("domain", "domain"),
            ("domain_suffix", "domain_suffix"), ("domain_keyword", "domain_keyword"),
            ("ip_cidr", "ip_cidr"),
        ]:
            if key in rule:
                label = f"{prefix}: {_join(rule[key])}"
                break
        result.append({"index": i, "label": label, "outbound": outbound})
    return result


def delete_rule(index: int) -> str:
    config = read_config()
    backup_config()

    rules = config["route"]["rules"]
    if not (0 <= index < len(rules)):
        raise ValueError("Неверный индекс правила")

    del_rule = rules.pop(index)
    dns_rules = config.get("dns", {}).get("rules", [])

    for key in ("rule_set", "domain", "domain_suffix", "domain_keyword", "ip_cidr"):
        if key in del_rule:
            val = del_rule[key]
            config["dns"]["rules"] = [r for r in dns_rules if r.get(key) != val]
            break

    write_config(config)
    return "Правило удалено"
