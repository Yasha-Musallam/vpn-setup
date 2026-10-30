#!/usr/bin/env bash
# Проверка функций генерации конфигов AmneziaWG, извлечённых из 03-amneziawg.sh
set -euo pipefail
cd "$(dirname "$0")"

extract_fn() { # $1=файл $2=имя функции
  awk -v fn="$2" '
    $0 ~ "^"fn"\\(\\) \\{" {inf=1}
    inf {print}
    inf && /^\}$/ {exit}
  ' "$1"
}

SCRIPT=${1:-../03-amneziawg.sh}
[[ -f "$SCRIPT" ]] || { echo "нет файла $SCRIPT"; exit 1; }

# --- параметры, как в скрипте
STATE_DIR=$(mktemp -d)
AWG_DIR="$STATE_DIR/awg"; mkdir -p "$AWG_DIR"
IFACE=amneziawg0; PORT=55424
NET_V4=10.77.0; SUBNET_V4=${NET_V4}.0/24; SERVER_V4=${NET_V4}.1
NET_V6_PREFIX=fd77; SUBNET_V6=fd77:77:0::/64; SERVER_V6=fd77:77:0::1
DNS1=1.1.1.1; DNS2=8.8.8.8; MTU=1280
JC=3; JMIN=10; JMAX=30; S1=30; S2=40; S3=15; S4=12
H1=1145255997; H2=1145255998; H3=1145255999; H4=1145256000
I1='<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>'
SRV_PRIV=YPrivKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
SRV_PUB=YPubKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
SERVER_IP4=203.0.113.10; SERVER_IP6=2001:db8::10
PEERS_DB="$STATE_DIR/awg-peers.tsv"
printf 'owner\tprivA\tpubA\tpskA\t10.77.0.2\tfd77:77:0::2\nwife\tprivB\tpubB\tpskB\t10.77.0.3\tfd77:77:0::3\n' > "$PEERS_DB"

eval "$(extract_fn "$SCRIPT" write_server_conf)"
eval "$(extract_fn "$SCRIPT" make_client_conf)"

check() { if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; exit 1; fi; }

for HAVE_V6 in 1 0; do
  echo
  echo "=== HAVE_V6=$HAVE_V6 ==="
  ADDR_LINE="${SERVER_V4}/24"
  [[ $HAVE_V6 -eq 1 ]] && ADDR_LINE="${ADDR_LINE}, ${SERVER_V6}/64"

  write_server_conf
  conf="$AWG_DIR/${IFACE}.conf"

  check "конфиг создан" "[[ -s '$conf' ]]"
  check "есть [Interface]" "grep -q '^\[Interface\]' '$conf'"
  check "Address корректен" "grep -qx 'Address = $ADDR_LINE' '$conf'"
  check "ListenPort" "grep -qx 'ListenPort = 55424' '$conf'"
  check "Jc" "grep -qx 'Jc = 3' '$conf'"
  check "I1 с пробелами внутри значения" "grep -qF 'I1 = <r 2><b 0x8580' '$conf'"
  check "два [Peer]" "[[ \$(grep -c '^\[Peer\]' '$conf') -eq 2 ]]"
  check "комментарий с именем клиента" "grep -q '# client: wife' '$conf'"
  if [[ $HAVE_V6 -eq 1 ]]; then
    check "AllowedIPs с IPv6" "grep -q 'AllowedIPs = 10.77.0.3/32, fd77:77:0::3/128' '$conf'"
    check "Address содержит IPv6" "grep -q 'fd77:77:0::1/64' '$conf'"
  else
    check "AllowedIPs без IPv6" "grep -qx 'AllowedIPs = 10.77.0.3/32' '$conf'"
    check "Address без IPv6" "! grep -q 'fd77' '$conf'"
  fi

  # клиентский конфиг
  cl="$STATE_DIR/owner.conf"
  make_client_conf privA pskA 10.77.0.2 fd77:77:0::2 "${SERVER_IP4}:${PORT}" > "$cl"
  check "клиент: [Interface]" "grep -q '^\[Interface\]' '$cl'"
  check "клиент: PrivateKey" "grep -qx 'PrivateKey = privA' '$cl'"
  check "клиент: Endpoint" "grep -qx 'Endpoint = 203.0.113.10:55424' '$cl'"
  check "клиент: PresharedKey" "grep -qx 'PresharedKey = pskA' '$cl'"
  check "клиент: PersistentKeepalive" "grep -qx 'PersistentKeepalive = 25' '$cl'"
  if [[ $HAVE_V6 -eq 1 ]]; then
    check "клиент: AllowedIPs оба стека" "grep -qx 'AllowedIPs = 0.0.0.0/0, ::/0' '$cl'"
  else
    check "клиент: AllowedIPs только IPv4" "grep -qx 'AllowedIPs = 0.0.0.0/0' '$cl'"
  fi

  # проверка, что awg setconf не подавится: удаляем служебные ключи
  grep -vE '^[[:space:]]*(Address|DNS|MTU|Table|PreUp|PreDown|PostUp|PostDown|SaveConfig)[[:space:]]*=' "$conf" > "$STATE_DIR/stripped.conf"
  check "strip: нет Address"  "! grep -q '^Address' '$STATE_DIR/stripped.conf'"
  check "strip: нет MTU"      "! grep -q '^MTU' '$STATE_DIR/stripped.conf'"
  check "strip: остался Jc"   "grep -qx 'Jc = 3' '$STATE_DIR/stripped.conf'"
  check "strip: остались Peer" "[[ \$(grep -c '^\[Peer\]' '$STATE_DIR/stripped.conf') -eq 2 ]]"
done

rm -rf "$STATE_DIR"
echo
echo "ГЕНЕРАЦИЯ КОНФИГОВ AMNEZIAWG: ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
