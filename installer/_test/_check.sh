#!/usr/bin/env bash
# Проверка синтаксиса всех установочных скриптов (лежат на уровень выше).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
rc=0
found=0
for f in *.sh; do
  [[ -f "$f" ]] || continue
  found=1
  printf '%-26s ' "$f"
  if bash -n "$f"; then echo "syntax OK"; else echo "SYNTAX ERROR"; rc=1; fi
done
[[ $found -eq 1 ]] || { echo "не найдено ни одного .sh в $(pwd)"; exit 1; }
exit $rc
