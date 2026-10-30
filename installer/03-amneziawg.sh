#!/usr/bin/env bash
# =====================================================================
#  ШАГ 3. AmneziaWG — второй протокол (UDP + обфускация)
#  Это WireGuard, у которого заголовки и мусорные пакеты не совпадают
#  с сигнатурой WireGuard, поэтому его не режут «по шаблону».
#
#  Что создаётся:
#    интерфейс amneziawg0, UDP 55424, IPv4 10.77.0.0/24 (+ IPv6 fd77:77:0::/64)
#    клиентские файлы .conf в /etc/vpn-manager/amneziawg-clients/
#    автозапуск systemd + NAT после перезагрузки
#
#  Запуск:  bash 03-amneziawg.sh
#  Можно переопределить:  AWG_PORT=55424 bash 03-amneziawg.sh
# =====================================================================
set -euo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYA=$'\e[36m'; RST=$'\e[0m'
ok()   { echo "${GRN}[ OK ]${RST} $*"; }
info() { echo "${CYA}[ .. ]${RST} $*"; }
warn() { echo "${YEL}[ !! ]${RST} $*"; }
die()  { echo "${RED}[FAIL]${RST} $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запускать нужно от root"

STATE_DIR=/etc/vpn-manager
AWG_DIR=/etc/amnezia/amneziawg
CL_DIR="$STATE_DIR/amneziawg-clients"
IFACE=${AWG_IFACE:-amneziawg0}
PORT=${AWG_PORT:-55424}

NET_V4=10.77.0
SUBNET_V4=${NET_V4}.0/24
SERVER_V4=${NET_V4}.1
NET_V6_PREFIX=fd77
SUBNET_V6=${NET_V6_PREFIX}:77:0::/64
SERVER_V6=${NET_V6_PREFIX}:77:0::1

DNS1=${AWG_DNS1:-1.1.1.1}
DNS2=${AWG_DNS2:-8.8.8.8}
MTU=${AWG_MTU:-1280}

# --- Параметры обфускации. Должны совпадать на сервере и у клиента.
JC=${AWG_JC:-3}
JMIN=${AWG_JMIN:-10}
JMAX=${AWG_JMAX:-30}
S1=${AWG_S1:-30}
S2=${AWG_S2:-40}
S3=${AWG_S3:-15}
S4=${AWG_S4:-12}
H1=${AWG_H1:-1145255997}
H2=${AWG_H2:-1145255998}
H3=${AWG_H3:-1145255999}
H4=${AWG_H4:-1145256000}
I1=${AWG_I1:-'<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>'}

mkdir -p "$STATE_DIR" "$AWG_DIR" "$CL_DIR"
chmod 700 "$AWG_DIR" "$CL_DIR"
if [[ -f "$STATE_DIR/system.env" ]]; then . "$STATE_DIR/system.env"; fi
if [[ -z "${SERVER_IP4:-}" ]]; then
  SERVER_IP4=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
fi
[[ -n "${SERVER_IP4:-}" ]] || die "Не определён IPv4 сервера"
HAVE_V6=0; [[ -n "${SERVER_IP6:-}" ]] && HAVE_V6=1

echo
info "Параметры AmneziaWG:"
echo "      интерфейс : ${IFACE}"
echo "      UDP порт  : ${PORT}"
echo "      адрес VPN : ${SERVER_V4}/24"
[[ $HAVE_V6 -eq 1 ]] && echo "                  ${SERVER_V6}/64 (IPv6 включён)"
echo "      MTU       : ${MTU}"

# ---------------------------------------------------------------------
# 1. Пакеты
# ---------------------------------------------------------------------
if command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1; then
  ok "amneziawg-tools уже установлены"
else
  info "Подключаю репозиторий amnezia/ppa..."
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  add-apt-repository -y ppa:amnezia/ppa >/tmp/ppa.log 2>&1 || { tail -n 20 /tmp/ppa.log; die "PPA amnezia/ppa не подключился"; }
  apt-get update -y -qq

  info "Ставлю модуль ядра (DKMS) и утилиты — 1-5 минут..."
  apt-get -y -qq install "linux-headers-$(uname -r)" >/dev/null 2>&1 || warn "linux-headers для $(uname -r) не найдены"
  if ! apt-get -y -qq install amneziawg-tools amneziawg-dkms >/tmp/awg-install.log 2>&1; then
    warn "Установка с DKMS не удалась:"
    tail -n 25 /tmp/awg-install.log | sed 's/^/      /'
    info "Пробую поставить только утилиты..."
    apt-get -y -qq install amneziawg-tools >/dev/null 2>&1 || true
  fi
  command -v awg >/dev/null 2>&1 || die "amneziawg-tools не установились. Лог: /tmp/awg-install.log"
  ok "amneziawg-tools установлены: $(awg --version 2>/dev/null | head -n1)"
fi

# ---------------------------------------------------------------------
# 2. Режим работы: модуль ядра или userspace
# ---------------------------------------------------------------------
MODE=""
if modprobe amneziawg 2>/dev/null && lsmod | grep -q '^amneziawg'; then
  MODE="kernel"
  echo 'amneziawg' > /etc/modules-load.d/amneziawg.conf
  ok "Модуль ядра amneziawg загружен (быстрый режим)"
else
  warn "Модуль ядра недоступен (частая причина: обновилось ядро, нужна перезагрузка)"
  if ! command -v amneziawg-go >/dev/null 2>&1; then
    info "Ставлю userspace-реализацию amneziawg-go (2-5 минут)..."
    apt-get -y -qq install golang-go git make >/dev/null 2>&1 || true
    if command -v go >/dev/null 2>&1; then
      tmpd=$(mktemp -d)
      if git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-go "$tmpd/src" >/dev/null 2>&1; then
        ( cd "$tmpd/src" && make >/tmp/awg-go.log 2>&1 && install -m 0755 amneziawg-go /usr/local/bin/amneziawg-go ) \
          || warn "Сборка amneziawg-go не удалась (см. /tmp/awg-go.log)"
      else
        warn "Не удалось склонировать amneziawg-go"
      fi
      rm -rf "$tmpd"
    else
      warn "Пакет golang-go недоступен"
    fi
  fi
  command -v amneziawg-go >/dev/null 2>&1 || die "Нет ни модуля ядра, ни amneziawg-go. Сделайте 'reboot' и запустите шаг 3 снова."
  MODE="userspace"
  ok "Будет использован amneziawg-go (userspace, чуть медленнее, но работает всегда)"
fi
echo "$MODE" > "$STATE_DIR/awg-mode"

# ---------------------------------------------------------------------
# 3. Ключи сервера
# ---------------------------------------------------------------------
if [[ -s "$AWG_DIR/server_private.key" ]]; then
  SRV_PRIV=$(cat "$AWG_DIR/server_private.key")
  SRV_PUB=$(cat "$AWG_DIR/server_public.key")
  info "Использую существующие ключи сервера"
else
  SRV_PRIV=$(awg genkey)
  SRV_PUB=$(printf '%s' "$SRV_PRIV" | awg pubkey)
  printf '%s' "$SRV_PRIV" > "$AWG_DIR/server_private.key"
  printf '%s' "$SRV_PUB"  > "$AWG_DIR/server_public.key"
  ok "Сгенерирована пара ключей сервера"
fi
chmod 600 "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key"
ok "Публичный ключ сервера: ${SRV_PUB}"

# ---------------------------------------------------------------------
# 4. База клиентов + первый клиент
# ---------------------------------------------------------------------
PEERS_DB="$STATE_DIR/awg-peers.tsv"   # имя \t priv \t pub \t psk \t ipv4 \t ipv6
[[ -f "$PEERS_DB" ]] || : > "$PEERS_DB"
chmod 600 "$PEERS_DB"

if [[ ! -s "$PEERS_DB" ]]; then
  priv=$(awg genkey)
  pub=$(printf '%s' "$priv" | awg pubkey)
  psk=$(awg genpsk)
  printf 'owner\t%s\t%s\t%s\t%s\t%s\n' "$priv" "$pub" "$psk" "${NET_V4}.2" "${NET_V6_PREFIX}:77:0::2" >> "$PEERS_DB"
  ok "Создан первый клиент: owner"
fi
ok "Клиентов в базе: $(wc -l < "$PEERS_DB")"

# ---------------------------------------------------------------------
# 5. Генерация конфигов (функции используются и в 04-manager.sh)
# ---------------------------------------------------------------------
ADDR_LINE="${SERVER_V4}/24"
[[ $HAVE_V6 -eq 1 ]] && ADDR_LINE="${ADDR_LINE}, ${SERVER_V6}/64"

write_server_conf() {
  local name priv pub psk ipv4 ipv6
  {
    cat <<EOF
[Interface]
Address = ${ADDR_LINE}
ListenPort = ${PORT}
PrivateKey = ${SRV_PRIV}
MTU = ${MTU}
SaveConfig = false
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}
I1 = ${I1}
EOF
    while IFS=$'\t' read -r name priv pub psk ipv4 ipv6; do
      [[ -n "${name:-}" ]] || continue
      printf '\n[Peer]\n# client: %s\nPublicKey = %s\nPresharedKey = %s\n' "$name" "$pub" "$psk"
      if [[ $HAVE_V6 -eq 1 ]]; then
        printf 'AllowedIPs = %s/32, %s/128\n' "$ipv4" "$ipv6"
      else
        printf 'AllowedIPs = %s/32\n' "$ipv4"
      fi
    done < "$PEERS_DB"
  } > "$AWG_DIR/${IFACE}.conf"
  chmod 600 "$AWG_DIR/${IFACE}.conf"
}

make_client_conf() {   # $1=priv $2=psk $3=ipv4 $4=ipv6 $5=endpoint
  local priv="$1" psk="$2" ipv4="$3" ipv6="$4" endpoint="$5"
  if [[ $HAVE_V6 -eq 1 ]]; then
    printf '[Interface]\nPrivateKey = %s\nAddress = %s/32, %s/128\n' "$priv" "$ipv4" "$ipv6"
  else
    printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\n' "$priv" "$ipv4"
  fi
  cat <<EOF
DNS = ${DNS1}, ${DNS2}
MTU = ${MTU}
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}
I1 = ${I1}

[Peer]
PublicKey = ${SRV_PUB}
PresharedKey = ${psk}
Endpoint = ${endpoint}
EOF
  if [[ $HAVE_V6 -eq 1 ]]; then
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
  else
    echo "AllowedIPs = 0.0.0.0/0"
  fi
  echo "PersistentKeepalive = 25"
}

info "Пишу серверный конфиг ${AWG_DIR}/${IFACE}.conf"
write_server_conf

# ---------------------------------------------------------------------
# 6. NAT (IPv4 и IPv6) + MSS clamp
# ---------------------------------------------------------------------
WAN_IF=$(ip -4 route show default | awk '{print $5; exit}')
[[ -n "${WAN_IF:-}" ]] || die "Не найден внешний интерфейс"
ok "Внешний интерфейс: ${WAN_IF}"

cat > /usr/local/sbin/awg-nat.sh <<EOF
#!/bin/sh
# NAT для AmneziaWG. Создаётся установщиком, идемпотентен.
UPLINK="${WAN_IF}"
SUBNET_V4="${SUBNET_V4}"
SUBNET_V6="${SUBNET_V6}"
IFACE="${IFACE}"
HAVE_V6=${HAVE_V6}

# --- IPv4 ---
iptables -t nat -C POSTROUTING -s "\$SUBNET_V4" -o "\$UPLINK" -j MASQUERADE 2>/dev/null || \\
  iptables -t nat -A POSTROUTING -s "\$SUBNET_V4" -o "\$UPLINK" -j MASQUERADE
iptables -C FORWARD -i "\$IFACE" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "\$IFACE" -j ACCEPT
iptables -C FORWARD -o "\$IFACE" -j ACCEPT 2>/dev/null || iptables -A FORWARD -o "\$IFACE" -j ACCEPT
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \\
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# --- IPv6 (только если на сервере есть IPv6) ---
if [ "\$HAVE_V6" = "1" ] && command -v ip6tables >/dev/null 2>&1; then
  ip6tables -t nat -C POSTROUTING -s "\$SUBNET_V6" -o "\$UPLINK" -j MASQUERADE 2>/dev/null || \\
    ip6tables -t nat -A POSTROUTING -s "\$SUBNET_V6" -o "\$UPLINK" -j MASQUERADE 2>/dev/null || true
  ip6tables -C FORWARD -i "\$IFACE" -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -i "\$IFACE" -j ACCEPT
  ip6tables -C FORWARD -o "\$IFACE" -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -o "\$IFACE" -j ACCEPT
  ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \\
    ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi
exit 0
EOF
chmod 755 /usr/local/sbin/awg-nat.sh
/usr/local/sbin/awg-nat.sh && ok "NAT-правила применены"

# ---------------------------------------------------------------------
# 7. Подъём интерфейса
# ---------------------------------------------------------------------
awg-quick down "$IFACE" >/dev/null 2>&1 || true
ip link del "$IFACE" >/dev/null 2>&1 || true

info "Поднимаю ${IFACE}..."
if ! awg-quick up "$IFACE" 2>/tmp/awg-up.log; then
  tail -n 25 /tmp/awg-up.log | sed 's/^/      /'
  die "awg-quick up не удался"
fi
ok "Интерфейс ${IFACE} поднят ($(cat "$STATE_DIR/awg-mode") режим)"
awg show "$IFACE" | head -n 5 | sed 's/^/      /'

# ---------------------------------------------------------------------
# 8. Автозапуск
# ---------------------------------------------------------------------
systemctl enable "awg-quick@${IFACE}" >/dev/null 2>&1 || true
cat > /etc/systemd/system/awg-nat.service <<EOF
[Unit]
Description=NAT and forwarding rules for AmneziaWG
After=network-online.target awg-quick@${IFACE}.service
Wants=network-online.target
Requires=awg-quick@${IFACE}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/awg-nat.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable awg-nat.service >/dev/null 2>&1 || true
systemctl restart awg-nat.service >/dev/null 2>&1 || true
ok "Автозапуск включён: awg-quick@${IFACE} + awg-nat"

# ---------------------------------------------------------------------
# 9. Проверка маршрута наружу из VPN-подсети
# ---------------------------------------------------------------------
info "Проверяю, что трафик из ${SERVER_V4} уходит в интернет..."
if ping -c1 -W3 -I "${SERVER_V4}" 1.1.1.1 >/dev/null 2>&1; then
  ok "Маршрутизация работает"
else
  warn "ICMP не прошёл (провайдеры часто его режут) — проверьте с телефона, это не приговор"
fi

# ---------------------------------------------------------------------
# 10. Клиентские файлы
# ---------------------------------------------------------------------
write_clients() {
  local name priv pub psk ipv4 ipv6
  while IFS=$'\t' read -r name priv pub psk ipv4 ipv6; do
    [[ -n "${name:-}" ]] || continue
    make_client_conf "$priv" "$psk" "$ipv4" "$ipv6" "${SERVER_IP4}:${PORT}" > "$CL_DIR/${name}.conf"
    chmod 600 "$CL_DIR/${name}.conf"
    if [[ $HAVE_V6 -eq 1 ]]; then
      make_client_conf "$priv" "$psk" "$ipv4" "$ipv6" "[${SERVER_IP6}]:${PORT}" > "$CL_DIR/${name}-ipv6.conf"
      chmod 600 "$CL_DIR/${name}-ipv6.conf"
    fi
  done < "$PEERS_DB"
}
write_clients
ok "Клиентские файлы: ${CL_DIR}/"

cat > "$STATE_DIR/awg.env" <<EOF
IFACE=${IFACE}
AWG_PORT=${PORT}
SERVER_PUB=${SRV_PUB}
AWG_MODE=${MODE}
SUBNET_V4=${SUBNET_V4}
SUBNET_V6=${SUBNET_V6}
SERVER_V4=${SERVER_V4}
SERVER_V6=${SERVER_V6}
HAVE_V6=${HAVE_V6}
AWG_DNS1=${DNS1}
AWG_DNS2=${DNS2}
AWG_MTU=${MTU}
EOF
chmod 600 "$STATE_DIR/awg.env"

echo
ok "ШАГ 3 завершён. AmneziaWG работает."
cat <<EOF

  ═══ КОНФИГ ДЛЯ КЛИЕНТА ═══
      ${CL_DIR}/owner.conf        → ${SERVER_IP4}:${PORT}
$( [[ $HAVE_V6 -eq 1 ]] && echo "      ${CL_DIR}/owner-ipv6.conf   → [${SERVER_IP6}]:${PORT}" )

  Забрать файл к себе на компьютер (выполните на СВОЁМ ПК/в другом окне):
      scp root@${SERVER_IP4}:${CL_DIR}/owner.conf .

  Подключение:
      • Windows / macOS : приложение AmneziaWG → «Добавить туннель» → «Импорт из файла»
      • Android / iOS   : AmneziaWG → «+» → «Импорт файла конфигурации»
      • Keenetic        : Другие подключения → WireGuard → Загрузить из файла
      • OpenWRT         : интерфейс AmneziaWG с этим .conf

  Дальше:
    bash 04-manager.sh      # команда 'vpn' для создания клиентов

EOF
