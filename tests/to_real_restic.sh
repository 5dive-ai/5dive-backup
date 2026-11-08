#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090
# DIVE-7873 grader arm with the REAL restic 0.17.3 (not the stub): enable --to=<local
# path> on box 1, a nightly run, then restore --to onto an empty box 2 with only the
# owner's code. A curl stub records every request to the 5dive API; it must stay empty.
# Not in CI (it needs the restic release). Usage: bash tests/to_real_restic.sh <restic 0.17.3 binary>
# (get it: the pinned release + sha256 in backup/bin/backup, BACKUP_RESTIC_SHA256).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; REAL="${1:?usage: to_real_restic.sh <restic 0.17.3 binary>}"
[[ "$("$REAL" version)" == "restic 0.17.3 "* ]] || { echo "need restic 0.17.3" >&2; exit 2; }
W="$(mktemp -d /tmp/to-real.XXXXXX)"; trap 'rm -rf "$W"' EXIT
SB="$W/box1"; SB2="$W/box2"; DEST="$W/owner-dest"
mkdir -p "$SB/home/agent-ava/node_modules/x" "$SB/var/lib/5dive" "$SB/etc/5dive/connectors" "$SB2/etc/5dive"
echo "remembers: the blue door" >"$SB/home/agent-ava/MEMORY.md"
echo "chat: hello ava" >"$SB/home/agent-ava/chat.jsonl"
echo junk >"$SB/home/agent-ava/node_modules/x/big.js"
printf '{"agents":{"ava":{}}}' >"$SB/var/lib/5dive/agents.json"
echo "TELEGRAM_BOT_TOKEN=123:bot" >"$SB/etc/5dive/connectors/telegram-ava.env"
echo "CONNECTORD_TOKEN=OLD_BOX" >"$SB/etc/5dive/connectord.env"
echo "CONNECTORD_TOKEN=NEW_BOX" >"$SB2/etc/5dive/connectord.env"

# restic shim: the real binary; a `backup` reads the absolute box paths from the
# sandbox (as relative paths from $SB, so the snapshot tree is home/…, var/…, etc/…
# exactly as on a box).
SHIM="$W/restic"
cat >"$SHIM" <<EOF
#!/usr/bin/env bash
SB="$SB"; REAL="$REAL"
EOF
cat >>"$SHIM" <<'EOF'
args=(); sub=""; prev=""
for a in "$@"; do
  if [[ "$sub" == backup ]]; then
    if [[ "$prev" == --exclude ]]; then [[ "$a" == /* ]] && a="$SB$a"; args+=("$a"); prev="$a"; continue; fi
    if [[ "$a" == /* ]]; then [[ -e "$SB$a" ]] && args+=("${a#/}"); prev="$a"; continue; fi
  fi
  [[ -z "$sub" && "$a" != -* && "$prev" != -o ]] && sub="$a"
  args+=("$a"); prev="$a"
done
echo "restic ${args[*]}" >>"${T}/restic.argv"
[[ "$sub" == backup ]] && cd "$SB"
exec "$REAL" "${args[@]}"
EOF
chmod +x "$SHIM"
export T="$W"

cd "$REPO" || exit 1
# shellcheck source=/dev/null
source backup/bin/backup; set +e
box() {   # <n>: point every seam at box n
  export FIVE_BACKUP_DIR="$W/b$1/etc-backup" FIVE_BACKUP_STATE="$W/b$1/state" FIVE_BACKUP_CRON="$W/b$1/cron"
  export FIVE_BACKUP_LOG="$W/b$1/backup.log" FIVE_BACKUP_RESTIC="$SHIM" FIVE_BACKUP_STAGE="$W/b$1/stage"
  export FIVE_API_BASE_FILE="$W/none" FIVE_API_BASE="https://api.test"
  mkdir -p "$W/b$1"
}
unset FIVE_BACKUP_KEY_TELEGRAM   # the default (1.0.1): no key message
: >"$W/curl.log"; : >"$W/tg"; : >"$W/restic.argv"
curl() { printf '%s\n' "$*" >>"$W/curl.log"; return 22; }   # every 5dive API request lands here
require_root() { :; }
_bk_agent_bot() { [[ "$1" == ava ]] || return 1; printf '123:bot'; }
_bk_agent_dms() { [[ "$1" == ava ]] && printf '%s\n' 1234567890; }
_bk_send() { printf 'chat=%s\n' "$2" >>"$W/tg"; echo '{"ok":true}'; }
systemctl() { :; }
getent() { return 2; }; useradd() { :; }; groupadd() { :; }; usermod() { :; }

PASS=0; FAIL=0
ck() { if eval "$2"; then PASS=$((PASS+1)); echo "ok   — $1"; else FAIL=$((FAIL+1)); echo "FAIL — $1"; fi; }

# ---- box 1: enable --to + nightly run
box 1; REGISTRY="$SB/var/lib/5dive/agents.json"; export FIVE_BACKUP_ROOT="$SB" FIVE_CONNECTORD_ENV="$SB/etc/5dive/connectord.env" FIVE_BACKUP_USERS="$SB/var/lib/5dive/backup-users.tsv"
( cmd_backup enable --to="$DEST" ) >"$W/o1" 2>&1; r1=$?
ck "enable --to=<local path> rc 0 (real restic init)" '[[ $r1 == 0 && -f "$DEST/config" ]]'
CODE=$(cat "$FIVE_BACKUP_DIR/key")
# 1.0.1: no key message unless FIVE_BACKUP_KEY_TELEGRAM=1; the code stays on the box for the app.
ck "the key is on the box, 0600, and no Telegram message by default" '[[ -n "$CODE" && $(stat -c %a "$FIVE_BACKUP_DIR/key") == 600 && ! -s "$W/tg" ]]'
( cmd_backup run ) >"$W/o2" 2>&1; r2=$?
ck "nightly run rc 0, status ok with a snapshot id" '[[ $r2 == 0 ]] && jq -e ".ok == true and (.snapshot|length) > 0" "$FIVE_BACKUP_STATE/status.json" >/dev/null'
SNAPS=$(RESTIC_PASSWORD_FILE="$FIVE_BACKUP_DIR/key" "$REAL" -r "$DEST" snapshots --json 2>/dev/null | jq length)
ck "the owner's path holds exactly one real snapshot" '[[ "$SNAPS" == 1 ]]'
ck "the plaintext memory is not in the repository (encrypted)" '! grep -rq "blue door" "$DEST"'
ck "the key is not in the repository" '! grep -rqF "$CODE" "$DEST"'
ck "box 1: ZERO requests to the 5dive API" '[[ ! -s "$W/curl.log" ]]'

# ---- box 2: empty, fresh key dir; restore --to with only the owner's code
box 2; export FIVE_BACKUP_ROOT="$SB2" FIVE_CONNECTORD_ENV="$SB2/etc/5dive/connectord.env" FIVE_BACKUP_USERS="$SB2/var/lib/5dive/backup-users.tsv"
( cmd_backup restore --code="$(_bk_code_pretty "$CODE")" --to="$DEST" --yes ) >"$W/o3" 2>&1; r3=$?
ck "restore --to rc 0 onto the empty box" '[[ $r3 == 0 ]]'
ck "the agent's memory is back" 'grep -qx "remembers: the blue door" "$SB2/home/agent-ava/MEMORY.md"'
ck "its chat is back" 'grep -qx "chat: hello ava" "$SB2/home/agent-ava/chat.jsonl"'
ck "its bot connector is back" '[[ -f "$SB2/etc/5dive/connectors/telegram-ava.env" ]]'
ck "node_modules was never backed up" '[[ ! -e "$SB2/home/agent-ava/node_modules/x/big.js" ]]'
ck "the new box keeps its own identity" 'grep -qx "CONNECTORD_TOKEN=NEW_BOX" "$SB2/etc/5dive/connectord.env"'
ck "box 2 now holds the owner's code as its key" '[[ "$(cat "$FIVE_BACKUP_DIR/key")" == "$CODE" ]]'
ck "box 2: ZERO requests to the 5dive API (whole run)" '[[ ! -s "$W/curl.log" ]]'
echo "--- restic calls made (real binary):"; cut -c1-110 "$W/restic.argv"
echo "--- restore said:"; cat "$W/o3"
echo "passed=$PASS failed=$FAIL"
[[ $FAIL == 0 ]]
