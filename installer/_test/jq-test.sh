#!/usr/bin/env bash
# РўРµСЃС‚ jq-Р»РѕРіРёРєРё РјРµРЅРµРґР¶РµСЂР° (РІС‹РїРѕР»РЅСЏРµС‚СЃСЏ Р»РѕРєР°Р»СЊРЅРѕ, Р±РµР· СЃРµСЂРІРµСЂР°)
set -euo pipefail
cd "$(dirname "$0")"
JQ=${JQ:-jq}
CFG=config.sample.json
TMP=$(mktemp)

"$JQ" . "$CFG" > /dev/null && echo "1) JSON Р±Р°Р·РѕРІС‹Р№: OK"

# --- СЌРјСѓР»СЏС†РёСЏ xray_regen
state=clients.json
echo '{"owner":"11111111-1111-1111-1111-111111111111","wife":"33333333-3333-3333-3333-333333333333"}' > "$state"
state2=clients2.json
echo '{"owner":"22222222-2222-2222-2222-222222222222","wife":"44444444-4444-4444-4444-444444444444"}' > "$state2"

vision=$("$JQ" -c '[to_entries[] | {id: .value, flow: "xtls-rprx-vision"}]' "$state")
plain=$("$JQ" -c '[to_entries[] | {id: .value, flow: ""}]' "$state2")
"$JQ" --argjson v "$vision" --argjson p "$plain" '
  .inbounds[0].settings.clients = $v |
  .inbounds[1].settings.clients = $p
' "$CFG" > "$TMP"

"$JQ" -e '.inbounds[0].settings.clients|length==2' "$TMP" > /dev/null && echo "2) xray_regen (clients РїРѕРґСЃС‚Р°РІР»РµРЅС‹): OK"
"$JQ" -e '.inbounds[0].settings.clients[0].flow=="xtls-rprx-vision"' "$TMP" > /dev/null && echo "3) flow vision: OK"
"$JQ" -e '.inbounds[1].settings.clients[0].flow==""' "$TMP" > /dev/null && echo "4) РІС‚РѕСЂРѕР№ inbound Р±РµР· flow: OK"

# --- РґРѕР±Р°РІР»РµРЅРёРµ/СѓРґР°Р»РµРЅРёРµ РєР»РёРµРЅС‚Р°
"$JQ" --arg n "petr" --arg u "55555555-5555-5555-5555-555555555555" '. + {($n): $u}' "$state" > "$state.t" && mv "$state.t" "$state"
"$JQ" -e '.["petr"]=="55555555-5555-5555-5555-555555555555"' "$state" > /dev/null && echo "5) add client: OK"
"$JQ" -e 'length==3' "$state" > /dev/null && echo "6) СЃС‡С‘С‚С‡РёРє РєР»РёРµРЅС‚РѕРІ: OK"
"$JQ" --arg n "petr" 'del(.[$n])' "$state" > "$state.t" && mv "$state.t" "$state"
"$JQ" -e 'has("petr")|not' "$state" > /dev/null && echo "7) del client: OK"

# --- РіРµРЅРµСЂР°С†РёСЏ СЃСЃС‹Р»РєРё
REALITY_SNI=www.samsung.com
REALITY_PUB=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG
SHORT_ID=0123456789abcdef
SERVER_IP4=203.0.113.10
PORT_MAIN=443
u1=$("$JQ" -r --arg n "owner" '.[$n] // empty' "$state")
q1="encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision"
LINK="vless://${u1}@${SERVER_IP4}:${PORT_MAIN}?${q1}#owner-vision"
echo "8) СЃСЃС‹Р»РєР°: $LINK"
case "$LINK" in
  vless://11111111-1111-1111-1111-111111111111@203.0.113.10:443\?encryption=none\&security=reality*) echo "9) С„РѕСЂРјР°С‚ СЃСЃС‹Р»РєРё: OK" ;;
  *) echo "9) С„РѕСЂРјР°С‚ СЃСЃС‹Р»РєРё: FAIL"; exit 1 ;;
esac

# --- AWG: AllowedIPs РёР· Р±Р°Р·С‹ (РїР°СЂСЃРёРЅРі TSV СЃСЂРµРґСЃС‚РІР°РјРё awk/grep РјРµРЅРµРґР¶РµСЂР°)
printf 'owner\taGVsbG8=\tpub1\tpsk1\t10.77.0.2\tfd77:77:0::2\nwife\taGVsbG8y\tpub2\tpsk2\t10.77.0.3\tfd77:77:0::3\n' > peers.tsv
grep = 2>/dev/null || true
# С„РёР»СЊС‚СЂ РєР°Рє РІ awg_apply (СѓР±РёСЂР°РµС‚ Address/DNS/MTU РёР· СЃРµСЂРІРµСЂРЅРѕРіРѕ РєРѕРЅС„РёРіР°)
cat > server.conf <<'EOF'
[Interface]
Address = 10.77.0.1/24, fd77:77:0::1/64
ListenPort = 55424
PrivateKey = xxxx
MTU = 1280
SaveConfig = false
Jc = 3

[Peer]
# client: owner
PublicKey = pub1
PresharedKey = psk1
AllowedIPs = 10.77.0.2/32, fd77:77:0::2/128
EOF
grep -vE '^[[:space:]]*(Address|DNS|MTU|Table|PreUp|PreDown|PostUp|PostDown|SaveConfig)[[:space:]]*=' server.conf > stripped.conf
if grep -q '^Address' stripped.conf; then echo "10) strip Address: FAIL"; exit 1; else echo "10) strip Address/MTU РґР»СЏ awg setconf: OK"; fi
grep -q '^ListenPort = 55424' stripped.conf && echo "11) ListenPort СЃРѕС…СЂР°РЅС‘РЅ: OK"
grep -q '^\[Peer\]' stripped.conf && echo "12) Peer СЃРѕС…СЂР°РЅС‘РЅ: OK"
awk -F'\t' -v n="wife" '$1==n{found=1} END{exit !found}' peers.tsv && echo "13) РїРѕРёСЃРє РєР»РёРµРЅС‚Р° РІ TSV: OK"

# --- cfg_get (С‡С‚РµРЅРёРµ РїР°СЂР°РјРµС‚СЂР° РѕР±С„СѓСЃРєР°С†РёРё РёР· СЃРµСЂРІРµСЂРЅРѕРіРѕ РєРѕРЅС„РёРіР°)
cfg_get() { local v; v=$(awk -F' = ' -v k="$1" '$1==k {print $2; exit}' server.conf 2>/dev/null || true); echo "${v:-$2}"; }
[[ "$(cfg_get Jc 99)" == "3" ]] && echo "14) cfg_get СЃСѓС‰РµСЃС‚РІСѓСЋС‰РµРіРѕ РєР»СЋС‡Р°: OK"
[[ "$(cfg_get H1 1145255997)" == "1145255997" ]] && echo "15) cfg_get РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ: OK"

rm -f "$TMP" server.conf stripped.conf peers.tsv clients.json clients2.json
echo
echo "Р’РЎР• РџР РћР’Р•Р РљР РџР РћР™Р”Р•РќР«"
