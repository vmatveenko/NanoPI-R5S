# Установка и эксплуатация

## Предварительные условия

- Ubuntu 24.04/Armbian с systemd и Netplan;
- root или sudo;
- локальный доступ на случай ошибки сети;
- доступ в интернет для apt и, при сборке из checkout, загрузки Go toolchain.

## Установка

```bash
sudo apt-get update
sudo apt-get install -y git
git clone --branch v0.2.0 --depth 1 https://github.com/vmatveenko/NanoPI-R5S.git ~/nanopi-manager
cd ~/nanopi-manager
chmod +x scripts/install-manager.sh
sudo ./scripts/install-manager.sh install
systemctl status nanopi-manager-agent nanopi-manager-web --no-pager
```

По умолчанию установщик скачивает готовые бинарники `arm64` или `amd64` из последнего GitHub Release. Для фиксированной версии:

```bash
sudo NANOPI_MANAGER_VERSION=v0.2.0 ./scripts/install-manager.sh install
```

Сборка текущего checkout вместо загрузки Release включается явно:

```bash
sudo NANOPI_MANAGER_BUILD_FROM_SOURCE=1 ./scripts/install-manager.sh
```

По умолчанию UI работает на `0.0.0.0:8080`. Порт меняется в разделе «Маршрутизатор»: Manager синхронно обновляет environment-файл, применяет firewall и с задержкой перезапускает web-службу. Открытая страница проверяет новый порт и LAN-адрес, автоматически подтверждает доступность и переходит на рабочий URL. Если ответа нет, через 120 секунд восстанавливается предыдущая конфигурация.

После применения режима Manager доступен из LAN. Доступ с WAN включается отдельным флажком, который создаёт обычное TCP-правило в Firewall. По умолчанию источник не ограничен; при внешнем HTTP-доступе рекомендуется отредактировать правило и указать доверенные IPv4/CIDR.

## Логи

```bash
sudo journalctl -u nanopi-manager-web -u nanopi-manager-agent -n 200 --no-pager
sudo journalctl -u nanopi-manager-policy.service -n 100 --no-pager
```

## Backup

- router revisions: `/var/lib/nanopi-manager/backups`;
- исходная точка постоянного отката: `/var/lib/nanopi-manager/router-baseline.json`;
- 3x-ui backups: `/var/lib/nanopi-manager/xui-backups`;
- активные данные 3x-ui: `/opt/nanopi-manager/3x-ui`.

Эти каталоги могут содержать чувствительные настройки и должны иметь доступ только root/службы Manager.

## Обновление Manager

Проверка и установка версии запускаются вручную на странице «Обзор». По умолчанию показываются только стабильные релизы. Предварительные и более старые версии требуют отдельного подтверждения. Перед заменой бинарников создаётся backup; при неуспешном health check служба автоматически возвращается к предыдущей версии.

## Удаление Manager

```bash
sudo ./scripts/install-manager.sh uninstall
```

Удаляются службы и бинарники. Сеть, данные 3x-ui и backup сохраняются, чтобы удаление панели не превратилось в разрушительную операцию.
