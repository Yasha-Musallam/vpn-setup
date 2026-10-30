#!/usr/bin/env bash
# =====================================================================
#  ШАГ 1. Подготовка сервера (Ubuntu 24.04)
#  - обновление системы и базовые пакеты
#  - форвардинг, BBR, conntrack
#  - swap (нужен для сборки модуля ядра на VPS с 1-2 GB RAM)
#  - firewall ufw: SSH + 443/tcp + 8443/tcp + 55424/udp
#  - сохранение параметров в /etc/vpn-manager/system.env
#
#  Запуск:  bash 01-prep.sh
# =====================================================================
set -euo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYA=$'\e[36m'; RST=$'\e[0m'
ok()   { echo "${GRN}[ OK ]${RST} $*"; }
info() { echo "${CYA}[ .. ]${RST} $*"; }
warn() { echo "${YEL}[ !! ]${RST} $*"; }
die()  { echo "${RED}[FAIL]${RST} $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запускать нужно от root (вы ведь зашли как root?)"
command -v apt-get >/dev/null || die "Этот скрипт для Ubuntu/Debian"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

STATE_DIR=/etc/vpn-manager
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"

. /etc/os-release
info "Система: ${PRETTY_NAME:-?} | ядро: $(uname -r) | RAM: $(free -m | awk '/Mem:/{print $2}') MB | диск: $(df -h / | awk 'NR==2{print $4}') свободно"

# ---------------------------------------------------------------------
# 1. Пакеты
# ---------------------------------------------------------------------
info "apt update + upgrade (может занять несколько минут)..."
apt-get update -y -qq
apt-get -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade || warn "upgrade завершился с замечаниями (обычно не критично)"

info "Ставлю базовые пакеты..."
apt-get -y -qq install \
  curl wget ca-certificates gnupg lsb-release software-properties-common \
  jq qrencode unzip tar iptables nftables ufw socat dnsutils iproute2 \
  openssl cron logrotate htop net-tools >/dev/null
ok "Базовые пакеты установлены"

# ---------------------------------------------------------------------
# 2. Время (для REALITY/TLS расхождение часов = обрыв рукопожатия)
# ---------------------------------------------------------------------
systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
timedatectl set-ntp true >/dev/null 2>&1 || true
ok "Синхронизация времени: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '?')"

# ---------------------------------------------------------------------
# 3. Форвардинг + BBR
# ---------------------------------------------------------------------
info "Настраиваю sysctl (форвардинг + BBR)..."
cat > /etc/sysctl.d/99-vpn-server.conf <<'EOF'
# --- VPN-сервер ---
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
# BBR: заметно лучше на дальних каналах с потерями (Европа <-> Москва)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.netfilter.nf_conntrack_max = 262144
fs.file-max = 1048576
EOF
sysctl --system >/dev/null 2>&1 || true
[[ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]] && ok "ip_forward = 1" || die "Не удалось включить ip_forward"
if [[ "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" == "bbr" ]]; then
  ok "BBR включён"
else
  warn "BBR недоступен на этом ядре — останется cubic (не критично)"
fi

# ---------------------------------------------------------------------
# 4. Swap (для сборки модуля ядра и Xray при 1-2 GB RAM)
# ---------------------------------------------------------------------
if swapon --show 2>/dev/null | grep -q . ; then
  ok "Swap уже есть: $(swapon --show 2>/dev/null | awk 'NR==2{print $3}')"
else
  FREESPACE=$(df -Pm / | awk 'NR==2{print $4}')
  if [[ ${FREESPACE:-0} -gt 3000 ]]; then
    info "Создаю swap 1 GB..."
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Swap 1 GB включён"
  else
    warn "Swap нет и на диске мало места — пропускаю"
  fi
fi

# ---------------------------------------------------------------------
# 5. Firewall
# ---------------------------------------------------------------------
SSH_PORT=$(ss -tlpnH 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | sort -u | head -n1)
SSH_PORT=${SSH_PORT:-22}
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || SSH_PORT=22
info "SSH слушает порт: ${SSH_PORT}"

# ufw по умолчанию блокирует FORWARD — это ломает VPN-трафик. Разрешаем.
if [[ -f /etc/default/ufw ]]; then
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  grep -q '^DEFAULT_FORWARD_POLICY' /etc/default/ufw || echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> /etc/default/ufw
fi

info "Настраиваю ufw..."
ufw --force disable >/dev/null 2>&1 || true
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}"/tcp comment 'ssh'         >/dev/null
ufw allow 443/tcp           comment 'xray-reality' >/dev/null
ufw allow 8443/tcp          comment 'xray-compat'  >/dev/null
ufw allow 55424/udp         comment 'amneziawg'    >/dev/null
ufw --force enable >/dev/null
ok "ufw включён"
ufw status numbered | sed 's/^/      /'

# ---------------------------------------------------------------------
# 6. Публичные адреса
# ---------------------------------------------------------------------
IP4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
[[ -z "${IP4:-}" ]] && IP4=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
IP6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
[[ -z "${IP6:-}" ]] && IP6=$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)
[[ -n "${IP4:-}" ]] || die "Не смог определить IPv4 сервера"
ok "IPv4 сервера: ${IP4}"
if [[ -n "${IP6:-}" ]]; then ok "IPv6 сервера: ${IP6}"; else warn "IPv6 не обнаружен на интерфейсе"; fi

cat > "$STATE_DIR/system.env" <<EOF
SSH_PORT=${SSH_PORT}
SERVER_IP4=${IP4}
SERVER_IP6=${IP6}
EOF
chmod 600 "$STATE_DIR/system.env"

# ---------------------------------------------------------------------
# 7. Итог
# ---------------------------------------------------------------------
echo
ok "ШАГ 1 завершён."
if [[ -f /var/run/reboot-required ]]; then
  warn "Система обновила ядро. Сделайте 'reboot' и продолжите со ШАГА 2 — иначе модуль AmneziaWG может не собраться под работающее ядро."
fi
cat <<EOF

  Дальше по порядку:
    bash 02-xray-reality.sh    # XRay: VLESS+Vision+REALITY (для v2box)
    bash 03-amneziawg.sh       # AmneziaWG: UDP с обфускацией
    bash 04-manager.sh         # команда 'vpn' — создание клиентов

EOF
