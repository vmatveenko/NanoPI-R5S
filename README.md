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

---

## Ручная настройка после прошивки ОС

> **Выполняется вручную через консоль (UART/SSH) сразу после прошивки
> официального образа Ubuntu (FriendlyELEC) на eMMC.**
> Интернета на этом этапе может не быть — скрипты из репозитория недоступны.

### 1. Вход и смена пароля

По умолчанию: `root` / `fa`

```bash
passwd
```

### 2. Проверка загрузки с eMMC

```bash
lsblk
```

Корневой раздел должен быть на `mmcblk1` (eMMC).
Если на `mmcblk0` — система загрузилась с SD-карты, извлеките её и перезагрузитесь.

### 3. Проверка версии ОС

```bash
lsb_release -a
# или
cat /etc/os-release
uname -r
```

### 4. Проверка сетевых интерфейсов

```bash
ip a
ip link
```

Убедитесь, что `eth0`, `eth1`, `eth2` присутствуют.

### 5. Диагностика интернета (WAN)

```bash
# Есть ли IP на WAN?
ip a show eth0

# Есть ли маршрут по умолчанию?
ip route

# Пинг по IP (без DNS)
ping -c 3 8.8.8.8

# Пинг по домену (нужен DNS)
ping -c 3 google.com
```

**Возможные ситуации:**

| ping 8.8.8.8 | ping google.com | Проблема | Решение |
|:---:|:---:|---|---|
| ✅ | ✅ | Нет проблем | Переходите к шагу 8 |
| ✅ | ❌ | Нет DNS | Шаг 6 |
| ❌ | ❌ | Нет интернета | Шаг 7, затем 6 |

### 6. Исправление DNS (типичная проблема FriendlyELEC)

**Суть проблемы:** `/etc/resolv.conf` — битый symlink на `systemd-resolved`,
который не запущен (`inactive (dead)`). Домены не резолвятся.

Проверяем:

```bash
ls -l /etc/resolv.conf
# Если видите красный файл или:
#   /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
# — это оно.

systemctl status systemd-resolved
# Скорее всего: inactive (dead)
```

Исправляем:

```bash
# Отключаем systemd-resolved (не нужен на роутере)
systemctl disable systemd-resolved
systemctl stop systemd-resolved

# Удаляем битый symlink
rm /etc/resolv.conf

# Создаём нормальный файл DNS
cat > /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# Защищаем от перезаписи
chattr +i /etc/resolv.conf
```

Проверяем:

```bash
ping -c 3 google.com
# Должен работать
```

### 7. Если WAN не получает IP по DHCP

```bash
# Проверить статус линка
ip link show eth0
# Должно быть: state UP

# Принудительно запросить DHCP
dhclient eth0

# Или через networkctl
networkctl reconfigure eth0

# Проверить результат
ip a show eth0
ip route
ping -c 3 8.8.8.8
```

### 8. Обновление системы

```bash
apt update
apt upgrade -y
```

### 9. Установка git и клонирование проекта

```bash
apt install -y git
git clone <repo-url> ~/nanopi-router
cd ~/nanopi-router
chmod +x scripts/*.sh
```

После этого можно запускать скрипты из репозитория.

---

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
