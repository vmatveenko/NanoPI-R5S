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
   Локальная сеть ◄─┤  eth1 ─┐               │
                    │        ├─ br0  (LAN)    │
   Локальная сеть ◄─┤  eth2 ─┘               │
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

## Быстрый старт

```bash
cd ~/nanopi-router
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

## Проброс портов

Для проброса портов отредактируйте `/etc/nftables.conf`, цепочка `prerouting`:

```bash
# Пример: проброс порта 8080 с WAN на 192.168.10.100:80
iifname "eth0" tcp dport 8080 dnat to 192.168.10.100:80
```

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
