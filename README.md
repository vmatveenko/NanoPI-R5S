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
| `singbox.sh` | Управление sing-box: серверы, группы, правила, статус |

## Быстрый старт

**Первая установка:**

```bash
git clone https://github.com/vmatveenko/NanoPI-R5S.git ~/nanopi-router
cd ~/nanopi-router
chmod +x scripts/*.sh *.sh
sudo ./scripts/01-router-setup.sh
```

**Переустановка Sing-box:**

```bash
cd ~/nanopi-router
git reset --hard
git pull
sudo rm /etc/sing-box/config.json
chmod +x scripts/*.sh *.sh
sudo ./scripts/02-singbox-install.sh
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
  ┌──────────────────────┐
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

### Что делает `02-singbox-install.sh`

1. Устанавливает зависимости (`curl`, `jq`)
2. Определяет подсеть LAN (из `br0`) для корректной маршрутизации
3. Скачивает последнюю версию sing-box с GitHub
4. Создаёт systemd-сервис
5. Запрашивает параметры (порт proxy, TUN-адрес, DNS)
6. Генерирует базовый конфиг с `route_exclude_address` для LAN
7. Настраивает `sysctl` (отключает `rp_filter` для TUN)
8. Добавляет правила `tun0` в nftables (br0↔tun0 в обе стороны)
9. Запускает sing-box

При повторном запуске: обновляет бинарник, nftables и sysctl, автоматически мигрирует конфиг (добавляет `route_exclude_address`, исправляет DNS) — **VPN/правила сохраняются**.

> **Важно:** после повторного запуска `01-router-setup.sh` необходимо перезапустить `02-singbox-install.sh` для восстановления nftables-правил sing-box.

---

### Управление sing-box

Все операции выполняются через единый скрипт `singbox.sh` в корне проекта:

```bash
sudo ./singbox.sh
```

Откроется интерактивное меню:

```
  sing-box · Управление
  ────────────────────────────────────────────
  ● active  │  v1.13.5  │  TUN: UP
  ────────────────────────────────────────────

    1)  Статус             показать конфигурацию
    2)  Добавить сервер    VLESS-подключение
    3)  Создать группу     urltest / selector
    4)  Добавить правило   маршрутизация трафика
    5)  Применить          проверить и перезапустить

    6)  Удалить сервер     убрать outbound
    7)  Удалить правило    убрать правило

    0)  Выход
```

Также доступен прямой вызов без меню:

```bash
sudo ./singbox.sh status    # показать статус
sudo ./singbox.sh apply     # применить конфигурацию
```

---

### Пошаговая настройка sing-box (примеры)

После установки sing-box работает, но весь трафик идёт напрямую.
Ниже — полный пример настройки с двумя VPN-серверами, failover и умной маршрутизацией.

#### Шаг 1. Добавить VLESS-серверы

Запустите `sudo ./singbox.sh` и выберите пункт **2** (Добавить сервер).

**Способ A — вставить URI-ссылку** (самый быстрый):

```
  Способ добавления:
    1) Вставить VLESS URI (vless://...)
    2) Ввести параметры вручную
  Выбор [1]: 1

  VLESS URI: vless://uuid@server:443?type=tcp&security=reality&...#NL-Amsterdam
```

Скрипт автоматически распарсит все параметры и покажет сводку для подтверждения.

**Способ B — ввод вручную** (если нет URI):

```
  Выбор [1]: 2

  Тег (имя): DE-Frankfurt
  Сервер: vpn-de.example.com
  Порт [443]: 443
  UUID: a1b2c3d4-...
  Flow []: xtls-rprx-vision
  Безопасность:  1) none  2) tls  3) reality
  Выбор [1]: 3
  ...
```

Повторите для каждого сервера.

#### Шаг 2. Создать группу (failover + автовыбор)

Выберите пункт **3** (Создать группу):

```
  VLESS-серверы
  ──────────────────────────────────────────
   1  NL-Amsterdam             vpn-nl.example.com:443
   2  DE-Frankfurt             vpn-de.example.com:443

  Тег группы [proxy]: proxy
  Тип группы:
    1) urltest   — автовыбор лучшего + failover
    2) selector  — ручной выбор
  Выбор [1]: 1
  Номера серверов через пробел или 'all':
  Выбор [all]: all
```

**Что это даёт:**
- sing-box каждые 3 минуты пингует оба сервера
- Автоматически выбирает лучший по latency
- Если один сервер упал — мгновенно переключается на другой
- DNS для VPN-доменов резолвится через DoH по VPN-туннелю

#### Шаг 3. Добавить правила маршрутизации

Выберите пункт **4** (Добавить правило):

```
  Тип правила:

    Ручные (высший приоритет):
    1) domain          точное совпадение
    2) domain_suffix   суффикс (*.example.com)
    3) domain_keyword  ключевое слово
    4) ip_cidr         подсеть IP

    Rule-set (community списки):
    5) geosite         категория (youtube, google...)
    6) geoip           страна по IP (ru, us...)

  Выбор [5]: 5

  Категории geosite:
    1) youtube    5) twitter    9) openai
    2) google     6) telegram  10) другое
    3) facebook   7) netflix
    4) instagram  8) tiktok
  Выбор [10]: 1

  Outbound (номер): 3   (proxy)
```

Скрипт автоматически:
- Скачает rule-set `geosite-youtube`
- Добавит правило: `geosite-youtube → proxy`
- Добавит DNS-правило: `geosite-youtube → dns-vpn` (split DNS)

**Ещё примеры:**
- Google через VPN: geosite → google → outbound: proxy
- `*.openai.com` через VPN: domain_suffix → openai.com → outbound: proxy
- Российские IP напрямую: geoip → ru → outbound: direct

Ручные правила имеют **приоритет выше** чем geosite/geoip.

#### Шаг 4. Применить конфигурацию

Выберите пункт **5** (Применить) — скрипт проверит конфиг и перезапустит сервис.

> Каждая операция добавления/удаления предлагает применить изменения сразу. Если добавляете несколько правил подряд — отвечайте `n`, а в конце примените один раз.

#### Шаг 5. Проверить статус

Выберите пункт **1** (Статус):

```
  Сервис:          active
  Версия:          1.13.5
  TUN:             tun0 (172.19.0.1/30)
  TUN статус:      UP
  Proxy:           :2080 (SOCKS5 + HTTP)

  Серверы и группы
  ──────────────────────────────────────────
   1  [vless]    NL-Amsterdam           vpn-nl.example.com:443
   2  [vless]    DE-Frankfurt           vpn-de.example.com:443
   3  [urltest]  proxy                  NL-Amsterdam, DE-Frankfurt
   4  [direct]   direct
   5  [block]    block

  Правила маршрутизации
  ──────────────────────────────────────────
   1  action: sniff
   2  protocol: dns          action: hijack-dns
   3  inbound: proxy-in           → proxy
   4  domain_suffix: openai.com   → proxy  [manual]
   5  rule-set: geosite-youtube   → proxy
   6  rule-set: geosite-google    → proxy
   7  rule-set: geoip-ru          → direct
   8  * (final)                   → direct

  DNS
  ──────────────────────────────────────────
  dns-direct:    udp://8.8.8.8  (detour: -)
  dns-vpn:       https://1.1.1.1  (detour: proxy)
  ··············································
  rule-set: geosite-youtube      → dns-vpn
  rule-set: geosite-google       → dns-vpn
  domain_suffix: openai.com      → dns-vpn
  * (final) → dns-direct
```

---

### Использование proxy (SOCKS/HTTP)

Для устройств или программ, которые нужно **целиком** пустить через VPN (весь трафик, не только по правилам), настройте прокси:

| Параметр | Значение |
|----------|----------|
| Тип | SOCKS5 или HTTP |
| Адрес | IP роутера (например `192.168.10.1`) |
| Порт | `2080` (по умолчанию) |

**Пример настройки в браузере (Firefox):**

Настройки → Сеть → Прокси → Ручная настройка → SOCKS-хост: `192.168.10.1`, Порт: `2080`, SOCKS v5.

**Пример curl через прокси:**

```bash
curl -x socks5://192.168.10.1:2080 https://ifconfig.me
```

**Разница TUN vs Proxy:**

| | TUN (прозрачный) | Proxy (SOCKS/HTTP) |
|---|---|---|
| Настройка на клиенте | Не нужна | Нужно прописать прокси |
| Маршрутизация | По правилам (YouTube → VPN, остальное → direct) | **Весь** трафик через VPN |
| Для чего | Все устройства в сети | Отдельное устройство/ПО |

---

### Управление сервисом sing-box

```bash
# Статус
sudo systemctl status sing-box

# Логи (последние 50 строк)
sudo journalctl -u sing-box -n 50 --no-pager

# Логи в реальном времени
sudo journalctl -u sing-box -f

# Перезапуск
sudo systemctl restart sing-box

# Остановка
sudo systemctl stop sing-box
```

### Конфиг sing-box

Конфиг находится в `/etc/sing-box/config.json`. Скрипты управления изменяют его автоматически, но при необходимости можно редактировать вручную:

```bash
sudo nano /etc/sing-box/config.json

# Проверить валидность
sudo sing-box check -c /etc/sing-box/config.json

# Применить
sudo systemctl restart sing-box
```

Бэкапы конфига сохраняются в `/root/singbox-backup/` при каждом изменении через скрипты.

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
