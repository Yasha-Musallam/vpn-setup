#!/usr/bin/env bash
# =====================================================================
#  ШАГ 2. XRay — VLESS + XTLS-Vision + REALITY
#  Работает в v2box (iOS/macOS), V2RayNG, Streisand, Hiddify, Happ,
#  NekoBox, FoXray и т.п. Снаружи это выглядит как обычный HTTPS.
#
#  Что создаётся:
#    TCP 443  : VLESS + XTLS Vision + REALITY   (основной профиль)
#    TCP 8443 : VLESS без flow + REALITY        (резерв для клиентов,
#                                                у которых капризничает Vision)
#
#  Запуск:  bash 02-xray-reality.sh
#  Можно переопределить:  REALITY_SNI=www.samsung.com XRAY_PORT_MAIN=443 bash 02-xray-reality.sh
# =====================================================================
set -euo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYA=$'\e[36m'; RST=$'\e[0m'
ok()   { echo "${GRN}[ OK ]${RST} $*"; }
info() { echo "${CYA}[ .. ]${RST} $*"; }
warn() { echo "${YEL}[ !! ]${RST} $*"; }
die()  { echo "${RED}[FAIL]${RST} $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запускать нужно от root"

STATE_DIR=/etc/vpn-manager
XRAY_DIR=/usr/local/etc/xray
XRAY_CONF="$XRAY_DIR/config.json"
mkdir -p "$STATE_DIR"
# ВАЖНО: каталог $XRAY_DIR создаёт сам установщик Xray (с правами 750 root:xray).
# Если создать его заранее, установщик решит, что конфиг уже есть, и не создаст
# config.json — служба не запустится. Поэтому каталог создаём только при необходимости,
# уже после установки Xray.

if [[ -f "$STATE_DIR/system.env" ]]; then . "$STATE_DIR/system.env"; fi
if [[ -z "${SERVER_IP4:-}" ]]; then
  SERVER_IP4=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
fi
[[ -n "${SERVER_IP4:-}" ]] || die "Не определён IPv4 сервера"

PORT_MAIN=${XRAY_PORT_MAIN:-443}
PORT_COMPAT=${XRAY_PORT_COMPAT:-8443}
XRAY_LISTEN=${XRAY_LISTEN:-0.0.0.0}
# Маскировка: SNI, который видит провайдер. Должен быть чужим популярным сайтом
# с TLS 1.3 + HTTP/2. НЕЛЬЗЯ: microsoft, apple, icloud, домены .ru/.ir/.cn —
# Xray предупреждает, что это повышает риск блокировки сервера.
# Проверенные варианты: www.samsung.com, www.nvidia.com, dl.google.com,
# www.lovelive-anime.jp
REALITY_SNI=${REALITY_SNI:-www.samsung.com}
REALITY_DEST=${REALITY_DEST:-${REALITY_SNI}:443}

echo
info "Параметры XRay:"
echo "      IPv4 сервера  : ${SERVER_IP4}"
echo "      основной порт : ${PORT_MAIN}/tcp  (VLESS + Vision + REALITY)"
echo "      резервный порт: ${PORT_COMPAT}/tcp  (VLESS без flow)"
echo "      маскировка    : ${REALITY_SNI} (dest ${REALITY_DEST})"

# ---------------------------------------------------------------------
# 1. Проверка занятости портов
# ---------------------------------------------------------------------
for p in "$PORT_MAIN" "$PORT_COMPAT"; do
  if ss -tlnpH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"; then
    warn "Порт ${p}/tcp уже занят:"
    ss -tlnpH | awk -v p="$p" '$4 ~ ":"p"$"' | sed 's/^/      /'
    die "Освободите порт ${p} (обычно это nginx/apache) либо задайте другие:
      XRAY_PORT_MAIN=2053 XRAY_PORT_COMPAT=2054 bash 02-xray-reality.sh"
  fi
done
ok "Порты ${PORT_MAIN} и ${PORT_COMPAT} свободны"

# ---------------------------------------------------------------------
# 2. Установка Xray-core (официальный установщик XTLS)
# ---------------------------------------------------------------------
if ! command -v xray >/dev/null 2>&1; then
  info "Устанавливаю Xray-core..."
  installer=""
  for try in 1 2 3; do
    installer=$(curl -fsSL --retry 3 --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh || true)
    [[ -n "$installer" ]] && break
    warn "Не удалось скачать установщик, попытка ${try}..."
    sleep 3
  done
  [[ -n "$installer" ]] || die "Нет доступа к github.com (проверьте DNS/сеть сервера)"
  DEBIAN_FRONTEND=noninteractive bash -c "$installer" @ install >/tmp/xray-install.log 2>&1 || {
    tail -n 30 /tmp/xray-install.log; die "Установка Xray не удалась"; }
fi
ok "Xray: $(xray version | head -n1)"
# установщик создаёт $XRAY_DIR сам; подстрахуемся, если он этого не сделал
mkdir -p "$XRAY_DIR"

# ---------------------------------------------------------------------
# 3. Ключи REALITY и shortId
# ---------------------------------------------------------------------
if [[ -s "$XRAY_DIR/reality.key" && -s "$XRAY_DIR/reality.pub" ]]; then
  REALITY_PRIV=$(cat "$XRAY_DIR/reality.key")
  REALITY_PUB=$(cat "$XRAY_DIR/reality.pub")
  info "Использую существующую пару ключей REALITY"
else
  info "Генерирую пару ключей x25519..."
  KOUT=$(xray x25519)
  REALITY_PRIV=$(printf '%s\n' "$KOUT" | awk -F': ' '/^PrivateKey/{print $2}')
  # в разных версиях строка называется Password (PublicKey) или PublicKey
  REALITY_PUB=$(printf '%s\n' "$KOUT" | awk -F': ' '/^(Password|PublicKey)/{print $2}' | head -n1)
  [[ -n "$REALITY_PRIV" && -n "$REALITY_PUB" ]] || die "Не удалось получить ключи из 'xray x25519'"
  printf '%s' "$REALITY_PRIV" > "$XRAY_DIR/reality.key"
  printf '%s' "$REALITY_PUB"  > "$XRAY_DIR/reality.pub"
  chmod 600 "$XRAY_DIR/reality.key"
fi
ok "Публичный ключ REALITY (pbk): ${REALITY_PUB}"

if [[ -s "$XRAY_DIR/shortid" ]]; then
  SHORT_ID=$(cat "$XRAY_DIR/shortid")
else
  SHORT_ID=$(openssl rand -hex 8)
  printf '%s' "$SHORT_ID" > "$XRAY_DIR/shortid"
fi
chmod 600 "$XRAY_DIR/shortid"
ok "shortId (sid): ${SHORT_ID}"

# ---------------------------------------------------------------------
# 4. База клиентов + первый клиент
# ---------------------------------------------------------------------
CL_DB="$STATE_DIR/xray-clients.json"       # профиль Vision  -> uuid
CL_DB2="$STATE_DIR/xray-clients2.json"     # профиль plain   -> uuid
[[ -s "$CL_DB"  ]] || echo '{}' > "$CL_DB"
[[ -s "$CL_DB2" ]] || echo '{}' > "$CL_DB2"

if [[ "$(jq 'length' "$CL_DB")" == "0" ]]; then
  jq --arg n owner --arg u "$(xray uuid)" '. + {($n): $u}' "$CL_DB"  > "$CL_DB.t"  && mv "$CL_DB.t"  "$CL_DB"
  jq --arg n owner --arg u "$(xray uuid)" '. + {($n): $u}' "$CL_DB2" > "$CL_DB2.t" && mv "$CL_DB2.t" "$CL_DB2"
  ok "Создан первый клиент: owner"
fi
chmod 600 "$CL_DB" "$CL_DB2"

clients_vision=$(jq -c '[to_entries[] | {id: .value, flow: "xtls-rprx-vision"}]' "$CL_DB")
clients_plain=$(jq -c '[to_entries[] | {id: .value, flow: ""}]' "$CL_DB2")

# ---------------------------------------------------------------------
# 5. Серверный конфиг
# ---------------------------------------------------------------------
info "Пишу конфиг ${XRAY_CONF}..."
cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality-vision",
      "listen": "${XRAY_LISTEN}",
      "port": ${PORT_MAIN},
      "protocol": "vless",
      "settings": {
        "clients": ${clients_vision},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [ "${REALITY_SNI}" ],
          "privateKey": "${REALITY_PRIV}",
          "shortIds": [ "${SHORT_ID}" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": false }
    },
    {
      "tag": "vless-reality-plain",
      "listen": "${XRAY_LISTEN}",
      "port": ${PORT_COMPAT},
      "protocol": "vless",
      "settings": {
        "clients": ${clients_plain},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [ "${REALITY_SNI}" ],
          "privateKey": "${REALITY_PRIV}",
          "shortIds": [ "${SHORT_ID}" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": false }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {},
      "streamSettings": { "sockopt": { "domainStrategy": "UseIPv4v6" } }
    },
    { "tag": "block",  "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "rules": [
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" },
      { "type": "field",
        "ip": [ "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                "100.64.0.0/10", "169.254.0.0/16",
                "fc00::/7", "fe80::/10", "::1/128" ],
        "outboundTag": "direct" }
    ]
  }
}
EOF

# ВАЖНО: служба xray работает от пользователя xray (создаётся установщиком),
# поэтому конфиг должен быть ему доступен на чтение. Держим владельцем root,
# группу xray — так служба не сможет переписать свой же конфиг.
getent group xray >/dev/null 2>&1 || groupadd --system xray
id xray >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --gid xray xray
chown 0:xray "$XRAY_CONF"
chmod 640 "$XRAY_CONF"
chown -R 0:xray "$XRAY_DIR" 2>/dev/null || true
chmod 750 "$XRAY_DIR"
chmod 600 "$XRAY_DIR/reality.key" "$XRAY_DIR/shortid"

# Проверяем конфиг от имени службы (пользователь xray), чтобы сразу поймать проблемы прав
TEST_CMD=(xray run -test -config "$XRAY_CONF")
if command -v runuser >/dev/null 2>&1; then
  runuser -u xray -- "${TEST_CMD[@]}" >/tmp/xray-test.log 2>&1 || {
    cat /tmp/xray-test.log; die "Конфиг XRay не прошёл проверку (см. вывод выше)"; }
elif command -v sudo >/dev/null 2>&1; then
  sudo -u xray "${TEST_CMD[@]}" >/tmp/xray-test.log 2>&1 || {
    cat /tmp/xray-test.log; die "Конфиг XRay не прошёл проверку (см. вывод выше)"; }
else
  "${TEST_CMD[@]}" >/tmp/xray-test.log 2>&1 || {
    cat /tmp/xray-test.log; die "Конфиг XRay не прошёл проверку (см. вывод выше)"; }
fi
ok "Конфиг валиден (xray run -test)"

# ---------------------------------------------------------------------
# 6. Запуск
# ---------------------------------------------------------------------
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { journalctl -u xray -n 40 --no-pager; die "Служба xray не запустилась"; }
ok "Служба xray активна"
ss -tlnpH | awk -v a="$PORT_MAIN" -v b="$PORT_COMPAT" '$4 ~ ":"a"$" || $4 ~ ":"b"$"' | sed 's/^/      /'

info "Проверяю, что порт ${PORT_MAIN} отвечает как настоящий https..."
TLSOUT=$(echo | timeout 10 openssl s_client -connect "127.0.0.1:${PORT_MAIN}" -servername "${REALITY_SNI}" 2>/dev/null | grep -E '^(subject|issuer)=' || true)
if [[ -n "$TLSOUT" ]]; then
  echo "$TLSOUT" | sed 's/^/      /'
  ok "TLS-маскировка работает"
else
  warn "Локальная проверка TLS не дала ответа — для REALITY это часто норма (проверьте с клиента)"
fi

# ---------------------------------------------------------------------
# 7. Данные для ссылок + вывод
# ---------------------------------------------------------------------
cat > "$STATE_DIR/xray.env" <<EOF
REALITY_SNI=${REALITY_SNI}
REALITY_DEST=${REALITY_DEST}
REALITY_PUB=${REALITY_PUB}
SHORT_ID=${SHORT_ID}
PORT_MAIN=${PORT_MAIN}
PORT_COMPAT=${PORT_COMPAT}
EOF
chmod 600 "$STATE_DIR/xray.env"

U1=$(jq -r '.owner' "$CL_DB")
U2=$(jq -r '.owner' "$CL_DB2")
Q1="encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision"
Q2="encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp"

echo
ok "ШАГ 2 завершён. XRay работает."
cat <<EOF

  ═══ ССЫЛКА 1 (основная, порт ${PORT_MAIN}, VLESS+Vision+REALITY) ═══
  vless://${U1}@${SERVER_IP4}:${PORT_MAIN}?${Q1}#owner

  ═══ ССЫЛКА 2 (резервная, порт ${PORT_COMPAT}, без Vision) ═══
  vless://${U2}@${SERVER_IP4}:${PORT_COMPAT}?${Q2}#owner-novision

  ═══ Те же параметры вручную (если клиент не понимает ссылку) ═══
      адрес       : ${SERVER_IP4}
      порт        : ${PORT_MAIN}
      протокол    : VLESS
      UUID        : ${U1}
      flow        : xtls-rprx-vision
      security    : reality
      SNI         : ${REALITY_SNI}
      fingerprint : chrome
      public key  : ${REALITY_PUB}
      shortId     : ${SHORT_ID}

  В v2box: «+» → «Добавить из буфера обмена» (или Import from clipboard).
  Проверить можно и на самом сервере:  journalctl -u xray -f

  Дальше:
    bash 03-amneziawg.sh    # второй протокол (UDP, обфускация)
    bash 04-manager.sh      # команда 'vpn' для новых клиентов

EOF
