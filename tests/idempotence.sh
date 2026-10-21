#!/usr/bin/env bash
# Двойной прогон плейбука: на втором не должно быть changed.
#   tests/idempotence.sh [inventories/staging] [доп. аргументы ansible-playbook]
set -euo pipefail
export ANSIBLE_NOCOLOR=1

INV="${1:-inventories/staging}"
shift || true

ansible-playbook -i "$INV" site.yml "$@"

out="$(ansible-playbook -i "$INV" site.yml "$@" | tee /dev/stderr)"
if grep -Eq 'changed=[1-9]' <<<"$out"; then
  echo "FAIL: второй прогон изменил состояние (не идемпотентно)" >&2
  exit 1
fi
echo "OK: второй прогон без изменений"
