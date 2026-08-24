# Архитектура NanoPi Manager

## Граница привилегий

`nanopi-manager-web` работает от системного пользователя `nanopi-manager`. Он обслуживает UI, аутентификацию и локальное состояние, но не имеет root-доступа.

`nanopi-manager-agent` работает от root. Он слушает Unix socket с режимом `0660`, принадлежащий группе `nanopi-manager`, и предоставляет только типизированные HTTP-операции. Аргумент «выполнить команду» отсутствует.

## Безопасное применение сети

1. Проверяется модель: интерфейсы, роли, IPv4 CIDR, DHCP, DNS, MAC и WAN-порты.
2. Формируется детерминированный набор Netplan/DHCP/sysctl/nftables-файлов.
3. Текущие целевые файлы сохраняются в `/var/lib/nanopi-manager/backups/<revision>`.
4. Новые файлы записываются атомарно.
5. Выполняются `netplan generate`, `dhcpd -t` и `nft -c`.
6. До `netplan apply` создаётся systemd rollback unit на 120 секунд.
7. Пользователь подтверждает доступ из web UI; без подтверждения agent восстанавливает backup.

## Firewall

- policy input на WAN: drop;
- loopback, established/related и ICMP разрешены;
- весь input с LAN bridge разрешён;
- панели 8080/2053 не добавляются в WAN set;
- VLESS/Hysteria2 порты входят в WAN set только после явного добавления;
- forward разрешает LAN→WAN, LAN↔xray0 и established/related;
- NAT masquerade применяется только на WAN.

## LAN-only TUN

nftables ставит mark `0x1` только пакетам, пришедшим с LAN bridge. Правило `ip rule` с priority 10000 направляет этот mark в table 100, где default route использует `xray0`.

Local/host traffic не получает mark и использует main table. Входящие VPN-соединения завершаются локальным Xray и также не попадают в TUN автоматически.

Таймер `nanopi-manager-policy.timer` каждые 10 секунд проверяет контейнер 3x-ui и `xray0`:

- оба работают — маршрут и правило восстанавливаются;
- любой компонент не работает — policy rule удаляется, LAN использует direct main route.

## 3x-ui

Контейнер использует проверенный стабильный образ `ghcr.io/mhsanaei/3x-ui:v3.6.0`, host network, `/dev/net/tun`, `NET_ADMIN` и `NET_RAW`. Данные находятся в `/opt/nanopi-manager/3x-ui/db`, сертификаты — в `cert`.

TUN создаётся вызовом `/panel/api/inbounds/add` с Bearer API token. Manager принимает только URL loopback (`127.0.0.1`, `localhost`, `::1`), не сохраняет токен и передаёт 3x-ui актуальный формат TUN settings.
