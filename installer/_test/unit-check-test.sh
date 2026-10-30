#!/usr/bin/env bash
# =====================================================================
#  Проверка, что install-release.sh ставит именно тот юнит, под который
#  рассчитаны пути и права в 02-xray-reality.sh (User=xray, конфиг в
#  /usr/local/etc/xray, ExecStart ... run -config ...).
#  Работает по скачанному файлу установщика (без запуска).
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"
INS=${1:-../xray-install.sh}
[[ -f "$INS" ]] || { echo "нет файла установщика: $INS"; exit 1; }
echo "проверяю: $INS ($(wc -c < "$INS") байт)"

ok=0; bad=0
chk() { if eval "$2"; then echo "  OK   $1"; ok=$((ok+1)); else echo "  FAIL $1"; bad=$((bad+1)); fi; }

chk "юнит создаётся (install_startup_service_file)" "grep -q 'install_startup_service_file()' '$INS'"
chk "User=xray" "grep -q 'User=xray' '$INS'"
chk "Group=xray" "grep -q 'Group=xray' '$INS'"
chk "ExecStart использует /usr/local/bin/xray run" "grep -q 'ExecStart=/usr/local/bin/xray run' '$INS'"
chk "конфиг /usr/local/etc/xray/config.json" "grep -q '/usr/local/etc/xray' '$INS'"
chk "пользователь xray создаётся (systemd-sysusers)" "grep -q 'systemd-sysusers' '$INS'"
chk "есть create_xray_user" "grep -q 'create_xray_user()' '$INS'"
chk "каталог конфига 750 root:xray" "grep -q 'install -d -m 750 -o 0 -g xray' '$INS'"
chk "config.json 640 root:xray" "grep -q 'install -m 640 -o 0 -g xray' '$INS'"
chk "UMask задан" "grep -q 'UMask' '$INS'"
chk "RuntimeDirectory xray" "grep -q 'RuntimeDirectory=xray' '$INS'"
chk "Restart=on-failure" "grep -q 'Restart=on-failure' '$INS'"
chk "CAP_NET_BIND_SERVICE" "grep -q 'CAP_NET_BIND_SERVICE' '$INS'"
chk "systemctl enable xray" "grep -q 'systemctl enable xray' '$INS' || grep -q 'enable --now xray' '$INS'"
chk "есть uninstall-режим (remove_xray)" "grep -q 'remove_xray()' '$INS'"

echo
echo "  успешно: $ok   провалено: $bad"
[[ $bad -eq 0 ]] || exit 1
echo "СООТВЕТСТВИЕ ЮНИТА XRAY: OK"
