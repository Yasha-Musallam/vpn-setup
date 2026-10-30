#!/usr/bin/env bash
# Локальная проверка: генерируем такой же config.json, как 02-xray-reality.sh,
# и прогоняем через настоящий xray -test
set -euo pipefail
cd "$(dirname "$0")"
XRAY=${XRAY:-./xray.exe}
JQ=${JQ:-./jq.exe}

PORT_MAIN=443
PORT_COMPAT=8443
REALITY_SNI=www.samsung.com
REALITY_DEST=www.samsung.com:443

KOUT=$("$XRAY" x25519)
REALITY_PRIV=$(printf '%s\n' "$KOUT" | awk -F': ' '/^PrivateKey/{print $2}')
REALITY_PUB=$(printf '%s\n' "$KOUT" | awk -F': ' '/^(Password|PublicKey)/{print $2}')
echo "priv=[$REALITY_PRIV] pub=[$REALITY_PUB]"
[[ ${#REALITY_PRIV} -eq 43 && ${#REALITY_PUB} -eq 43 ]] || { echo "FAIL: длина ключей"; exit 1; }

SHORT_ID=$("$XRAY" uuid | tr -d '-' | cut -c1-16)
OWNER_UUID=$("$XRAY" uuid)
OWNER_UUID2=$("$XRAY" uuid)

echo "{\"owner\":\"$OWNER_UUID\"}" > clients.json
echo "{\"owner\":\"$OWNER_UUID2\"}" > clients2.json
clients_vision=$("$JQ" -c '[to_entries[] | {id: .value, flow: "xtls-rprx-vision"}]' clients.json)
clients_novision=$("$JQ" -c '[to_entries[] | {id: .value, flow: ""}]' clients2.json)

cat > gen-config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality-vision",
      "listen": "0.0.0.0",
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
      "listen": "0.0.0.0",
      "port": ${PORT_COMPAT},
      "protocol": "vless",
      "settings": {
        "clients": ${clients_novision},
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
        "ip": [ "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10",
                "fc00::/7", "fe80::/10", "::1/128", "10.77.0.0/24" ],
        "outboundTag": "direct" }
    ]
  }
}
EOF

echo "--- xray run -test ---"
if "$XRAY" run -test -config gen-config.json; then
  echo "РЕАЛЬНЫЙ КОНФИГ ПРОШЁЛ ПРОВЕРКУ XRAY"
else
  echo "КОНФИГ НЕВАЛИДЕН"; exit 1
fi

rm -f clients.json clients2.json gen-config.json
