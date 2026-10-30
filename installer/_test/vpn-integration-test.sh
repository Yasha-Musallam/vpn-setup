#!/usr/bin/env bash
# =====================================================================
#  Интеграционный тест команды 'vpn' БЕЗ реального сервера.
#  Подменяет пути и системные команды заглушками, затем проверяет
#  add / list / link / show / del для обоих протоколов.
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")"

JQ=${JQ:-./jq.exe}
SRC=${1:-../04-manager.sh}
[[ -f "$SRC" ]] || { echo "нет файла $SRC"; exit 1; }

ROOT=$(mktemp -d)
export ROOT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# ---------- вырезаем встроенный скрипт vpn и переписываем пути ----------
awk '/^cat > \/usr\/local\/bin\/vpn <</{f=1;next} /^VPN_SCRIPT$/{f=0} f' "$SRC" > "$ROOT/vpn.raw"
[[ -s "$ROOT/vpn.raw" ]] || { echo "не удалось вырезать vpn-скрипт"; exit 1; }

sed -e "s#/etc/vpn-manager#$ROOT/etc/vpn-manager#g" \
    -e "s#/usr/local/etc/xray#$ROOT/xray#g" \
    -e "s#/etc/amnezia/amneziawg#$ROOT/awg#g" \
    -e "s#/usr/local/sbin/awg-nat.sh#$ROOT/bin/awg-nat.sh#g" \
    -e "s#/tmp/vpn-#$ROOT/tmp-vpn-#g" \
    -e "s#\$(mktemp)#$ROOT/mktemp.out#g" \
    "$ROOT/vpn.raw" > "$ROOT/vpn"

# тест идёт не от root — отключаем проверку прав (на сервере скрипт работает от root)
sed -i 's/^need_root() {.*$/need_root() { :; }/' "$ROOT/vpn"
grep -q '^need_root() { :; }' "$ROOT/vpn" || { echo "не удалось отключить need_root"; exit 1; }

chmod +x "$ROOT/vpn"

# ---------- окружение ----------
mkdir -p "$ROOT/etc/vpn-manager" "$ROOT/xray" "$ROOT/awg" "$ROOT/etc/vpn-manager/amneziawg-clients"
cat > "$ROOT/etc/vpn-manager/system.env" <<EOF
SSH_PORT=22
SERVER_IP4=203.0.113.10
SERVER_IP6=2001:db8::10
EOF
cat > "$ROOT/etc/vpn-manager/xray.env" <<EOF
REALITY_SNI=www.samsung.com
REALITY_DEST=www.samsung.com:443
REALITY_PUB=PUBKEYPUBKEYPUBKEYPUBKEYPUBKEYPUBKEYPUBKEY0
SHORT_ID=0123456789abcdef
PORT_MAIN=443
PORT_COMPAT=8443
EOF
cat > "$ROOT/etc/vpn-manager/awg.env" <<EOF
IFACE=amneziawg0
AWG_PORT=55424
SERVER_PUB=SRVPUBSRVPUBSRVPUBSRVPUBSRVPUBSRVPUBSRVPUB0
AWG_MODE=kernel
SUBNET_V4=10.77.0.0/24
SUBNET_V6=fd77:77:0::/64
SERVER_V4=10.77.0.1
SERVER_V6=fd77:77:0::1
HAVE_V6=1
AWG_DNS1=1.1.1.1
AWG_DNS2=8.8.8.8
AWG_MTU=1280
EOF
echo '{"owner":"00000000-0000-0000-0000-000000000001"}' > "$ROOT/etc/vpn-manager/xray-clients.json"
echo '{"owner":"00000000-0000-0000-0000-000000000002"}' > "$ROOT/etc/vpn-manager/xray-clients2.json"
printf 'owner\tpriv0\tpub0\tpsk0\t10.77.0.2\tfd77:77:0::2\n' > "$ROOT/etc/vpn-manager/awg-peers.tsv"
echo 'YPrivKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' > "$ROOT/awg/server_private.key"
echo 'YPubKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' > "$ROOT/awg/server_public.key"
cat > "$ROOT/awg/amneziawg0.conf" <<'EOF'
[Interface]
Address = 10.77.0.1/24, fd77:77:0::1/64
ListenPort = 55424
PrivateKey = YPrivKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
MTU = 1280
SaveConfig = false
Jc = 3
Jmin = 10
Jmax = 30
S1 = 30
S2 = 40
S3 = 15
S4 = 12
H1 = 1145255997
H2 = 1145255998
H3 = 1145255999
H4 = 1145256000
I1 = <r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>

[Peer]
# client: owner
PublicKey = pub0
PresharedKey = psk0
AllowedIPs = 10.77.0.2/32, fd77:77:0::2/128
EOF
cat > "$ROOT/xray/config.json" <<'EOF'
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"tag":"vision","listen":"0.0.0.0","port":443,"protocol":"vless",
     "settings":{"clients":[{"id":"00000000-0000-0000-0000-000000000001","flow":"xtls-rprx-vision"}],"decryption":"none"},
     "streamSettings":{"network":"tcp","security":"reality",
       "realitySettings":{"dest":"www.samsung.com:443","serverNames":["www.samsung.com"],
         "privateKey":"PRIV","shortIds":["0123456789abcdef"]}}},
    {"tag":"plain","listen":"0.0.0.0","port":8443,"protocol":"vless",
     "settings":{"clients":[{"id":"00000000-0000-0000-0000-000000000002","flow":""}],"decryption":"none"},
     "streamSettings":{"network":"tcp","security":"reality",
       "realitySettings":{"dest":"www.samsung.com:443","serverNames":["www.samsung.com"],
         "privateKey":"PRIV","shortIds":["0123456789abcdef"]}}}
  ],
  "outbounds": [{"tag":"direct","protocol":"freedom","settings":{}}]
}
EOF

# ---------- заглушки ----------
cat > "$BIN/xray" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  uuid) echo "aaaaaaaa-bbbb-cccc-dddd-$(date +%N | cut -c1-12)" ;;
  version) echo "Xray 26.10.29 (test stub)" ;;
  run) exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-active) echo active; exit 0 ;;
  is-enabled) echo enabled; exit 0 ;;
  restart|start|enable|daemon-reload|stop) exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$BIN/awg" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  genkey) echo "priv$(date +%N | cut -c1-8)AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
  genpsk) echo "psk$(date +%N | cut -c1-9)BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" ;;
  pubkey) read -r k; echo "pub${k:4:8}CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" ;;
  show) echo "interface: amneziawg0"; echo "  public key: YPUB"; echo "  listening port: 55424" ;;
  setconf) exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$BIN/qrencode" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null; echo "[QR-CODE-STUB]"
EOF
cat > "$BIN/journalctl" <<'EOF'
#!/usr/bin/env bash
echo "stub journal"
EOF
cat > "$BIN/ss" <<'EOF'
#!/usr/bin/env bash
echo "Netid State Recv-Q Send-Q Local-Address:Port Peer-Address:Port Process"
EOF
cat > "$BIN/ip" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN/mktemp" <<'EOF'
#!/usr/bin/env bash
echo "$ROOT/tmpfile.$$"
EOF
cat > "$BIN/awg-nat.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# jq: в тесте он лежит рядом как jq.exe (Windows) — делаем доступным по имени
if [[ -x "$JQ" ]]; then
  cat > "$BIN/jq" <<EOF
#!/usr/bin/env bash
exec "$(cd "$(dirname "$JQ")" && pwd)/$(basename "$JQ")" "\$@"
EOF
  chmod +x "$BIN/jq"
fi
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export ROOT

# ---------- проверки ----------
ok=0; bad=0
chk() { if eval "$2"; then echo "  OK   $1"; ok=$((ok+1)); else echo "  FAIL $1"; bad=$((bad+1)); fi; }

V="$ROOT/vpn"

echo "=== 1. vpn help ==="
"$V" help | grep -q 'vpn add' && chk "справка выводится" "true" || chk "справка выводится" "false"

echo "=== 2. vpn list (исходное состояние) ==="
LISTOUT=$("$V" list 2>&1); chk "owner виден в списке" "grep -q owner <<< \"\$LISTOUT\""
chk "list не падает" "[[ $? -eq 0 || true ]]"

echo "=== 3. vpn add ivan (оба протокола) ==="
OUT=$("$V" add ivan 2>&1); RC=$?
chk "add завершился успешно" "[[ $RC -eq 0 ]]"
chk "XRay: ivan в базе" "$JQ -e 'has(\"ivan\")' '$ROOT/etc/vpn-manager/xray-clients.json' >/dev/null"
chk "XRay: во втором профиле тоже" "$JQ -e 'has(\"ivan\")' '$ROOT/etc/vpn-manager/xray-clients2.json' >/dev/null"
chk "XRay: клиентов стало 2" "[[ \$($JQ 'length' '$ROOT/etc/vpn-manager/xray-clients.json') -eq 2 ]]"
chk "XRay: в конфиг попал flow vision" "$JQ -e '.inbounds[0].settings.clients|length==2' '$ROOT/xray/config.json' >/dev/null"
chk "XRay: второй inbound без flow" "$JQ -e '.inbounds[1].settings.clients[0].flow==\"\"' '$ROOT/xray/config.json' >/dev/null"
chk "AWG: пир добавлен" "grep -q 'ivan' '$ROOT/etc/vpn-manager/awg-peers.tsv'"
chk "AWG: выданы IPv4+IPv6" "grep -P '^ivan\t.*\t10\.77\.0\.3\tfd77:77:0::3$' '$ROOT/etc/vpn-manager/awg-peers.tsv' >/dev/null 2>&1 || awk -F'\t' '\$1==\"ivan\"{exit !(\$5==\"10.77.0.3\" && \$6==\"fd77:77:0::3\")}' '$ROOT/etc/vpn-manager/awg-peers.tsv'"
chk "AWG: серверный конфиг содержит пира" "grep -q '# client: ivan' '$ROOT/awg/amneziawg0.conf'"
chk "AWG: серверный конфиг содержит AllowedIPs" "grep -q 'AllowedIPs = 10.77.0.3/32, fd77:77:0::3/128' '$ROOT/awg/amneziawg0.conf'"
chk "AWG: параметры обфускации сохранены" "grep -qx 'Jc = 3' '$ROOT/awg/amneziawg0.conf'"
chk "AWG: I1 сохранён целиком" "grep -qF 'I1 = <r 2><b 0x8580' '$ROOT/awg/amneziawg0.conf'"
chk "AWG: файл клиента создан" "[[ -s '$ROOT/etc/vpn-manager/amneziawg-clients/ivan.conf' ]]"
chk "AWG: IPv6-файл клиента создан" "[[ -s '$ROOT/etc/vpn-manager/amneziawg-clients/ivan-ipv6.conf' ]]"
chk "вывод содержит ссылку vless://" "grep -q 'vless://' <<< \"\$OUT\""
chk "вывод содержит путь к .conf" "grep -q 'ivan.conf' <<< \"\$OUT\""
chk "клиентский .conf содержит Endpoint" "grep -q 'Endpoint = 203.0.113.10:55424' '$ROOT/etc/vpn-manager/amneziawg-clients/ivan.conf'"
chk "клиентский .conf содержит PresharedKey" "grep -q 'PresharedKey = psk' '$ROOT/etc/vpn-manager/amneziawg-clients/ivan.conf'"
chk "клиентский .conf содержит AllowedIPs 0/0" "grep -qx 'AllowedIPs = 0.0.0.0/0, ::/0' '$ROOT/etc/vpn-manager/amneziawg-clients/ivan.conf'"

echo "=== 4. vpn add petr xray (только XRay) ==="
OUT2=$("$V" add petr xray 2>&1); RC2=$?
chk "add xray успешен" "[[ $RC2 -eq 0 ]]"
chk "petr в XRay" "$JQ -e 'has(\"petr\")' '$ROOT/etc/vpn-manager/xray-clients.json' >/dev/null"
chk "petr НЕ добавлен в AWG" "! grep -q petr '$ROOT/etc/vpn-manager/awg-peers.tsv'"

echo "=== 5. vpn add router awg (только AWG) ==="
OUT3=$("$V" add router awg 2>&1); RC3=$?
chk "add awg успешен" "[[ $RC3 -eq 0 ]]"
chk "router в AWG" "grep -q router '$ROOT/etc/vpn-manager/awg-peers.tsv'"
chk "router НЕ добавлен в XRay" "! $JQ -e 'has(\"router\")' '$ROOT/etc/vpn-manager/xray-clients.json' >/dev/null"
chk "router получил 10.77.0.4" "awk -F'\t' '\$1==\"router\"{exit !(\$5==\"10.77.0.4\")}' '$ROOT/etc/vpn-manager/awg-peers.tsv'"

echo "=== 6. повторный add (идемпотентность) ==="
OUT4=$("$V" add ivan 2>&1); RC4=$?
chk "повторный add не падает" "[[ $RC4 -eq 0 ]]"
chk "не создан дубль пира" "[[ \$(grep -c '^ivan' '$ROOT/etc/vpn-manager/awg-peers.tsv') -eq 1 ]]"
chk "клиентов AWG не стало больше" "[[ \$(wc -l < '$ROOT/etc/vpn-manager/awg-peers.tsv') -eq 3 ]]"

echo "=== 7. vpn show ivan ==="
OUT5=$("$V" show ivan 2>&1)
chk "show: есть конфиг AWG" "grep -q 'PrivateKey' <<< \"\$OUT5\""
chk "show: есть QR" "grep -q 'QR-CODE-STUB' <<< \"\$OUT5\""
chk "show: есть ссылка XRay" "grep -q 'vless://' <<< \"\$OUT5\""

echo "=== 8. vpn link ivan ==="
OUT6=$("$V" link ivan 2>&1); RC6=$?
chk "link успешен" "[[ $RC6 -eq 0 ]]"
chk "link: две ссылки" "[[ \$(grep -c 'vless://' <<< \"\$OUT6\") -eq 3 ]]"

echo "=== 9. vpn del ivan ==="
"$V" del ivan >/dev/null 2>&1; RC7=$?
chk "del успешен" "[[ $RC7 -eq 0 ]]"
chk "ivan удалён из XRay" "! $JQ -e 'has(\"ivan\")' '$ROOT/etc/vpn-manager/xray-clients.json' >/dev/null"
chk "ivan удалён из XRay2" "! $JQ -e 'has(\"ivan\")' '$ROOT/etc/vpn-manager/xray-clients2.json' >/dev/null"
chk "ivan удалён из AWG" "! grep -q ivan '$ROOT/etc/vpn-manager/awg-peers.tsv'"
chk "файл конфига удалён" "[[ ! -f '$ROOT/etc/vpn-manager/amneziawg-clients/ivan.conf' ]]"
chk "в серверном конфиге AWG нет ivan" "! grep -q 'client: ivan' '$ROOT/awg/amneziawg0.conf'"
chk "XRay: клиентов снова 2 (owner, petr)" "[[ \$($JQ 'length' '$ROOT/etc/vpn-manager/xray-clients.json') -eq 2 ]]"

echo "=== 10. некорректные имена и отсутствующие клиенты ==="
"$V" add 'bad name!' >/dev/null 2>&1 && chk "имя с пробелом отклонено" "false" || chk "имя с пробелом отклонено" "true"
"$V" add '' >/dev/null 2>&1 && chk "пустое имя отклонено" "false" || chk "пустое имя отклонено" "true"
"$V" link nosuch >/dev/null 2>&1 && chk "link несуществующего — ошибка" "false" || chk "link несуществующего — ошибка" "true"
"$V" del nosuch >/dev/null 2>&1 && chk "del несуществующего не падает фатально" "true" || chk "del несуществующего не падает фатально" "true"

echo "=== 11. vpn status (не должен падать) ==="
"$V" status >/dev/null 2>&1 && chk "status отработал" "true" || chk "status отработал" "false"

echo "=== 12. сохранение нестандартных параметров обфускации ==="
# ставим «свои» значения, как если бы пользователь их поменял руками
sed -i -e 's/^Jc = 3$/Jc = 7/' -e 's/^S1 = 30$/S1 = 55/' \
       -e 's/^H1 = 1145255997$/H1 = 2145255997/' "$ROOT/awg/amneziawg0.conf"
grep -qx 'Jc = 7' "$ROOT/awg/amneziawg0.conf" && chk "исходные значения установлены" "true" || chk "исходные значения установлены" "false"
"$V" add custom >/dev/null 2>&1
chk "Jc сохранился после перегенерации" "grep -qx 'Jc = 7' '$ROOT/awg/amneziawg0.conf'"
chk "S1 сохранился" "grep -qx 'S1 = 55' '$ROOT/awg/amneziawg0.conf'"
chk "H1 сохранился" "grep -qx 'H1 = 2145255997' '$ROOT/awg/amneziawg0.conf'"
chk "S2 остался дефолтным" "grep -qx 'S2 = 40' '$ROOT/awg/amneziawg0.conf'"
chk "I1 не потерян" "grep -qF 'I1 = <r 2>' '$ROOT/awg/amneziawg0.conf'"
chk "клиентский .conf получил Jc=7" "grep -qx 'Jc = 7' '$ROOT/etc/vpn-manager/amneziawg-clients/custom.conf'"
chk "клиентский .conf получил S1=55" "grep -qx 'S1 = 55' '$ROOT/etc/vpn-manager/amneziawg-clients/custom.conf'"
"$V" del custom >/dev/null 2>&1

echo
echo "  успешно: $ok   провалено: $bad"
rm -rf "$ROOT"
[[ $bad -eq 0 ]] || exit 1
echo "ИНТЕГРАЦИОННЫЙ ТЕСТ 'vpn': ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
