# NanoPi R5S — Скрипты настройки роутера

Набор bash-скриптов для превращения **NanoPi R5S** (Ubuntu / Armbian) в полноценный роутер.

## Схема сети

```
                    ┌─────────────────────────┐
   Интернет ───────►│  eth0  (WAN)            │
   (от провайдера)  │                         │
                    │       NanoPi R5S        │
                    │       (роутер)          │
                    │                         │
   Локальная сеть ◄─┤  eth1 ─┐                │
                    │        ├─ br0  (LAN)    │
   Локальная сеть ◄─┤  eth2 ─┘                │
                    └─────────────────────────┘
```

| Интерфейс | Роль | Описание |
|-----------|------|----------|
| `eth0` | WAN | Получает IP по DHCP от провайдера |
| `eth1` | LAN | Объединён в мост `br0` |
| `eth2` | LAN | Объединён в мост `br0` |
| `br0` | LAN bridge | Подсеть по умолчанию `192.168.10.0/24` |

## Скрипты

| Скрипт | Описание |
|--------|----------|
| `scripts/01-router-setup.sh` | Настройка роутера: netplan, nftables, NAT, DHCP |
| `scripts/02-singbox-install.sh` | Установка sing-box: TUN, proxy, split DNS |
| `scripts/singbox-add-vless.sh` | Добавить VLESS-подключение (URI или вручную) |
| `scripts/singbox-add-group.sh` | Создать группу outbound'ов (urltest / selector) |
| `scripts/singbox-add-rule.sh` | Добавить правило маршрутизации (domain, geosite, geoip) |
| `scripts/singbox-status.sh` | Показать текущую конфигурацию и статус |
| `scripts/singbox-apply.sh` | Валидация конфига и перезапуск sing-box |

## Быстрый старт

**Первая установка:**

```bash
git clone https://github.com/vmatveenko/NanoPI-R5S.git ~/nanopi-router
cd ~/nanopi-router
chmod +x scripts/*.sh
sudo ./scripts/01-router-setup.sh
```

**Обновление (если уже скачан):**

```bash
cd ~/nanopi-router
git pull
sudo ./scripts/01-router-setup.sh
```

## Что делает `01-router-setup.sh`

1. Проверяет наличие интерфейсов `eth0`, `eth1`, `eth2`
2. Запрашивает параметры LAN (CIDR, DHCP-диапазон, DNS)
3. Создаёт бэкап текущих конфигов → `/root/router-backup-<timestamp>`
4. Устанавливает `nftables` и `isc-dhcp-server`
5. Настраивает **netplan**: WAN (DHCP) + LAN bridge
6. Включает **IP forwarding**
7. Настраивает **nftables**: firewall + NAT masquerade
8. Настраивает **DHCP-сервер** на `br0`
9. Проверяет работоспособность сервисов

### Параметры по умолчанию

| Параметр | Значение |
|----------|----------|
| LAN IP | `192.168.10.1/24` |
| DHCP диапазон | `192.168.10.10` — `192.168.10.200` |
| DNS | `8.8.8.8`, `1.1.1.1` |

Все параметры можно изменить при запуске скрипта.

## sing-box — прозрачный прокси и VPN

[sing-box](https://sing-box.sagernet.org/) — универсальная прокси-платформа с поддержкой VLESS, TUN, rule-based routing и split DNS.

### Архитектура

```
Устройство в LAN
      │
      ▼
    br0 (LAN bridge)
      │
      ▼  (policy routing)
    tun0 (sing-box TUN)
      │
      ▼
  ┌─────────────────────┐
  │      sing-box        │
  │                      │
  │  route rules:        │
  │  youtube → VPN       │
  │  *       → direct    │
  └──────┬───────┬───────┘
    VPN выход  Direct выход
    (VLESS)    (напрямую)
         │       │
         ▼       ▼
        eth0 (WAN) → Интернет
```

- **TUN** (`tun0`) — прозрачный прокси для всего LAN-трафика. Устройства ничего не настраивают.
- **Proxy** (SOCKS5 + HTTP, порт 2080) — для устройств/ПО, которые нужно целиком пустить через VPN.
- **Split DNS** — домены, идущие через VPN, резолвятся через DoH по VPN-туннелю.

### Установка sing-box

```bash
sudo ./scripts/02-singbox-install.sh
```

### Типовой сценарий настройки

```bash
# 1. Добавить VLESS-серверы (можно вставить URI-ссылку)
sudo ./scripts/singbox-add-vless.sh
sudo ./scripts/singbox-add-vless.sh

# 2. Создать группу с автовыбором (failover + latency)
sudo ./scripts/singbox-add-group.sh

# 3. Добавить правила маршрутизации
sudo ./scripts/singbox-add-rule.sh     # youtube → proxy
sudo ./scripts/singbox-add-rule.sh     # google  → proxy

# 4. Применить конфигурацию
sudo ./scripts/singbox-apply.sh

# 5. Проверить статус
sudo ./scripts/singbox-status.sh
```

### Использование proxy (SOCKS/HTTP)

Для устройств, которые нужно целиком пустить через VPN, настройте прокси:

| Параметр | Значение |
|----------|----------|
| Тип | SOCKS5 или HTTP |
| Адрес | IP роутера (например `192.168.10.1`) |
| Порт | `2080` (по умолчанию) |

### Что делает `02-singbox-install.sh`

1. Устанавливает зависимости (`curl`, `jq`)
2. Скачивает последнюю версию sing-box с GitHub
3. Создаёт systemd-сервис
4. Запрашивает параметры (порт proxy, TUN-адрес, DNS)
5. Генерирует базовый конфиг (весь трафик → direct)
6. Добавляет правила `tun0` в nftables
7. Запускает sing-box

При повторном запуске: обновляет бинарник и nftables, **не трогает конфиг** (сохраняет VPN и правила).

> **Важно:** после повторного запуска `01-router-setup.sh` необходимо перезапустить `02-singbox-install.sh` для восстановления nftables-правил sing-box.

## Проброс портов

Для проброса портов отредактируйте `/etc/nftables.conf`, цепочка `prerouting`:

```bash
# Пример: проброс порта 8080 с WAN на 192.168.10.100:80
iifname "eth0" tcp dport 8080 dnat to 192.168.10.100:80
```

Правило `ct status dnat accept` в цепочке `forward` уже разрешает прохождение DNAT-трафика — дополнительных forward-правил добавлять не нужно.

Затем: `sudo systemctl restart nftables`

## SSH-доступ с WAN

По умолчанию SSH с WAN **закрыт**. Чтобы открыть, раскомментируйте строку в `/etc/nftables.conf` → `chain input`:

```bash
iifname "eth0" tcp dport 22 ct state new accept
```

## Откат изменений

Бэкап создаётся автоматически в `/root/router-backup-<timestamp>/`. Для отката:

```bash
# Восстановить netplan
sudo cp /root/router-backup-*/netplan/*.yaml /etc/netplan/
sudo netplan apply

# Восстановить nftables
sudo cp /root/router-backup-*/nftables.conf /etc/
sudo systemctl restart nftables
```

## Требования

- **Устройство**: NanoPi R5S
- **ОС**: Ubuntu 22.04+ / Armbian
- **Интерфейсы**: `eth0`, `eth1`, `eth2`
- **Права**: root (sudo)

## Лицензия

MIT
