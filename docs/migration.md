# Переход с sing-box и Telegram-бота

## 1. Удаление старого второго слоя

```bash
sudo ./scripts/00-remove-legacy-second-layer.sh
```

Будут сохранены в backup и удалены sing-box, `nanopi-bot`, старый sysctl и правила `br0`↔`tun0`. Netplan, DHCP, bridge и базовый NAT сохраняются.

## 2. Установка Manager

```bash
sudo ./scripts/install-manager.sh
```

## 3. Импорт параметров роутера

Откройте Manager по текущему LAN IP. Проверьте автоматически обнаруженные интерфейсы и укажите существующие LAN CIDR/DHCP/DNS. Перед применением Manager покажет создаваемые файлы.

Старый `/etc/netplan/01-router.yaml` заменяется безопасной заглушкой и входит в rollback backup; рабочая конфигурация записывается в `/etc/netplan/60-nanopi-manager.yaml`.

## 4. Установка 3x-ui и TUN

Установите Docker/3x-ui из UI, смените стандартные данные 3x-ui, создайте API token и передайте его форме TUN. Старые sing-box outbounds/rules автоматически не конвертируются — настройте их в 3x-ui вручную.

