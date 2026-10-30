#!/usr/bin/env bash
# Проверяем команды скачивания из инструкции "КАК-ПЕРЕНЕСТИ-ФАЙЛЫ.md"
# на РЕАЛЬНОМ публичном репозитории (XTLS/Xray-install как донор).
set -uo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d); cd "$WORK"
ok=0; bad=0
chk(){ if eval "$2"; then echo "  OK   $1"; ok=$((ok+1)); else echo "  FAIL $1"; bad=$((bad+1)); fi; }

# --- 1. архивом (Вариант 1), как в инструкции
echo "=== 1. Вариант 1: tar.gz одной строкой ==="
curl -fsSL https://github.com/XTLS/Xray-install/archive/refs/heads/main.tar.gz | tar xz
chk "архив распаковался" "[[ -d Xray-install-main ]]"
chk "в корне архива есть файлы" "[[ -n \$(ls Xray-install-main) ]]"
chk "имя каталога = <repo>-<branch>" "[[ -d 'Xray-install-main' ]]"

# --- 2. по файлам (Вариант 2) — успешный случай, ТОЧНО КАК В ИНСТРУКЦИИ
echo
echo "=== 2. Вариант 2: цикл по файлам ==="
BASE=https://raw.githubusercontent.com/XTLS/Xray-install/main
mkdir -p "$WORK/f2" && cd "$WORK/f2"
for f in install-release.sh; do
  curl -fsSL "$BASE/$f" -o "$f"
  if [ "$(head -c 2 "$f" 2>/dev/null)" = "#!" ]; then
    echo "OK   $f ($(wc -c < "$f") байт)"
  else
    echo "ПЛОХО $f — скачался не скрипт, перекачайте"; rm -f "$f"
  fi
done
chk "файл скачался и начинается с #!" "head -c 2 install-release.sh | grep -q '#!'"

# --- 3. поведение при 404 (главная ловушка)
echo
echo "=== 3. Проверка ловушки: 404 ==="
BAD="$BASE/nosuchfile.sh"
echo "  -- с -f (как в инструкции) --"
curl -fsSL "$BAD" -o bad.sh 2>/dev/null; rc=$?
echo "  rc=$rc, файл создан: $([[ -e bad.sh ]] && echo да || echo НЕТ)"
chk "curl -f вернул ненулевой код" "[[ $rc -ne 0 ]]"
chk "curl -f НЕ создал файл" "[[ ! -e bad.sh ]]"

echo "  -- без -f (так делать нельзя) --"
curl -sSL "$BAD" -o bad2.sh 2>/dev/null; rc2=$?
echo "  rc=$rc2, размер=$(wc -c < bad2.sh 2>/dev/null), содержимое=[$(cat bad2.sh 2>/dev/null)]"
chk "без -f curl врёт: код 0 при ошибке" "[[ $rc2 -eq 0 ]]"
chk "без -f создаётся мусорный файл" "[[ -e bad2.sh ]]"
# вот почему проверки размера НЕДОСТАТОЧНО:
chk "мусорный файл проходит bash -n (не спасает!)" "bash -n bad2.sh 2>/dev/null"
chk "мусорный файл НЕ пустой ([ -s ] не спасает!)" "[ -s bad2.sh ]"
# а проверка shebang — спасает:
chk "проверка shebang ЛОВИТ мусор" "[[ \"\$(head -c 2 bad2.sh)\" != '#!' ]]"

# --- 4. проверка доступности github (из таблицы ошибок)
echo
echo "=== 4. Диагностика из таблицы ==="
code=$(curl -sI https://github.com | head -1)
echo "  curl -sI https://github.com | head -1  =>  $code"
chk "получили HTTP-статус" "[[ -n \"\$code\" ]]"
code2=$(curl -sI "$BASE/install-release.sh" | head -1)
echo "  curl -sI BASE/<file> | head -1  =>  $code2"

# --- 5. проверка синтаксиса пачкой (Шаг 5)
echo
echo "=== 5. Шаг 5: массовая проверка ==="
mkdir -p "$WORK/f3" && cd "$WORK/f3"
cp "$WORK/f2/install-release.sh" a.sh
cp "$WORK/f2/install-release.sh" b.sh
out=$(for f in *.sh; do bash -n "$f" && echo "$f — OK"; done)
echo "$out" | sed 's/^/  /'
chk "обе строки OK" "[[ \$(echo \"\$out\" | grep -c 'OK') -eq 2 ]]"

cd /
rm -rf "$WORK"
echo
echo "  успешно: $ok   провалено: $bad"
[[ $bad -eq 0 ]] || exit 1
echo "КОМАНДЫ ИЗ ИНСТРУКЦИИ РАБОТАЮТ"
