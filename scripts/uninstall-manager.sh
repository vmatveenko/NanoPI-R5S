#!/bin/bash
# Removes NanoPi Manager services and binaries. Router configuration is preserved.
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Запустите от root: sudo $0" >&2
  exit 1
fi

systemctl disable --now nanopi-manager-policy.timer nanopi-manager-web.service nanopi-manager-agent.service 2>/dev/null || true
for unit in nanopi-manager-policy.timer nanopi-manager-policy.service nanopi-manager-web.service nanopi-manager-agent.service; do
  rm -f -- "/etc/systemd/system/$unit"
done
rm -f -- /run/nanopi-manager/agent.sock
rm -rf -- /usr/local/lib/nanopi-manager
systemctl daemon-reload

echo "NanoPi Manager удалён."
echo "Сетевые настройки, резервные копии и /var/lib/nanopi-manager сохранены."
echo "Для их удаления используйте отдельное явное действие после проверки содержимого."

