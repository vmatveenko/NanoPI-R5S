# NanoPi Manager

NanoPi Manager превращает чистую Ubuntu/Armbian ARM64-систему в управляемый IPv4-маршрутизатор с локальным web-интерфейсом, Docker, 3x-ui и Xray TUN.

Проект не привязан к именам `eth0`, `eth1`, `eth2`: WAN и несколько LAN-портов выбираются после обнаружения интерфейсов.

## Текущий статус

Ветка `feature/nanopi-manager` содержит локальную реализацию итерации 02. Go-тесты и `go vet` проходят, Linux-бинарники собираются для ARM64 и AMD64. Сетевые изменения, постоянный откат, обновление Manager, TUN и внешний VPN-inbound должны быть проверены вручную на NanoPi перед публикацией релиза.

## Архитектура

```text
Browser (LAN)
    |
    v
nanopi-manager-web (unprivileged, HTTP :8080)
    |
    | typed API over /run/nanopi-manager/agent.sock
    v
nanopi-manager-agent (root)
    |-- Netplan / DHCP / sysctl / nftables
    |-- Docker / 3x-ui
    `-- policy routing watchdog

LAN bridge -> nft mark -> ip rule/table 100 -> xray0 -> Xray outbound
Host traffic ---------------------------------------------> main/direct route
```

Web-процесс не принимает произвольные shell-команды. Привилегированный agent предоставляет только фиксированный набор операций.

## Возможности

- первый вход с созданием одного локального администратора и смена пароля с завершением всех сеансов;
- PBKDF2-SHA256 для пароля, серверные сессии, CSRF и ограничение попыток входа;
- обнаружение физических интерфейсов и текущего default route;
- выбор одного WAN и нескольких LAN-портов;
- bridge, LAN CIDR, DHCP range, DNS и режим MAC WAN;
- предварительный план и полный diff конфигурационных файлов;
- backup перед применением, автоматический rollback через 120 секунд и постоянное отключение режима с возвратом к исходному состоянию;
- WAN default-drop и опциональное открытие текущего HTTP-порта Manager с фильтром IPv4/CIDR;
- отдельный редактор пользовательских TCP/UDP WAN-правил с описанием, выключением и фильтрами источников;
- защищённые от редактирования системные правила firewall;
- вертикальная навигация по разделам;
- установка Docker, состояние daemon и список всех контейнеров с restart policy;
- отдельный раздел 3x-ui/Xray, доступный после запуска Docker;
- ручная проверка GitHub Releases и обновление/понижение Manager с SHA256, резервной копией, health check и автоматическим возвратом бинарников;
- воспроизводимый образ 3x-ui `v3.6.0`, соответствующий проверенному API-адаптеру;
- создание `xray0` через официальный API 3x-ui;
- policy routing только для транзитного LAN-трафика;
- watchdog с fail-open: при остановке Xray правило уходит, LAN возвращается в direct;
- диагностика основных компонентов;

## Поддерживаемая первая платформа

- Ubuntu 24.04 / совместимая Armbian;
- systemd + Netplan;
- nftables;
- `arm64` и `amd64` для разработки/тестирования;
- только IPv4.

Первая аппаратная проверка рассчитана на NanoPi R5S LTS с Ubuntu 24.04.4 и kernel 6.1.141.

## Установка

Установщик использует готовые бинарники из последнего GitHub Release. Go на устройстве для обычной установки не нужен:

```bash
git clone --branch v0.1.1 --depth 1 https://github.com/vmatveenko/NanoPI-R5S.git ~/nanopi-manager
cd ~/nanopi-manager
chmod +x scripts/install-manager.sh
sudo ./scripts/install-manager.sh install
```

Для установки конкретной версии задайте тег:

```bash
sudo NANOPI_MANAGER_VERSION=v0.1.1 ./scripts/install-manager.sh install
```

Для разработки можно собрать текущий checkout на устройстве:

```bash
sudo NANOPI_MANAGER_BUILD_FROM_SOURCE=1 ./scripts/install-manager.sh
```

Также можно передать готовые файлы:

```bash
sudo NANOPI_MANAGER_WEB_BINARY=/path/to/nanopi-manager-web \
     NANOPI_MANAGER_AGENT_BINARY=/path/to/nanopi-manager-agent \
     ./scripts/install-manager.sh install
```

Откройте `http://<текущий-IP-NanoPi>:8080` и создайте логин и пароль администратора.

> До применения router firewall Manager слушает `0.0.0.0:8080`. После применения порт разрешён с LAN bridge и закрыт с WAN.

Подробности: [установка](docs/installation.md), [архитектура и безопасность](docs/architecture.md).

## Порядок настройки

1. Установить Manager и создать администратора.
2. В разделе «Маршрутизатор» выбрать WAN/LAN и параметры DHCP.
3. Проверить план, применить и подтвердить связь за 120 секунд.
4. Установить Docker.
5. Установить 3x-ui.
6. В 3x-ui сменить его стандартные учётные данные и создать API token.
7. В Manager создать/проверить Xray TUN, передав токен один раз.
8. Пользовательские VLESS/Hysteria2 inbound и outbound создать в 3x-ui.
9. Во вкладке «Firewall» явно добавить соответствующий TCP/UDP-порт и при необходимости ограничить источники IPv4/CIDR.

## Разработка

```bash
cd manager
go test ./...
go build ./cmd/nanopi-manager-web ./cmd/nanopi-manager-agent
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./cmd/nanopi-manager-web ./cmd/nanopi-manager-agent
```

Бинарники не имеют runtime-зависимости от Go и собираются с `CGO_ENABLED=0`.

## Ограничения итерации 02

- HTTP без Caddy/HTTPS;
- один администратор;
- WAN только DHCP;
- PPPoE, IPv6 и DNS hijack отложены;
- WAN-доступ к Manager остаётся обычным HTTP без TLS и по умолчанию выключен;
- firewall-редактор не управляет системными правилами, DNAT, исходящими правилами и IPv6;
- автоматического обновления нет: проверка и установка версии запускаются администратором вручную;
- пользовательские VPN-inbound/outbound настраиваются в 3x-ui;
- реальное применение сетевой конфигурации выполняйте только при наличии локального доступа к устройству.
