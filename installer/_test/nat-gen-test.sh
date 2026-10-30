#!/usr/bin/env bash
# Проверяем, что генерируемый /usr/local/sbin/awg-nat.sh — валидный shell
set -euo pipefail
cd "$(dirname "$0")"
SRC=${1:-../03-amneziawg.sh}
[[ -f "$SRC" ]] || { echo "нет $SRC"; exit 1; }

for HAVE_V6 in 1 0; do
  WAN_IF=eth0
  SUBNET_V4=10.77.0.0/24
  SUBNET_V6=fd77:77:0::/64
  IFACE=amneziawg0

  # вырезаем тело heredoc (между строкой cat > ...awg-nat.sh <<EOF и строкой EOF)
  awk '/^cat > \/usr\/local\/sbin\/awg-nat.sh <</{f=1;next} f&&/^EOF$/{exit} f' "$SRC" > nat.tmp.tpl
  [[ -s nat.tmp.tpl ]] || { echo "не найден heredoc awg-nat.sh"; exit 1; }

  # подставляем переменные, как это сделал бы bash при запуске скрипта
  eval "cat <<NATEOF
$(cat nat.tmp.tpl)
NATEOF" > nat.$HAVE_V6.sh

  if bash -n nat.$HAVE_V6.sh; then
    echo "  OK   сгенерированный awg-nat.sh (HAVE_V6=$HAVE_V6) синтаксически валиден"
  else
    echo "  FAIL awg-nat.sh (HAVE_V6=$HAVE_V6) содержит синтаксическую ошибку"; exit 1
  fi

  # смысловые проверки
  grep -q 'UPLINK="eth0"' nat.$HAVE_V6.sh && echo "  OK   UPLINK подставлен" || { echo "  FAIL UPLINK"; exit 1; }
  grep -q 'SUBNET_V4="10.77.0.0/24"' nat.$HAVE_V6.sh && echo "  OK   SUBNET_V4 подставлен" || { echo "  FAIL SUBNET_V4"; exit 1; }
  grep -q "HAVE_V6=$HAVE_V6" nat.$HAVE_V6.sh && echo "  OK   HAVE_V6=$HAVE_V6" || { echo "  FAIL HAVE_V6"; exit 1; }
  grep -q 'iptables -t nat -A POSTROUTING' nat.$HAVE_V6.sh && echo "  OK   MASQUERADE присутствует" || { echo "  FAIL MASQUERADE"; exit 1; }
  if [[ $HAVE_V6 -eq 1 ]]; then
    grep -q 'ip6tables -t nat -A POSTROUTING' nat.$HAVE_V6.sh && echo "  OK   IPv6 MASQUERADE присутствует" || { echo "  FAIL ip6 MASQUERADE"; exit 1; }
  fi
done
rm -f nat.tmp.tpl nat.1.sh nat.0.sh
echo "ГЕНЕРАЦИЯ awg-nat.sh: OK"
