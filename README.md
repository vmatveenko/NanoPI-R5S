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
2. Скачивает последнюю версию sing-box с GitHub
3. Создаёт systemd-сервис
4. Запрашивает параметры (порт proxy, TUN-адрес, DNS)
5. Генерирует базовый конфиг (весь трафик → direct)
6. Добавляет правила `tun0` в nftables
7. Запускает sing-box

При повторном запуске: обновляет бинарник и nftables, **не трогает конфиг** (сохраняет VPN и правила).

> **Важно:** после повторного запуска `01-router-setup.sh` необходимо перезапустить `02-singbox-install.sh` для восстановления nftables-правил sing-box.

---

### Пошаговая настройка sing-box (примеры)

После установки sing-box работает, но весь трафик идёт напрямую.
Ниже — полный пример настройки с двумя VPN-серверами, failover и умной маршрутизацией.

#### Шаг 1. Добавить VLESS-серверы

**Способ A — вставить URI-ссылку** (самый быстрый):

```bash
sudo ./scripts/singbox-add-vless.sh
```

Скрипт спросит способ ввода — выберите `1` и вставьте ссылку от провайдера:

```
  Способ добавления:
    1) Вставить VLESS URI (ссылка vless://...)
    2) Ввести параметры вручную
  Выбор [1]: 1

  Вставьте VLESS URI: vless://a1b2c3d4-5678-90ab-cdef-1234567890ab@vpn-nl.example.com:443?type=tcp&security=reality&pbk=XXXX&sid=abcd&sni=www.google.com&fp=chrome&flow=xtls-rprx-vision#NL-Amsterdam
```

Скрипт автоматически распарсит все параметры (сервер, порт, UUID, Reality ключи, SNI и т.д.) и покажет сводку для подтверждения.

**Способ B — ввод вручную** (если нет URI):

```bash
sudo ./scripts/singbox-add-vless.sh
```

```
  Выбор [1]: 2

  Тег (имя подключения): DE-Frankfurt
  Адрес сервера: vpn-de.example.com
  Порт [443]: 443
  UUID: a1b2c3d4-5678-90ab-cdef-1234567890ab
  Flow (пусто / xtls-rprx-vision) []: xtls-rprx-vision

  Безопасность:
    1) none
    2) tls
    3) reality
  Выбор [1]: 3

  SNI (server name): www.google.com
  Fingerprint [chrome]: chrome
  ALPN []:
  Reality public key: XXXXXXXXXXXXXXXXXXXX
  Reality short ID []: abcd1234

  Транспорт:
    1) tcp
    2) ws (WebSocket)
    3) grpc
  Выбор [1]: 1
```

Повторите для каждого сервера. Например, добавьте два: `NL-Amsterdam` и `DE-Frankfurt`.

#### Шаг 2. Создать группу (failover + автовыбор)

```bash
sudo ./scripts/singbox-add-group.sh
```

```
  Доступные VLESS-подключения:
    1) NL-Amsterdam  →  vpn-nl.example.com:443
    2) DE-Frankfurt  →  vpn-de.example.com:443

  Тег группы [proxy]: proxy

  Тип группы:
    1) urltest  — автоматический выбор лучшего + failover
    2) selector — ручной выбор
  Выбор [1]: 1

  Введите номера подключений через пробел (или 'all' для всех):
  Выбор [all]: all

  Настройка health-check:
  URL проверки [https://www.gstatic.com/generate_204]:
  Интервал проверки [3m]:
  Tolerance, мс [50]:

  Использовать 'proxy' для proxy-inbound (SOCKS/HTTP → VPN)? [Y/n]: Y
  Использовать 'proxy' для VPN DNS (split DNS)? [Y/n]: Y
```

**Что это даёт:**
- sing-box каждые 3 минуты пингует оба сервера
- Автоматически выбирает лучший по latency
- Если один сервер упал — мгновенно переключается на другой
- Весь трафик через proxy-порт (SOCKS/HTTP) идёт через VPN-группу
- DNS для VPN-доменов резолвится через DoH по VPN-туннелю

#### Шаг 3. Добавить правила маршрутизации

**Пример: YouTube через VPN**

```bash
sudo ./scripts/singbox-add-rule.sh
```

```
  Тип правила:
    --- Ручные (высший приоритет) ---
    1) domain         — точное совпадение домена
    2) domain_suffix  — суффикс домена (*.example.com)
    3) domain_keyword — ключевое слово в домене
    4) ip_cidr        — подсеть IP-адресов
    --- Rule-set (community списки) ---
    5) geosite        — категория сайтов (youtube, google, ...)
    6) geoip          — страна по IP (ru, us, ...)
  Выбор [5]: 5

  Популярные категории geosite:
    1) youtube      6) telegram
    2) google       7) netflix
    3) facebook     8) tiktok
    4) instagram    9) openai
    5) twitter     10) другое (ввести вручную)
  Выбор [10]: 1

  Доступные outbound'ы:
    1) [vless]     NL-Amsterdam
    2) [vless]     DE-Frankfurt
    3) [urltest]   proxy
    4) [direct]    direct
    5) [block]     block

  Outbound для этого правила (номер): 3
```

Скрипт автоматически:
- Скачает rule-set `geosite-youtube` (список всех YouTube-доменов)
- Добавит правило: `geosite-youtube → proxy`
- Добавит DNS-правило: `geosite-youtube → dns-vpn` (split DNS)

**Пример: Google через VPN**

```bash
sudo ./scripts/singbox-add-rule.sh
# Выбрать: 5 (geosite) → 2 (google) → outbound: proxy
```

**Пример: конкретный домен через VPN (ручное правило)**

```bash
sudo ./scripts/singbox-add-rule.sh
# Выбрать: 2 (domain_suffix) → ввести: openai.com → outbound: proxy
```

Это направит `*.openai.com` через VPN. Ручные правила имеют **приоритет выше** чем geosite/geoip.

**Пример: российские IP напрямую (bypass VPN)**

```bash
sudo ./scripts/singbox-add-rule.sh
# Выбрать: 6 (geoip) → 1 (ru) → outbound: direct
```

#### Шаг 4. Применить конфигурацию

```bash
sudo ./scripts/singbox-apply.sh
```

Скрипт проверит конфиг на ошибки (`sing-box check`) и перезапустит сервис.

> Каждый скрипт `add-*` также предлагает применить изменения сразу (на вопрос «Применить сейчас?»). Если вы добавляете несколько правил подряд — отвечайте `n`, а после всех добавлений запустите `singbox-apply.sh` один раз.

#### Шаг 5. Проверить статус

```bash
sudo ./scripts/singbox-status.sh
```

Пример вывода:

```
  Сервис:      active (running)
  Версия:      1.13.5
  TUN:         tun0 (172.19.0.1/30)
  Proxy:       :2080 (SOCKS5 + HTTP)
  TUN статус:  UP

═══ Outbound'ы ═══
   1. [vless     ] NL-Amsterdam        → vpn-nl.example.com:443
   2. [vless     ] DE-Frankfurt        → vpn-de.example.com:443
   3. [urltest   ] proxy               → NL-Amsterdam, DE-Frankfurt
   4. [direct    ] direct
   5. [block     ] block

═══ Правила маршрутизации ═══
   1. action: sniff
   2. protocol: dns           action: hijack-dns
   3. inbound: proxy-in            → proxy
   4. domain_suffix: openai.com    → proxy          [manual]
   5. rule-set: geosite-youtube    → proxy
   6. rule-set: geosite-google     → proxy
   7. rule-set: geoip-ru           → direct
   8. * (final)                    → direct

═══ DNS ═══
  dns-direct:    udp://8.8.8.8  (detour: -)
  dns-vpn:       https://1.1.1.1  (detour: proxy)
    Правила DNS:
    rule-set: geosite-youtube → dns-vpn
    rule-set: geosite-google  → dns-vpn
    domain_suffix: openai.com → dns-vpn
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
