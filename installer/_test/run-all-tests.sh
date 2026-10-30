#!/usr/bin/env bash
# =====================================================================
#  Запуск всех тестов комплекта (для разработки).
#  На сервере НЕ нужен — тесты запускаются на машине разработчика.
#
#  Требуется: bash, jq (в пути или JQ=./jq.exe), xray (в пути или XRAY=./xray.exe)
#  Запуск:  bash _test/run-all-tests.sh
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")"

JQ=${JQ:-$(command -v jq || true)}
XRAY=${XRAY:-$(command -v xray || true)}
[[ -z "$JQ"   ]] && JQ=./jq.exe
[[ -z "$XRAY" ]] && XRAY=./xray.exe
export JQ XRAY

fail=0
run() {
  local name="$1"; shift
  echo
  echo "════════ $name ════════"
  if "$@"; then
    echo "──────── $name: УСПЕШНО"
  else
    echo "──────── $name: ПРОВАЛ"
    fail=$((fail+1))
  fi
}

echo "═══════════════════════════════════════════════"
echo " Тесты комплекта установки VPN"
echo "═══════════════════════════════════════════════"

run "Синтаксис всех скриптов" bash _check.sh

if [[ -x "$JQ" ]] || command -v jq >/dev/null 2>&1; then
  run "jq-логика менеджера" bash jq-test.sh
  run "Интеграционный тест 'vpn'" bash vpn-integration-test.sh ../04-manager.sh
else
  echo; echo "!! jq не найден — тесты jq и 'vpn' пропущены (JQ=/путь/к/jq)"
  fail=$((fail+1))
fi

run "Генерация конфигов AmneziaWG" bash awg-gen-test.sh ../03-amneziawg.sh
run "Генерация NAT-скрипта" bash nat-gen-test.sh ../03-amneziawg.sh
run "Значение I1 по умолчанию" bash i1-default-test.sh

if [[ -f ../xray-install.sh ]] || [[ -n "${XRAY_INSTALL:-}" ]]; then
  run "Соответствие systemd-юнита Xray" bash unit-check-test.sh "${XRAY_INSTALL:-../xray-install.sh}"
else
  echo; echo "!! xray-install.sh не найден — проверка юнита пропущена"
  echo "   (положите установщик в ../xray-install.sh или задайте XRAY_INSTALL=/путь)"
fi

if [[ -x "$XRAY" ]] || command -v xray >/dev/null 2>&1; then
  run "Валидация конфига Xray (реальный xray -test)" bash xray-validate.sh
else
  echo; echo "!! xray не найден — валидация конфига пропущена (XRAY=/путь/к/xray)"
fi

echo
echo "═══════════════════════════════════════════════"
if [[ $fail -eq 0 ]]; then
  echo " ВСЕ НАБОРЫ ТЕСТОВ ПРОЙДЕНЫ"
else
  echo " НАБОРОВ С ПРОВАЛАМИ: $fail"
fi
echo "═══════════════════════════════════════════════"
exit $fail
