#!/usr/bin/env bash
# Runs every mutant in tests/mutants/DIVE-7873.sh against a throwaway copy of
# this repo and requires tests/backup_unit.sh to go RED on each, and the
# unmutated copy to stay green. A mutant whose sed matched nothing is a broken
# control, not a pass: the copy must differ from the original.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/tests/mutants/DIVE-7873.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fresh() { rm -rf "$W/t"; mkdir -p "$W/t"; cp -a "$ROOT/backup" "$ROOT/tests" "$ROOT/.claude-plugin" "$W/t/"; }
bad=0
fresh; if (cd "$W/t" && bash tests/backup_unit.sh >/dev/null 2>&1); then echo "ok   control: unmutated copy is green"; else echo "FAIL control: unmutated copy is red"; bad=1; fi
for m in $(declare -F | awk '{print $3}' | grep -E '^m[0-9]+$' | sort -V); do
  fresh
  (cd "$W/t" && "$m")
  if cmp -s "$ROOT/backup/bin/backup" "$W/t/backup/bin/backup"; then echo "FAIL $m: the mutation matched nothing"; bad=1; continue; fi
  out=$(cd "$W/t" && bash tests/backup_unit.sh 2>&1); fails=$(grep -c '^FAIL' <<<"$out")
  if (( fails > 0 )); then echo "ok   $m: red ($fails arm(s): $(grep '^FAIL' <<<"$out" | head -1 | sed "s/^FAIL — //" | cut -c1-70))"; else echo "FAIL $m: harness stayed green"; bad=1; fi
done
exit "$bad"
