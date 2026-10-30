#!/usr/bin/env bash
# =====================================================================
#  ШАГ 5 (необязательный). Самопроверка сервера
#  Проверяет: службы, порты, файрвол, форвардинг, NAT, конфиги, ключи.
#  Ничего не меняет — только читает и печатает отчёт.
#
#  Запуск:  bash 05-verify.sh
# =====================================================================
set -uo pipefail   # без -e: хотим дойти до конца и показать все проблемы

GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; CYA=$'\e[36m'; BLD=$'\e[1m'; RST=$'\e[0m'
PASS=0; FAIL=0; WARN=0
p() { echo "  ${GRN}✓${RST} $*"; PASS=$((PASS+1)); }
f() { echo "  ${RED}✗${RST} $*"; FAIL=$((FAIL+1)); }
w() { echo "  ${YEL}!${RST} $*"; WARN=$((WARN+1)); }
sec(){ echo; echo "${BLD}── $* ──${RST}"; }

STATE_DIR=/etc/vpn-manager
XRAY_DIR=/usr/local/etc/xray
AWG_DIR=/etc/amnezia/amneziawg
IFACE=amneziawg0
PORT_MAIN=443; PORT_COMPAT=8443; AWG_PORT=55424
[[ -f "$STATE_DIR/system.env" ]] && . "$STATE_DIR/system.env"
[[ -f "$STATE_DIR/xray.env"   ]] && . "$STATE_DIR/xray.env"
[[ -f "$STATE_DIR/awg.env"    ]] && . "$STATE_DIR/awg.env"
IFACE=${IFACE:-amneziawg0}
PORT_MAIN=${PORT_MAIN:-443}; PORT_COMPAT=${PORT_COMPAT:-8443}; AWG_PORT=${AWG_PORT:-55424}

echo "${BLD}═══ Самопроверка VPN-сервера ═══${RST}"

# ---------------------------------------------------------------- система
sec "Система"
if [[ $EUID -eq 0 ]]; then p "запуск от root"; else w "запуск не от root (часть проверок недоступна)"; fi
p "ядро: $(uname -r)"
p "время: $(date '+%Y-%m-%d %H:%M:%S %Z')"
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
  p "часы синхронизированы (важно для TLS)"
else
  w "часы НЕ синхронизированы — REALITY может не работать: timedatectl set-ntp true"
fi
RAM=$(free -m | awk '/Mem:/{print $2}')
[[ $RAM -ge 400 ]] && p "RAM: ${RAM} MB" || w "RAM всего ${RAM} MB — может не хватить"
SW=$(free -m | awk '/Swap:/{print $2}')
[[ $SW -gt 0 ]] && p "swap: ${SW} MB" || w "swap отсутствует (для 1-2 GB RAM желателен)"

# ------------------------------------------------------------ форвардинг
sec "Маршрутизация"
[[ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]] && p "ip_forward = 1" || f "ip_forward = 0 → VPN не выпустит трафик"
CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
if [[ "$CC" == "bbr" ]]; then p "congestion control: bbr"; else w "congestion control: ${CC} (BBR недоступен/не включён)"; fi
WAN=$(ip -4 route show default | awk '{print $5; exit}')
[[ -n "$WAN" ]] && p "внешний интерфейс: ${WAN}" || f "нет default route"

# -------------------------------------------------------------- firewall
sec "Файрвол"
if command -v ufw >/dev/null; then
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    p "ufw активен"
    for pr in "${PORT_MAIN}/tcp" "${PORT_COMPAT}/tcp" "${AWG_PORT}/udp"; do
      ufw status 2>/dev/null | grep -qE "^${pr%%/*}(/tcp|/udp)?\s+ALLOW" && p "разрешён ${pr}" || w "в ufw не найден явный allow для ${pr}"
    done
    grep -q 'DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw 2>/dev/null \
      && p "ufw разрешает FORWARD" || f "DEFAULT_FORWARD_POLICY не ACCEPT — VPN-трафик будет блокироваться"
  else
    w "ufw выключен (порт открыт, но и защита слабее)"
  fi
else
  w "ufw не установлен"
fi

# ------------------------------------------------------------------ XRay
sec "XRay (VLESS + REALITY)"
if ! command -v xray >/dev/null; then
  f "xray не установлен"
else
  p "версия: $(xray version 2>/dev/null | head -n1)"
  systemctl is-active --quiet xray && p "служба xray активна" || f "служба xray не работает: journalctl -u xray -n 50"
  systemctl is-enabled --quiet xray 2>/dev/null && p "автозапуск включён" || w "автозапуск выключен: systemctl enable xray"
  if [[ -f "$XRAY_DIR/config.json" ]]; then
    if xray run -test -config "$XRAY_DIR/config.json" >/tmp/verify-xray.log 2>&1; then
      p "конфиг валиден"
    else
      f "конфиг невалиден:"; sed 's/^/       /' /tmp/verify-xray.log
    fi
    grep -q '<r 2>' "$XRAY_DIR/config.json" 2>/dev/null && w "странно: в конфиге XRay найдены AWG-параметры"
    [[ -s "$XRAY_DIR/reality.key" ]] && p "ключ REALITY на месте" || f "нет $XRAY_DIR/reality.key"
    [[ -s "$XRAY_DIR/reality.pub" ]] && p "публичный ключ: $(cat "$XRAY_DIR/reality.pub")" || f "нет $XRAY_DIR/reality.pub"
    [[ -s "$XRAY_DIR/shortid" ]] && p "shortId: $(cat "$XRAY_DIR/shortid")" || f "нет $XRAY_DIR/shortid"
  else
    f "нет конфига $XRAY_DIR/config.json"
  fi
  ss -tlnpH 2>/dev/null | grep -q ":${PORT_MAIN}\b" && p "слушает ${PORT_MAIN}/tcp" || f "не слушает ${PORT_MAIN}/tcp"
  ss -tlnpH 2>/dev/null | grep -q ":${PORT_COMPAT}\b" && p "слушает ${PORT_COMPAT}/tcp" || w "не слушает ${PORT_COMPAT}/tcp (резервный профиль)"
  if command -v openssl >/dev/null && [[ -n "${REALITY_SNI:-}" ]]; then
    if echo | timeout 10 openssl s_client -connect "127.0.0.1:${PORT_MAIN}" -servername "$REALITY_SNI" 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
      p "на ${PORT_MAIN} отдаётся валидный TLS для ${REALITY_SNI}"
    else
      w "TLS-проверка локально не удалась (у REALITY это бывает нормой)"
    fi
  fi
fi

# ------------------------------------------------------------ AmneziaWG
sec "AmneziaWG"
if ! command -v awg >/dev/null; then
  f "amneziawg-tools не установлены"
else
  p "утилиты: $(awg --version 2>/dev/null | head -n1)"
  if lsmod 2>/dev/null | grep -q '^amneziawg'; then
    p "модуль ядра загружен"
  elif command -v amneziawg-go >/dev/null; then
    w "работает userspace-реализация (amneziawg-go) — медленнее"
  else
    f "ни модуля ядра, ни amneziawg-go: нужен reboot или установка amneziawg-dkms"
  fi
  if ip link show "$IFACE" >/dev/null 2>&1; then
    p "интерфейс ${IFACE} поднят"
    ip -4 addr show "$IFACE" | grep -q "inet " && p "IPv4: $(ip -4 addr show "$IFACE" | awk '/inet /{print $2}')" || f "у ${IFACE} нет IPv4"
    ip -6 addr show "$IFACE" 2>/dev/null | grep -q "inet6 " && p "IPv6: $(ip -6 addr show "$IFACE" | awk '/inet6 /{print $2}' | head -n1)"
    PEERCOUNT=$(awg show "$IFACE" peers 2>/dev/null | grep -c . || true)
    p "настроено пиров: ${PEERCOUNT}"
  else
    f "интерфейс ${IFACE} не поднят: awg-quick up ${IFACE}"
  fi
  systemctl is-enabled --quiet "awg-quick@${IFACE}" 2>/dev/null && p "автозапуск ${IFACE} включён" || w "автозапуск не включён: systemctl enable awg-quick@${IFACE}"
  systemctl is-active --quiet awg-nat 2>/dev/null && p "служба awg-nat активна" || w "служба awg-nat не активна (NAT не восстановится после reboot)"
  ss -ulnpH 2>/dev/null | grep -q ":${AWG_PORT}\b" && p "слушает UDP ${AWG_PORT}" || f "не слушает UDP ${AWG_PORT}"
  if [[ -s "$AWG_DIR/${IFACE}.conf" ]]; then
    p "серверный конфиг на месте"
    grep -qE '^(Jc|S1|H1|I1) *=' "$AWG_DIR/${IFACE}.conf" && p "параметры обфускации присутствуют" || f "в конфиге нет параметров обфускации!"
  else
    f "нет конфига $AWG_DIR/${IFACE}.conf"
  fi
fi

# ------------------------------------------------------------------- NAT
sec "NAT"
iptables -t nat -C POSTROUTING -s "${SUBNET_V4:-10.77.0.0/24}" -o "${WAN:-eth0}" -j MASQUERADE 2>/dev/null \
  && p "MASQUERADE для ${SUBNET_V4:-10.77.0.0/24} есть" \
  || f "нет правила MASQUERADE (запустите /usr/local/sbin/awg-nat.sh)"
iptables -C FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null && p "FORWARD разрешён" || w "нет правила FORWARD для ${IFACE}"
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  && p "MSS clamp настроен" || w "нет MSS clamp (возможны подвисания страниц)"

# -------------------------------------------------------------- клиенты
sec "Клиенты"
[[ -s "$STATE_DIR/xray-clients.json" ]] && p "XRay: $(jq 'length' "$STATE_DIR/xray-clients.json" 2>/dev/null || echo '?') клиент(ов)" || w "XRay: клиентов нет"
[[ -s "$STATE_DIR/awg-peers.tsv" ]] && p "AmneziaWG: $(wc -l < "$STATE_DIR/awg-peers.tsv") клиент(ов)" || w "AmneziaWG: клиентов нет"
[[ -x /usr/local/bin/vpn ]] && p "команда 'vpn' установлена" || w "нет /usr/local/bin/vpn (запустите 04-manager.sh)"
for d in "$STATE_DIR" /usr/local/etc/xray /etc/amnezia/amneziawg; do
  perm=$(stat -c '%a' "$d" 2>/dev/null)
  [[ -n "$perm" ]] && [[ "$perm" -le 750 ]] && p "права ${perm} на ${d}" || w "права ${perm:-?} на ${d} — стоит ограничить"
done

# --------------------------------------------------------------- трафик
sec "Выход в интернет"
for url in https://api.ipify.org https://www.google.com; do
  if curl -4 -fsS --max-time 8 -o /dev/null "$url" 2>/dev/null; then
    p "сервер имеет доступ к ${url}"
  else
    w "нет доступа к ${url}"
  fi
done
if command -v ping >/dev/null; then
  ping -c1 -W3 -I "${SERVER_V4:-10.77.0.1}" 1.1.1.1 >/dev/null 2>&1 \
    && p "трафик из VPN-подсети уходит наружу" \
    || w "ICMP из ${SERVER_V4:-10.77.0.1} не прошёл (часто блокируется провайдером)"
fi

# ---------------------------------------------------------------- итоги
echo
echo "${BLD}═══ Итог ═══${RST}"
echo "  ${GRN}успешно: ${PASS}${RST}   ${YEL}предупреждений: ${WARN}${RST}   ${RED}ошибок: ${FAIL}${RST}"
if [[ $FAIL -eq 0 ]]; then
  echo "  ${GRN}Сервер выглядит исправным. Если клиент не подключается — проблема в клиенте или в блокировке провайдера.${RST}"
else
  echo "  ${RED}Есть ошибки — см. строки с ✗ выше.${RST}"
fi
exit 0
