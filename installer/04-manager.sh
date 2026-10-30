#!/usr/bin/env bash
# =====================================================================
#  ШАГ 4. Менеджер пользователей — команда 'vpn'
#  Создание/удаление клиентов для обоих протоколов в одну команду.
#
#  Запуск:  bash 04-manager.sh
#  Потом:   vpn help
# =====================================================================
set -euo pipefail

GRN=$'\e[32m'; RST=$'\e[0m'
ok() { echo "${GRN}[ OK ]${RST} $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Запускать нужно от root" >&2; exit 1; }

cat > /usr/local/bin/vpn <<'VPN_SCRIPT'
#!/usr/bin/env bash
# =====================================================================
#  vpn — управление пользователями VPN
#  Протоколы: XRay (VLESS + Vision + REALITY) и AmneziaWG
#  Создан установщиком. Данные: /etc/vpn-manager
# =====================================================================
set -euo pipefail

STATE_DIR=/etc/vpn-manager
XRAY_DIR=/usr/local/etc/xray
XRAY_CONF="$XRAY_DIR/config.json"
AWG_DIR=/etc/amnezia/amneziawg
PEERS_DB="$STATE_DIR/awg-peers.tsv"
CL_DB="$STATE_DIR/xray-clients.json"
CL_DB2="$STATE_DIR/xray-clients2.json"
CL_DIR="$STATE_DIR/amneziawg-clients"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYA=$'\e[36m'; BLD=$'\e[1m'; RST=$'\e[0m'
ok()   { echo "${GRN}[ OK ]${RST} $*"; }
err()  { echo "${RED}[ERR]${RST} $*" >&2; }
warn() { echo "${YEL}[ !! ]${RST} $*"; }
head1(){ echo; echo "${BLD}$*${RST}"; }

. "$STATE_DIR/system.env" 2>/dev/null || true
. "$STATE_DIR/xray.env"   2>/dev/null || true
. "$STATE_DIR/awg.env"    2>/dev/null || true

IFACE=${IFACE:-amneziawg0}
AWG_PORT=${AWG_PORT:-55424}
PORT_MAIN=${PORT_MAIN:-443}
PORT_COMPAT=${PORT_COMPAT:-8443}
HAVE_V6=${HAVE_V6:-0}
AWG_DNS1=${AWG_DNS1:-1.1.1.1}
AWG_DNS2=${AWG_DNS2:-8.8.8.8}
AWG_MTU=${AWG_MTU:-1280}
SERVER_V4=${SERVER_V4:-10.77.0.1}
NET_V4=$(echo "$SERVER_V4" | cut -d. -f1-3)
NET_V6_PREFIX=fd77

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "нужен root: sudo vpn $*"; exit 1; }; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }

# =====================================================================
#  XRAY
# =====================================================================
xray_regen() {
  local vision plain
  # tr -d '\r' на случай запуска с Windows-машины (jq.exe добавляет CR)
  vision=$(jq -c '[to_entries[] | {id: .value, flow: "xtls-rprx-vision"}]' "$CL_DB" | tr -d '\r')
  plain=$(jq -c '[to_entries[] | {id: .value, flow: ""}]' "$CL_DB2" | tr -d '\r')
  jq --argjson v "$vision" --argjson p "$plain" '
    .inbounds[0].settings.clients = $v |
    .inbounds[1].settings.clients = $p
  ' "$XRAY_CONF" > "$XRAY_CONF.tmp" && mv "$XRAY_CONF.tmp" "$XRAY_CONF"
  chmod 640 "$XRAY_CONF"
  chown 0:xray "$XRAY_CONF" 2>/dev/null || true
}

xray_apply() {
  if ! xray run -test -config "$XRAY_CONF" >/tmp/vpn-xray-test.log 2>&1; then
    sed 's/^/    /' /tmp/vpn-xray-test.log >&2
    err "конфиг XRay невалиден — изменения НЕ применены"
    return 1
  fi
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray || { journalctl -u xray -n 20 --no-pager >&2; return 1; }
}

xray_links() {  # $1=имя -> печатает ссылки
  local name="$1" u1 u2
  u1=$(jq -r --arg n "$name" '.[$n] // empty' "$CL_DB")
  u2=$(jq -r --arg n "$name" '.[$n] // empty' "$CL_DB2")
  [[ -n "$u1" ]] || return 1
  local q1 q2
  q1="encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision"
  q2="encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp"
  echo "vless://${u1}@${SERVER_IP4}:${PORT_MAIN}?${q1}#${name}-vision"
  echo "vless://${u2}@${SERVER_IP4}:${PORT_COMPAT}?${q2}#${name}-novision"
  if [[ "$HAVE_V6" == "1" && -n "${SERVER_IP6:-}" ]]; then
    echo "vless://${u1}@[${SERVER_IP6}]:${PORT_MAIN}?${q1}#${name}-vision-v6"
  fi
}

# =====================================================================
#  AMNEZIAWG
# =====================================================================
cfg_get() {  # $1=ключ $2=значение по умолчанию — читает из текущего конфига
  local v
  v=$(awk -F' = ' -v k="$1" '$1==k {print $2; exit}' "$AWG_DIR/${IFACE}.conf" 2>/dev/null || true)
  echo "${v:-$2}"
}

awg_regen() {
  local name priv pub psk ipv4 ipv6 srv_priv
  srv_priv=$(cat "$AWG_DIR/server_private.key")
  # ВАЖНО: читаем текущие параметры обфускации ДО перезаписи файла,
  # иначе редирект обнулит конфиг и мы потеряем пользовательские значения.
  local v_jc v_jmin v_jmax v_s1 v_s2 v_s3 v_s4 v_h1 v_h2 v_h3 v_h4 v_i1
  v_jc=$(cfg_get Jc 3)
  v_jmin=$(cfg_get Jmin 10)
  v_jmax=$(cfg_get Jmax 30)
  v_s1=$(cfg_get S1 30)
  v_s2=$(cfg_get S2 40)
  v_s3=$(cfg_get S3 15)
  v_s4=$(cfg_get S4 12)
  v_h1=$(cfg_get H1 1145255997)
  v_h2=$(cfg_get H2 1145255998)
  v_h3=$(cfg_get H3 1145255999)
  v_h4=$(cfg_get H4 1145256000)
  v_i1=$(cfg_get I1 '<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>')

  {
    if [[ "$HAVE_V6" == "1" ]]; then
      printf '[Interface]\nAddress = %s/24, %s/64\n' "$SERVER_V4" "${NET_V6_PREFIX}:77:0::1"
    else
      printf '[Interface]\nAddress = %s/24\n' "$SERVER_V4"
    fi
    cat <<EOF
ListenPort = ${AWG_PORT}
PrivateKey = ${srv_priv}
MTU = ${AWG_MTU}
SaveConfig = false
Jc = ${v_jc}
Jmin = ${v_jmin}
Jmax = ${v_jmax}
S1 = ${v_s1}
S2 = ${v_s2}
S3 = ${v_s3}
S4 = ${v_s4}
H1 = ${v_h1}
H2 = ${v_h2}
H3 = ${v_h3}
H4 = ${v_h4}
I1 = ${v_i1}
EOF
    while IFS=$'\t' read -r name priv pub psk ipv4 ipv6; do
      [[ -n "${name:-}" ]] || continue
      printf '\n[Peer]\n# client: %s\nPublicKey = %s\nPresharedKey = %s\n' "$name" "$pub" "$psk"
      if [[ "$HAVE_V6" == "1" ]]; then
        printf 'AllowedIPs = %s/32, %s/128\n' "$ipv4" "$ipv6"
      else
        printf 'AllowedIPs = %s/32\n' "$ipv4"
      fi
    done < "$PEERS_DB"
  } > "$AWG_DIR/${IFACE}.conf"
  chmod 600 "$AWG_DIR/${IFACE}.conf"
}

awg_apply() {
  command -v awg >/dev/null || { err "AmneziaWG не установлен"; return 1; }
  local tmp
  tmp=$(mktemp)
  # awg setconf не понимает Address/DNS/MTU/... — вырезаем
  grep -vE '^[[:space:]]*(Address|DNS|MTU|Table|PreUp|PreDown|PostUp|PostDown|SaveConfig)[[:space:]]*=' \
    "$AWG_DIR/${IFACE}.conf" > "$tmp"
  if ip link show "$IFACE" >/dev/null 2>&1; then
    if ! awg setconf "$IFACE" "$tmp" 2>/tmp/vpn-awg-setconf.log; then
      warn "setconf не сработал, перезапускаю интерфейс"
      awg-quick down "$IFACE" >/dev/null 2>&1 || true
      ip link del "$IFACE" >/dev/null 2>&1 || true
      if ! awg-quick up "$IFACE" >/dev/null 2>&1; then
        sed 's/^/    /' /tmp/vpn-awg-setconf.log >&2
        rm -f "$tmp"; err "не удалось поднять ${IFACE}"; return 1
      fi
    fi
  else
    awg-quick up "$IFACE" >/dev/null 2>&1 || { rm -f "$tmp"; err "не удалось поднять ${IFACE}"; return 1; }
  fi
  rm -f "$tmp"
  [[ -x /usr/local/sbin/awg-nat.sh ]] && /usr/local/sbin/awg-nat.sh >/dev/null 2>&1 || true
}

awg_conf_for() {  # $1=имя $2=endpoint -> stdout
  local name="$1" endpoint="$2" priv psk ipv4 ipv6
  local line
  line=$(awk -F'\t' -v n="$name" '$1==n' "$PEERS_DB")
  [[ -n "$line" ]] || { err "клиент '$name' не найден в AmneziaWG"; return 1; }
  IFS=$'\t' read -r _ priv _ psk ipv4 ipv6 <<< "$line"
  if [[ "$HAVE_V6" == "1" ]]; then
    printf '[Interface]\nPrivateKey = %s\nAddress = %s/32, %s/128\n' "$priv" "$ipv4" "$ipv6"
  else
    printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\n' "$priv" "$ipv4"
  fi
  cat <<EOF
DNS = ${AWG_DNS1}, ${AWG_DNS2}
MTU = ${AWG_MTU}
Jc = $(cfg_get Jc 3)
Jmin = $(cfg_get Jmin 10)
Jmax = $(cfg_get Jmax 30)
S1 = $(cfg_get S1 30)
S2 = $(cfg_get S2 40)
S3 = $(cfg_get S3 15)
S4 = $(cfg_get S4 12)
H1 = $(cfg_get H1 1145255997)
H2 = $(cfg_get H2 1145255998)
H3 = $(cfg_get H3 1145255999)
H4 = $(cfg_get H4 1145256000)
I1 = $(cfg_get I1 '<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>')

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${psk}
Endpoint = ${endpoint}
EOF
  if [[ "$HAVE_V6" == "1" ]]; then
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
  else
    echo "AllowedIPs = 0.0.0.0/0"
  fi
  echo "PersistentKeepalive = 25"
}

awg_write_files() {  # $1=имя
  local name="$1"
  mkdir -p "$CL_DIR"; chmod 700 "$CL_DIR"
  awg_conf_for "$name" "${SERVER_IP4}:${AWG_PORT}" > "$CL_DIR/${name}.conf"
  chmod 600 "$CL_DIR/${name}.conf"
  if [[ "$HAVE_V6" == "1" && -n "${SERVER_IP6:-}" ]]; then
    awg_conf_for "$name" "[${SERVER_IP6}]:${AWG_PORT}" > "$CL_DIR/${name}-ipv6.conf"
    chmod 600 "$CL_DIR/${name}-ipv6.conf"
  fi
}

# =====================================================================
#  КОМАНДЫ
# =====================================================================
cmd_add() {
  local name="${1:-}" proto="${2:-all}"
  [[ -n "$name" ]] || { err "укажите имя: vpn add <имя> [all|xray|awg]"; exit 1; }
  valid_name "$name" || { err "имя: латиница, цифры, '-' и '_', до 32 символов"; exit 1; }
  need_root add "$name"

  if [[ "$proto" == "all" || "$proto" == "xray" ]]; then
    if [[ "$(jq -r --arg n "$name" 'has($n)' "$CL_DB")" == "true" ]]; then
      warn "XRay: клиент '$name' уже есть — выдаю те же ключи и обновляю конфиг"
    else
      jq --arg n "$name" --arg u "$(xray uuid)" '. + {($n): $u}' "$CL_DB"  > "$CL_DB.t"  && mv "$CL_DB.t"  "$CL_DB"
      jq --arg n "$name" --arg u "$(xray uuid)" '. + {($n): $u}' "$CL_DB2" > "$CL_DB2.t" && mv "$CL_DB2.t" "$CL_DB2"
      chmod 600 "$CL_DB" "$CL_DB2"
      xray_regen && xray_apply && ok "XRay: клиент '$name' добавлен"
    fi
  fi

  if [[ "$proto" == "all" || "$proto" == "awg" ]]; then
    if awk -F'\t' -v n="$name" '$1==n{found=1} END{exit !found}' "$PEERS_DB"; then
      warn "AmneziaWG: клиент '$name' уже есть — перевыпускаю файл конфига"
    else
      local priv pub psk idx ipv4 ipv6
      priv=$(awg genkey); pub=$(printf '%s' "$priv" | awg pubkey); psk=$(awg genpsk)
      idx=$(($(wc -l < "$PEERS_DB") + 2))
      ipv4="${NET_V4}.${idx}"; ipv6="${NET_V6_PREFIX}:77:0::${idx}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$priv" "$pub" "$psk" "$ipv4" "$ipv6" >> "$PEERS_DB"
      chmod 600 "$PEERS_DB"
      awg_regen && awg_apply && ok "AmneziaWG: клиент '$name' добавлен (${ipv4})"
    fi
    awg_write_files "$name" && ok "Файл: ${CL_DIR}/${name}.conf"
  fi

  cmd_link "$name"
}

cmd_del() {
  local name="${1:-}" proto="${2:-all}"
  [[ -n "$name" ]] || { err "укажите имя: vpn del <имя> [all|xray|awg]"; exit 1; }
  need_root del "$name"

  if [[ "$proto" == "all" || "$proto" == "xray" ]]; then
    jq --arg n "$name" 'del(.[$n])' "$CL_DB"  > "$CL_DB.t"  && mv "$CL_DB.t"  "$CL_DB"
    jq --arg n "$name" 'del(.[$n])' "$CL_DB2" > "$CL_DB2.t" && mv "$CL_DB2.t" "$CL_DB2"
    xray_regen && xray_apply && ok "XRay: клиент '$name' удалён"
  fi

  if [[ "$proto" == "all" || "$proto" == "awg" ]]; then
    if awk -F'\t' -v n="$name" '$1==n{found=1} END{exit !found}' "$PEERS_DB"; then
      awk -F'\t' -v n="$name" '$1!=n' "$PEERS_DB" > "$PEERS_DB.t" && mv "$PEERS_DB.t" "$PEERS_DB"
      chmod 600 "$PEERS_DB"
      rm -f "$CL_DIR/${name}.conf" "$CL_DIR/${name}-ipv6.conf"
      awg_regen && awg_apply && ok "AmneziaWG: клиент '$name' удалён"
    fi
  fi
}

cmd_list() {
  head1 "XRay (VLESS + REALITY)"
  if [[ -s "$CL_DB" ]] && [[ "$(jq 'length' "$CL_DB")" != "0" ]]; then
    jq -r 'to_entries[] | "  \(.key)\t\(.value)"' "$CL_DB"
  else echo "  (нет клиентов)"; fi

  head1 "AmneziaWG"
  if [[ -s "$PEERS_DB" ]]; then
    printf "  %-16s %-14s %s\n" "ИМЯ" "IPv4" "IPv6"
    awk -F'\t' '{printf "  %-16s %-14s %s\n", $1, $5, $6}' "$PEERS_DB"
  else echo "  (нет клиентов)"; fi

  head1 "Кто сейчас подключён (AmneziaWG)"
  if ip link show "$IFACE" >/dev/null 2>&1; then
    awg show "$IFACE" | awk '
      /^peer:/ {peer=$2; hs="никогда"}
      /latest handshake:/ {hs=""; for(i=3;i<=NF;i++) hs=hs" "$i}
      /transfer:/ {printf "  %s  handshake:%s  %s %s %s %s\n", substr(peer,1,12)"…", hs, $2,$3,$5,$6}
    '
  else echo "  интерфейс ${IFACE} не поднят"; fi
}

cmd_link() {
  local name="${1:-}"
  [[ -n "$name" ]] || { err "укажите имя: vpn link <имя>"; exit 1; }
  local found=0
  if xray_links "$name" > /tmp/vpn-links.txt 2>/dev/null; then
    found=1
    head1 "XRay — ссылки (импорт «из буфера обмена»)"
    sed 's/^/  /' /tmp/vpn-links.txt
  fi
  if awk -F'\t' -v n="$name" '$1==n{found=1} END{exit !found}' "$PEERS_DB"; then
    found=1
    head1 "AmneziaWG — файл конфигурации"
    echo "  ${CL_DIR}/${name}.conf"
    [[ "$HAVE_V6" == "1" ]] && echo "  ${CL_DIR}/${name}-ipv6.conf      (через IPv6)"
    echo
    echo "  Забрать на свой компьютер:"
    echo "      scp root@${SERVER_IP4}:${CL_DIR}/${name}.conf ."
  fi
  [[ $found -eq 1 ]] || { err "клиент '$name' не найден"; exit 1; }
}

cmd_show() {
  local name="${1:-}"
  [[ -n "$name" ]] || { err "укажите имя: vpn show <имя>"; exit 1; }
  local any=0
  if awk -F'\t' -v n="$name" '$1==n{found=1} END{exit !found}' "$PEERS_DB"; then
    any=1
    head1 "AmneziaWG: ${name}.conf"
    awg_conf_for "$name" "${SERVER_IP4}:${AWG_PORT}"
    if command -v qrencode >/dev/null 2>&1; then
      head1 "QR-код для приложения AmneziaWG (наведите камеру)"
      awg_conf_for "$name" "${SERVER_IP4}:${AWG_PORT}" | qrencode -t ansiutf8
    else
      warn "qrencode не установлен: apt install qrencode"
    fi
  fi
  if xray_links "$name" > /tmp/vpn-links.txt 2>/dev/null; then
    any=1
    head1 "XRay: ссылки"
    cat /tmp/vpn-links.txt
    if command -v qrencode >/dev/null 2>&1; then
      head1 "QR основной ссылки XRay"
      head -n1 /tmp/vpn-links.txt | qrencode -t ansiutf8
    fi
  fi
  [[ $any -eq 1 ]] || { err "клиент '$name' не найден"; exit 1; }
}

cmd_status() {
  head1 "Службы"
  printf "  %-16s %s\n" "xray"        "$(systemctl is-active xray 2>/dev/null || echo '—')"
  printf "  %-16s %s\n" "$IFACE"      "$(systemctl is-active "awg-quick@${IFACE}" 2>/dev/null || echo '—')"
  printf "  %-16s %s\n" "awg-nat"     "$(systemctl is-active awg-nat 2>/dev/null || echo '—')"
  printf "  %-16s %s\n" "ufw"         "$(systemctl is-active ufw 2>/dev/null || echo '—')"

  head1 "Порты"
  ss -tulnpH 2>/dev/null | awk -v a="$PORT_MAIN" -v b="$PORT_COMPAT" -v c="$AWG_PORT" \
    '$5 ~ ":"a"$" || $5 ~ ":"b"$" || $5 ~ ":"c"$" {printf "  %-6s %-24s %s\n",$1,$5,$7}'

  head1 "AmneziaWG: ${IFACE}"
  if ip link show "$IFACE" >/dev/null 2>&1; then
    awg show "$IFACE" | head -n 8 | sed 's/^/  /'
  else echo "  не поднят"; fi

  head1 "XRay — последние строки журнала"
  journalctl -u xray -n 6 --no-pager 2>/dev/null | sed 's/^/  /' || true

  head1 "Нагрузка"
  uptime 2>/dev/null | sed 's/^/  /' || true
  free -m 2>/dev/null | awk 'NR<=2{printf "  %s\n",$0}' || true
}

cmd_help() {
  cat <<EOF
${BLD}vpn${RST} — управление пользователями VPN (XRay VLESS+REALITY + AmneziaWG)

  ${BLD}vpn add${RST}  <имя> [all|xray|awg]   создать клиента (по умолчанию — оба протокола)
  ${BLD}vpn del${RST}  <имя> [all|xray|awg]   удалить / отозвать доступ
  ${BLD}vpn list${RST}                        список клиентов и активные подключения
  ${BLD}vpn link${RST} <имя>                  ссылки XRay + путь к .conf AmneziaWG
  ${BLD}vpn show${RST} <имя>                  конфиг + QR-коды прямо в консоли
  ${BLD}vpn status${RST}                      состояние служб, портов, нагрузки
  ${BLD}vpn help${RST}                        эта справка

Примеры:
  vpn add wife              # оба протокола сразу
  vpn add iphone xray       # только XRay (v2box / Streisand)
  vpn add router awg        # только AmneziaWG (Keenetic / OpenWRT)
  vpn show wife             # конфиг + QR

Файлы:
  ${CL_DIR}/<имя>.conf                   клиентские конфиги AmneziaWG
  /usr/local/etc/xray/config.json        серверный конфиг XRay
  ${AWG_DIR}/${IFACE}.conf               серверный конфиг AmneziaWG
  ${STATE_DIR}/                          база клиентов и их ключи (chmod 600)
EOF
}

case "${1:-help}" in
  add|new)   shift; cmd_add  "${1:-}" "${2:-all}" ;;
  del|rm)    shift; cmd_del  "${1:-}" "${2:-all}" ;;
  list|ls)   cmd_list ;;
  link|url)  shift; cmd_link "${1:-}" ;;
  show|qr)   shift; cmd_show "${1:-}" ;;
  status|st) cmd_status ;;
  help|-h|--help) cmd_help ;;
  *) cmd_help; exit 1 ;;
esac
VPN_SCRIPT

chmod 755 /usr/local/bin/vpn
ok "Установлено: /usr/local/bin/vpn"

echo
/usr/local/bin/vpn list || true
echo
cat <<'EOF'
  Готово! Дальше:

     vpn add ivan        # новый клиент: XRay + AmneziaWG, сразу выдаст ссылки
     vpn show ivan       # конфиг AmneziaWG и QR-коды для сканирования
     vpn list            # кто есть, кто подключён
     vpn del ivan        # отозвать доступ

  Справка:  vpn help
EOF
