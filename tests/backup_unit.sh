#!/usr/bin/env bash
# The arms are strings eval'd by check(), so variables they read look unused to
# ShellCheck; the plugin is sourced by a variable path on purpose.
# shellcheck disable=SC2034,SC2154,SC2155,SC1090
# DIVE-7873 unit harness: `5dive backup enable|run|restore|code|setup|uninstall`,
# the backup plugin's own executable (backup/bin/backup).
#
# The load-bearing property is KEY CUSTODY: the recovery code is made on the box,
# reaches restic only through a 0600 password file, reaches the owner only through
# a Telegram DM from the box's own bot, and NEVER reaches the 5dive API (enrol and
# report bodies, curl argv) or restic's argv. Then: a box with an earlier backup
# in its place never starts a new key over it; a failed run is reported, not
# silent; the box token rides curl's stdin; a malformed enrol answer writes
# nothing; a restore refuses a wrong code and never brings back the old box's
# identity files.
#
# restic, curl, Telegram, systemctl and the user tools are stubs; every path is
# redirected into a temp dir. No root, no network. The restic stub is REPO-AWARE:
# each repository under the owner's prefix is a dir holding its keys, so init,
# the probe (10 absent / 0 opens / 12 wrong key), key add|list|remove and backup
# behave per repository the way restic 0.17.3 does, and the S3 listing the CLI
# reads is drawn from the same dirs. That is what lets the fresh-box sequence
# (old repo box-7, new box 42) run end to end here.
#
# Run: bash tests/backup_unit.sh   (from anywhere; it cds to the repo root)
set -uo pipefail

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
BIN=backup/bin/backup
TMP="$(mktemp -d /tmp/backup-unit.XXXXXX)"
echo "grading tree: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet HEAD -- backup tests 2>/dev/null || echo ' +uncommitted')"

# The plugin's executable, sourced for its functions (the entry trailer runs
# nothing when sourced).
# shellcheck source=/dev/null
source "$BIN"
set +e

PASSED=0; FAILED=0
pass() { PASSED=$((PASSED+1)); printf 'ok   — %s\n' "$1"; }
bad()  { FAILED=$((FAILED+1)); printf 'FAIL — %s\n' "$1"; }
check() { if eval "$2"; then pass "$1"; else bad "$1"; fi; }
# grep -q in a pipe exits at the first match, the writer can die of SIGPIPE, and
# under pipefail the arm flakes red: gq reads the whole stream.
gq() { grep "$@" >/dev/null; }

# The agent unit's drop-in dir, built so no literal name-at-host string sits here.
export UNIT_D="5dive-agent$(printf '\x40')ava.service.d" UNIT_S="5dive-agent$(printf '\x40')ava.service"

reset() {
  rm -rf "$TMP/w" "$TMP/repos"; mkdir -p "$TMP/repos"; mkdir -p "$TMP/w/bin" "$TMP/w/etc" "$TMP/w/state" "$TMP/w/root"
  export FIVE_BACKUP_DIR="$TMP/w/etc/backup" FIVE_BACKUP_STATE="$TMP/w/state/backup"
  export FIVE_BACKUP_CRON="$TMP/w/etc/cron.d/5dive-backup" FIVE_BACKUP_LOG="$TMP/w/backup.log"
  export FIVE_BACKUP_RESTIC="$TMP/w/bin/restic" FIVE_BACKUP_USERS="$TMP/w/state/backup-users.tsv"
  export FIVE_BACKUP_ROOT="$TMP/w/root" FIVE_BACKUP_STAGE="$TMP/w/stage"
  export FIVE_CONNECTORD_ENV="$TMP/w/etc/connectord.env" FIVE_API_BASE_FILE="$TMP/none" FIVE_API_BASE="https://api.test"
  printf 'CONNECTORD_TOKEN=boxtok_SECRET123\n' >"$FIVE_CONNECTORD_ENV"
  REGISTRY="$TMP/w/state/agents.json"; printf '{"agents":{"ava":{}}}' >"$REGISTRY"
  : >"$TMP/curl.argv"; : >"$TMP/curl.stdin"; : >"$TMP/curl.body"; : >"$TMP/restic.argv"; : >"$TMP/tg"; : >"$TMP/restic.pw"; : >"$TMP/restic.sess"; : >"$TMP/sys"
  export RESTIC_PROBE_RC="" RESTIC_BACKUP_RC=0 RESTIC_SILENT="" LIST_FAIL="" T="$TMP"
  export FIVE_BACKUP_KEY_TELEGRAM=1   # the DM arms below drive the (now opt-in) Telegram path
  # restic stub: logs the repository + argv and the password it was given, then
  # acts on $T/repos/<repo>/keys (one password per line).
  cat >"$FIVE_BACKUP_RESTIC" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${RESTIC_REPOSITORY:-}" "$*" >>"$T/restic.argv"; printf '%s\n' "${AWS_SESSION_TOKEN:-}" >>"$T/restic.sess"
[[ -n "${RESTIC_PASSWORD_FILE:-}" ]] && printf 'pw=%s mode=%s\n' "$(cat "$RESTIC_PASSWORD_FILE")" "$(stat -c %a "$RESTIC_PASSWORD_FILE")" >>"$T/restic.pw"
R="$T/repos/${RESTIC_REPOSITORY##*/}"; pw=$(cat "$RESTIC_PASSWORD_FILE" 2>/dev/null)
opens() { [[ -f "$R/keys" ]] && grep -qxF -- "$pw" "$R/keys"; }
kid() { printf '%s' "$1" | sha256sum | cut -c1-64; }
argafter() { local p="" a; for a in "${@:2}"; do [[ "$p" == "$1" ]] && { printf '%s' "$a"; return; }; p="$a"; done; }
case " $* " in
  *" version "*) echo "restic 0.17.3 compiled with go1.23.3 on linux/amd64"; exit 0 ;;
  *" cat config"*) [[ -n "${RESTIC_PROBE_RC:-}" ]] && exit "$RESTIC_PROBE_RC"
     [[ -d "$R" ]] || exit 10; opens && exit 0; exit 12 ;;
  *" init"*) [[ -d "$R" ]] && { echo "Fatal: config file already exists" >&2; exit 1; }
     mkdir -p "$R"; printf '%s\n' "$pw" >"$R/keys"; exit 0 ;;
  *" key add "*) opens || exit 12; printf '%s\n' "$(cat "$(argafter --new-password-file "$@")")" >>"$R/keys"; exit 0 ;;
  *" key list "*) opens || exit 12
     while IFS= read -r k; do jq -cn --arg id "$(kid "$k")" --argjson c "$([[ "$k" == "$pw" ]] && echo true || echo false)" '{current:$c, id:$id}'; done <"$R/keys" | jq -cs . ; exit 0 ;;
  *" key remove "*) opens || exit 12; id="${@: -1}"; [[ "$id" == "$(kid "$pw")" ]] && exit 1
     while IFS= read -r k; do [[ "$(kid "$k")" == "$id" ]] || printf '%s\n' "$k"; done <"$R/keys" >"$R/keys.n"; mv "$R/keys.n" "$R/keys"; exit 0 ;;
  *" backup "*) opens || { echo "Fatal: wrong password or no key found" >&2; exit 12; }
     [[ "$RESTIC_BACKUP_RC" == 0 ]] && { echo x >>"$R/snapshots"; echo '{"message_type":"summary","snapshot_id":"abc123","data_added":4096}'; exit 0; }
     [[ -n "${RESTIC_SILENT:-}" ]] || echo "Fatal: unable to open repo" >&2; exit "$RESTIC_BACKUP_RC" ;;
  *" forget "*) exit 0 ;;
  *" restore "*) opens || exit 12; t=$(argafter --target "$@")
     mkdir -p "$t/home/agent-ava" "$t/var/lib/5dive" "$t/etc/5dive/connectors" "$t/etc/systemd/system/$UNIT_D"
     echo "remembers: the blue door" >"$t/home/agent-ava/MEMORY.md"
     printf '{"agents":{"ava":{}}}' >"$t/var/lib/5dive/agents.json"
     printf 'agent-ava\t%s\t%s\tagent-ava\t/home/agent-ava\t/bin/bash\tagent-ava,claude\n' "${STAGE_UID:-1007}" "${STAGE_GID:-1007}" >"$t/var/lib/5dive/backup-users.tsv"
     # A different LENGTH from the new box's token, so rsync's size+mtime check
     # can never skip it by coincidence: the IDENTITY arm is deterministic.
     echo "CONNECTORD_TOKEN=OLD_BOX_IDENTITY_FROM_THE_BACKUP" >"$t/etc/5dive/connectord.env"
     echo "TELEGRAM_BOT_TOKEN=bot" >"$t/etc/5dive/connectors/telegram-ava.env"
     echo "[Service]" >"$t/etc/systemd/system/$UNIT_D/x.conf" ;;
esac
exit 0
EOF
  chmod +x "$FIVE_BACKUP_RESTIC"
  ENROLL_BODY='{"endpoint":"https://acct.eu.r2.cloudflarestorage.com","bucket":"5dive-box-backups","prefix":"o-0123456789abcdef01234567/","accessKeyId":"AKID1","secretAccessKey":"deadbeef","sessionToken":"sess.TOKEN_1","region":"auto","serverId":42}'
  ENROLL_HTTP=200
}
# curl stub: argv, stdin (the auth header) and the body. Writes the answer to -o.
curl() {
  printf '%s\n' "$*" >>"$TMP/curl.argv"
  local o="" d="" prev="" a url=""
  for a in "$@"; do
    [[ "$prev" == -o ]] && o="$a"; [[ "$prev" == --data ]] && d="$a"; prev="$a"; url="$a"
  done
  cat >>"$TMP/curl.stdin"; printf '%s\n' "$d" >>"$TMP/curl.body"
  case "$url" in
    *list-type=2*) [[ -n "$LIST_FAIL" ]] && return 22
       local r; printf '<ListBucketResult><Prefix>o-0123456789abcdef01234567/</Prefix>'
       for r in "$TMP"/repos/box-*; do [[ -d "$r" ]] && printf '<CommonPrefixes><Prefix>o-0123456789abcdef01234567/%s/</Prefix></CommonPrefixes>' "${r##*/}"; done
       printf '</ListBucketResult>' ;;
    */enroll) printf '%s' "$ENROLL_BODY" >"$o"; printf '%s' "$ENROLL_HTTP" ;;
    */report) printf '{"ok":true}' >"$o"; printf 200 ;;
  esac
}
require_root() { :; }
_bk_restic_install() { :; }
_bk_agent_bot() { [[ "$1" == ava ]] || return 1; printf '123:bot'; }
_bk_agent_dms() { [[ "$1" == ava ]] && printf '%s\n' -1009876543210 1234567890; }   # a group, then the owner
_bk_send() { printf 'chat=%s text=%s\n' "$2" "$4" >>"$TMP/tg"; echo '{"ok":true}'; }
systemctl() { printf 'systemctl %s\n' "$*" >>"$TMP/sys"; }
getent() { case "$1" in passwd|group) [[ "${2:-}" == claude ]] && return 0; return 2 ;; esac; }
useradd() { printf 'useradd %s\n' "$*" >>"$TMP/sys"; }
groupadd() { printf 'groupadd %s\n' "$*" >>"$TMP/sys"; }
usermod() { printf 'usermod %s\n' "$*" >>"$TMP/sys"; }
run() { ( cmd_backup "$@" ) >"$TMP/out" 2>&1; echo $? >"$TMP/rc"; }
rc() { cat "$TMP/rc"; }
code_on_box() { cat "$FIVE_BACKUP_DIR/key" 2>/dev/null; }
seed() { mkdir -p "$TMP/repos/$1"; printf '%s\n' "$2" >"$TMP/repos/$1/keys"; }   # <repo> <key that opens it>
opens_repo() { grep -qxF -- "$2" "$TMP/repos/$1/keys" 2>/dev/null; }

# --- the recovery code ---------------------------------------------------------
c=$(_bk_code_new)
check "a new code is 28 symbols of the no-0/O/1/I alphabet" '[[ ${#c} -eq 28 && "$c" =~ ^[A-HJ-NP-Z2-9]+$ ]]'
check "two codes differ" '[[ "$c" != "$(_bk_code_new)" ]]'
p=$(_bk_code_pretty "$c")
check "the pretty code normalises back, lowercase and dashed" '[[ "$(_bk_code_normalize "${p,,}")" == "$c" ]]'
check "a short code refuses" '! _bk_code_normalize "ABCD-EFGH" >/dev/null'
check "a code with O/0/1/I refuses" '! _bk_code_normalize "O0I1ABCDEFGHJKLMNPQRSTUVWXYZ" >/dev/null'

# --- enable on a fresh box ------------------------------------------------------
reset; run enable
K=$(code_on_box)
check "enable: rc 0" '[[ $(rc) == 0 ]]'
check "enable: the key file is 0600 and holds a valid code" '[[ $(stat -c %a "$FIVE_BACKUP_DIR/key") == 600 && -n "$(_bk_code_normalize "$K")" ]]'
check "enable: r2.env is 0600 and names repo box-42" '[[ $(stat -c %a "$FIVE_BACKUP_DIR/r2.env") == 600 ]] && grep -q "^BACKUP_REPO=box-42$" "$FIVE_BACKUP_DIR/r2.env"'
check "enable: the repository is box-42 under this owner's prefix" 'grep -q "^s3:https://acct.eu.r2.cloudflarestorage.com/5dive-box-backups/o-0123456789abcdef01234567/box-42 .* init" "$TMP/restic.argv"'
check "enable: restic got the temporary credential's session token" 'grep -qx "sess.TOKEN_1" "$TMP/restic.sess"'
check "enable: restic got the key via a 0600 password file" 'grep -q "^pw=$K mode=600$" "$TMP/restic.pw"'
check "enable: cron scheduled nightly as root" 'grep -qE "^[0-9]+ [2-4] \* \* \* root /usr/local/bin/5dive backup run" "$FIVE_BACKUP_CRON"'
check "enable: the owner got the code in a DM, with the no-recovery warning" 'grep -q "chat=1234567890" "$TMP/tg" && grep -q "$(_bk_code_pretty "$K")" "$TMP/tg" && grep -q "nobody can restore" "$TMP/tg"'
check "enable: a GROUP the bot is paired with never gets the code (DMs only)" '! grep -q "chat=-" "$TMP/tg"'
check "CUSTODY: the code is in no API body, header or argv" '! grep -q "$K" "$TMP/curl.argv" "$TMP/curl.body" "$TMP/curl.stdin" && ! grep -q "$(_bk_code_pretty "$K")" "$TMP/curl.argv" "$TMP/curl.body"'
check "CUSTODY: the code is never on restic's argv" '! grep -q "$K" "$TMP/restic.argv"'
check "the box token rides curl's stdin, never argv" 'grep -q "boxtok_SECRET123" "$TMP/curl.stdin" && ! grep -q "boxtok_SECRET123" "$TMP/curl.argv"'
check "the code is delivered once: a second enable sends nothing new" '( cmd_backup enable ) >/dev/null 2>&1; [[ $(grep -c "chat=" "$TMP/tg") == 1 ]]'

# --- enable on a box whose place already holds a backup -------------------------
reset; seed box-42 OTHERKEYOTHERKEYOTHERKEY2345; run enable
check "earlier backup: no key is made over it" '[[ ! -e "$FIVE_BACKUP_DIR/key" ]] && ! grep -q " init" "$TMP/restic.argv"'
check "earlier backup: state restore-available, no cron, no DM" '[[ "$(cat "$FIVE_BACKUP_STATE/state")" == restore-available && ! -e "$FIVE_BACKUP_CRON" && ! -s "$TMP/tg" ]]'
check "earlier backup: the nightly run reports it, and still makes no key" '( cmd_backup run ) >/dev/null 2>&1; grep -q "waiting for the owner" "$TMP/curl.body" && [[ ! -e "$FIVE_BACKUP_DIR/key" ]]'

# --- FIX (1): a fresh box of an owner whose backup is an EARLIER box's ----------
# The fresh box gets a new server id (42), so its own place is empty; the owner's
# real backup is box-7. No new key, no init, no second code in the owner's DMs.
reset; seed box-7 ABCDEFGHJKLMNPQRSTUVWXYZ2345; run enable
check "FRESH BOX (1): another box's backup under the owner's prefix: no key, no init" '[[ $(rc) == 0 && ! -e "$FIVE_BACKUP_DIR/key" && ! -d "$TMP/repos/box-42" ]] && ! grep -q " init" "$TMP/restic.argv"'
check "FRESH BOX (1): state restore-available, no cron, no DM, and it names box-7" '[[ "$(cat "$FIVE_BACKUP_STATE/state")" == restore-available && ! -e "$FIVE_BACKUP_CRON" && ! -s "$TMP/tg" ]] && grep -q -- "--from=box-7" "$TMP/out"'
reset; LIST_FAIL=1; run enable
check "FRESH BOX (1): a listing that fails makes no key (unknown is not empty)" '[[ $(rc) != 0 && ! -e "$FIVE_BACKUP_DIR/key" && ! -s "$TMP/tg" ]] && ! grep -q " init" "$TMP/restic.argv"'
reset; seed box-7 ABCDEFGHJKLMNPQRSTUVWXYZ2345; run enable --new-key
check "--new-key: the owner may start over beside a lost backup (box-7 untouched)" '[[ $(rc) == 0 && -s "$FIVE_BACKUP_DIR/key" ]] && opens_repo box-42 "$(code_on_box)" && opens_repo box-7 ABCDEFGHJKLMNPQRSTUVWXYZ2345'
reset; seed box-7 ABCDEFGHJKLMNPQRSTUVWXYZ2345; run enable --auto --new-key
check "--new-key is never unattended: --auto with it refuses and makes no key" '[[ $(rc) != 0 && ! -e "$FIVE_BACKUP_DIR/key" ]]'

# --- the nightly run enables a never-set-up box ----------------------------------
reset; run run
check "rollout: the first nightly run sets the box up and backs up" '[[ $(rc) == 0 && -s "$FIVE_BACKUP_DIR/key" ]] && grep -q " backup " "$TMP/restic.argv" && grep -q "chat=1234567890" "$TMP/tg"'
reset; rm -f "$FIVE_CONNECTORD_ENV"; run run
check "rollout: a box with no 5dive identity is left alone" '[[ $(rc) == 0 && ! -e "$FIVE_BACKUP_DIR/key" && ! -s "$TMP/curl.argv" ]]'

# --- enrol refusals -------------------------------------------------------------
reset; ENROLL_BODY='{"endpoint":"https://acct.r2.cloudflarestorage.com","bucket":"../other-box","accessKeyId":"A","secretAccessKey":"b","serverId":42}'; run enable
check "a malformed enrol answer writes no storage settings and no key" '[[ $(rc) != 0 && ! -e "$FIVE_BACKUP_DIR/r2.env" && ! -e "$FIVE_BACKUP_DIR/key" ]]'
for bad in '"prefix":"../o-x/"' '"prefix":""' '"sessionToken":"a$(id)"' '"sessionToken":"a b"'; do
  reset; ENROLL_BODY=$(jq -c ". + {${bad}}" <<<"$ENROLL_BODY"); run enable
  check "a malformed enrol answer ($bad) writes nothing" '[[ $(rc) != 0 && ! -e "$FIVE_BACKUP_DIR/r2.env" && ! -e "$FIVE_BACKUP_DIR/key" ]]'
done
reset; ENROLL_HTTP=503; ENROLL_BODY='{"code":"backup_not_configured"}'; run enable --auto
check "--auto: an unready API never fails the caller, and says why" '[[ $(rc) == 0 ]] && grep -q "backup_not_configured" "$FIVE_BACKUP_LOG"'

# --- run -------------------------------------------------------------------------
reset; ( cmd_backup enable ) >/dev/null 2>&1; K=$(code_on_box); : >"$TMP/curl.body"; : >"$TMP/curl.argv"; run run
check "run: re-enrols first (the credential lives 36 h)" '[[ $(grep -c "/enroll" "$TMP/curl.argv") -ge 1 ]]'
check "run: ok, snapshot recorded in status.json" '[[ $(rc) == 0 ]] && jq -e ".ok == true and .snapshot == \"abc123\"" "$FIVE_BACKUP_STATE/status.json" >/dev/null'
check "run: reported ok to the API with the snapshot" 'grep -q "\"ok\":true" "$TMP/curl.body" && grep -q abc123 "$TMP/curl.body"'
check "run: caches and the key dir are excluded" 'grep -q -- "--exclude node_modules" "$TMP/restic.argv" && grep -q -- "--exclude /etc/5dive/backup" "$TMP/restic.argv"'
check "run: old snapshots are pruned" 'grep -q "forget --keep-daily 7" "$TMP/restic.argv"'
export RESTIC_BACKUP_RC=1; : >"$TMP/curl.body"; run run
check "FAILED run: non-zero exit" '[[ $(rc) != 0 ]]'
check "FAILED run: status.json says so and keeps the last good time" 'jq -e ".ok == false and (.error|test(\"rc 1\")) and .lastOkAt != null" "$FIVE_BACKUP_STATE/status.json" >/dev/null'
check "FAILED run: reported to the API as not ok" 'grep -q "\"ok\":false" "$TMP/curl.body"'
check "FAILED run: status says FAILED" '( cmd_backup status ) 2>&1 | gq "FAILED"'
check "FAILED run (4): the error is restic's own stderr of this run" 'jq -e ".error|test(\"Fatal: unable to open repo\")" "$FIVE_BACKUP_STATE/status.json" >/dev/null'
export RESTIC_BACKUP_RC=0; ( cmd_backup run ) >/dev/null 2>&1; export RESTIC_BACKUP_RC=1 RESTIC_SILENT=1; run run
check "FAILED run (4): a silent restic never borrows an older log line" 'jq -e "(.error|test(\"run ok=\")|not) and (.error|test(\"printed no error\"))" "$FIVE_BACKUP_STATE/status.json" >/dev/null'
export RESTIC_SILENT="" RESTIC_BACKUP_RC=0
check "CUSTODY: no report body carries the code" '! grep -q "$K" "$TMP/curl.body"'

# --- restore ----------------------------------------------------------------------
GOOD=ABCDEFGHJKLMNPQRSTUVWXYZ2345
reset; seed box-42 "$GOOD"
mkdir -p "$FIVE_BACKUP_ROOT/etc/5dive"; echo "CONNECTORD_TOKEN=NEW_BOX" >"$FIVE_BACKUP_ROOT/etc/5dive/connectord.env"
run restore --code=ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ --yes
check "restore: a wrong code refuses before touching anything" '[[ $(rc) == 6 && ! -e "$FIVE_BACKUP_ROOT/home" ]]'
run restore --code=abcd-efgh-jklm-npqr-stuv-wxyz-2345 --from=../x --yes
check "restore: --from takes only box-N" '[[ $(rc) == 3 ]]'
run restore --code=abcd-efgh-jklm-npqr-stuv-wxyz-2345
check "restore without --yes only checks the key" '[[ $(rc) == 0 && ! -e "$FIVE_BACKUP_ROOT/home" ]] && grep -q "opens box-42" "$TMP/out"'

# The fresh-box sequence, end to end: old repo box-7 under the owner's prefix,
# a fresh box 42 that has never been set up.
reset; seed box-7 "$GOOD"
mkdir -p "$FIVE_BACKUP_ROOT/etc/5dive"; echo "CONNECTORD_TOKEN=NEW_BOX" >"$FIVE_BACKUP_ROOT/etc/5dive/connectord.env"
run run   # step 1: the first nightly run on the fresh box
check "SEQUENCE step 1: the nightly run on the fresh box makes no key, no repo, no DM" '[[ ! -e "$FIVE_BACKUP_DIR/key" && ! -d "$TMP/repos/box-42" && ! -s "$TMP/tg" ]] && grep -q "waiting for the owner" "$TMP/curl.body"'
: >"$TMP/restic.argv"; run restore --code=abcd-efgh-jklm-npqr-stuv-wxyz-2345 --from=box-7 --yes   # step 2
check "restore: rc 0" '[[ $(rc) == 0 ]] || { cat "$TMP/out"; false; }'
check "restore: read from the named box's repository, under the owner's prefix" 'grep -q "^s3:https://acct.eu.r2.cloudflarestorage.com/5dive-box-backups/o-0123456789abcdef01234567/box-7 .*restore latest" "$TMP/restic.argv"'
check "restore: the agent's memory is back" 'grep -q "blue door" "$FIVE_BACKUP_ROOT/home/agent-ava/MEMORY.md"'
check "restore: its bot connector and unit drop-in are back" '[[ -f "$FIVE_BACKUP_ROOT/etc/5dive/connectors/telegram-ava.env" && -f "$FIVE_BACKUP_ROOT/etc/systemd/system/$UNIT_D/x.conf" ]]'
check "IDENTITY: the old box's token never overwrites the new box's" 'grep -qx "CONNECTORD_TOKEN=NEW_BOX" "$FIVE_BACKUP_ROOT/etc/5dive/connectord.env"'
check "restore: the agent user is recreated with its uid, and its groups" 'grep -q "useradd -M -u 1007 .* agent-ava" "$TMP/sys" && grep -q "usermod -aG claude agent-ava" "$TMP/sys"'
check "restore: the agent is restarted" 'grep -q "restart $UNIT_S" "$TMP/sys"'
check "SEQUENCE step 2: this box's own repository box-42 is created with the owner's code" 'opens_repo box-42 "$GOOD" && [[ "$(code_on_box)" == "$GOOD" && -f "$FIVE_BACKUP_CRON" ]] && grep -q "continue as box-42" "$TMP/out"'
check "CUSTODY: the restore code reached no API call" '! grep -q "$GOOD" "$TMP/curl.argv" "$TMP/curl.body" "$TMP/curl.stdin"'
: >"$TMP/tg"; run run   # step 3
check "SEQUENCE step 3: the next nightly backup succeeds into box-42" '[[ $(rc) == 0 && -s "$TMP/repos/box-42/snapshots" ]] && jq -e ".ok == true" "$FIVE_BACKUP_STATE/status.json" >/dev/null'
check "SEQUENCE: no second recovery code was ever DMed" '! [[ -s "$TMP/tg" ]]'

# FIX (2): this box's own repository already exists under ANOTHER key (one this
# box made before the restore). Re-key it with the box's old key: the owner's
# code opens it, the old key no longer does.
reset; seed box-7 "$GOOD"; seed box-42 OLDBOXKEYOLDBOXKEYOLDBOXKEY2
mkdir -p "$FIVE_BACKUP_DIR"; printf OLDBOXKEYOLDBOXKEYOLDBOXKEY2 >"$FIVE_BACKUP_DIR/key"
run restore --code="$GOOD" --from=box-7 --yes
check "RE-KEY (2): box-42 now opens with the owner's code and not the old box key" '[[ $(rc) == 0 ]] && opens_repo box-42 "$GOOD" && ! opens_repo box-42 OLDBOXKEYOLDBOXKEYOLDBOXKEY2 && grep -q "continue as box-42" "$TMP/out"'
run run
check "RE-KEY (2): the next nightly backup succeeds" '[[ $(rc) == 0 && -s "$TMP/repos/box-42/snapshots" ]]'

# FIX (2), the residue: nothing on this box opens its own repository. The agents
# come back, and the box says backups are NOT running, everywhere it can.
reset; seed box-7 "$GOOD"; seed box-42 STRANGERKEYSTRANGERKEYSTRAN
run restore --code="$GOOD" --from=box-7 --yes
check "MISMATCH (2): the restore still brings the agents back" '[[ $(rc) == 0 ]] && grep -q "blue door" "$FIVE_BACKUP_ROOT/home/agent-ava/MEMORY.md"'
check "MISMATCH (2): it never claims backups continue" '! grep -q "continue as" "$TMP/out" && grep -q "NOT running" "$TMP/out"'
check "MISMATCH (2): status and the API both say backups failed" 'jq -e ".ok == false and (.error|test(\"different key\"))" "$FIVE_BACKUP_STATE/status.json" >/dev/null && grep -q "\"ok\":false" "$TMP/curl.body"'
check "MISMATCH (2): the stranger's repository is left as it was" 'opens_repo box-42 STRANGERKEYSTRANGERKEYSTRAN && ! opens_repo box-42 "$GOOD"'

# --- the plugin's host half: setup / uninstall ------------------------------------
reset; run setup
check "SETUP: rc 0 and the nightly run is scheduled as root at 03:mm" '[[ $(rc) == 0 ]] && grep -qE "^[0-9]+ 3 \* \* \* root /usr/local/bin/5dive backup run" "$FIVE_BACKUP_CRON"'
check "SETUP: makes no key, calls no API, sends no DM" '[[ ! -e "$FIVE_BACKUP_DIR/key" && ! -s "$TMP/curl.argv" && ! -s "$TMP/tg" ]]'
check "SETUP: the cron file is 0644 (cron ignores a group/world-writable one)" '[[ $(stat -c %a "$FIVE_BACKUP_CRON") == 644 ]]'
reset; ( cmd_backup enable ) >/dev/null 2>&1; before=$(cat "$FIVE_BACKUP_CRON"); run setup
check "SETUP is idempotent: a box's per-box schedule from enable is kept byte for byte" '[[ $(rc) == 0 && "$(cat "$FIVE_BACKUP_CRON")" == "$before" ]]'
reset; ( _bk_restic_install() { return 1; }; cmd_backup setup ) >"$TMP/out" 2>&1; echo $? >"$TMP/rc"
check "SETUP: restic unavailable -> rc 7, and the schedule is still in place for the nightly retry" '[[ $(rc) == 7 && -f "$FIVE_BACKUP_CRON" ]]'
reset; ( cmd_backup enable ) >/dev/null 2>&1; K=$(code_on_box); run uninstall
check "UNINSTALL: the schedule is gone, the key is kept, state is off" '[[ $(rc) == 0 && ! -e "$FIVE_BACKUP_CRON" && "$(code_on_box)" == "$K" && "$(cat "$FIVE_BACKUP_STATE/state")" == off ]]'

# --- owner delivery through core's CLI (the plugin divergence) ---------------------
reset; : >"$TMP/curl.argv"
( source "$BIN"; _bk_send 123:SECRET_BOT_TOKEN 555 "" "the code ABCD-SECRETCODE" ) >/dev/null 2>&1
check "SEND: the bot token and the text are never on curl's argv" '[[ -s "$TMP/curl.argv" ]] && ! grep -q "SECRET_BOT_TOKEN" "$TMP/curl.argv" && ! grep -q "SECRETCODE" "$TMP/curl.argv" && grep -q -- "-K " "$TMP/curl.argv"'
: >"$TMP/curl.argv"
( source "$BIN"; FIVEDIVE_NOTIFY_DRYRUN=1 _bk_send 123:tok 555 "" "x" ) >"$TMP/out" 2>&1
check "SEND: core's FIVEDIVE_NOTIFY_DRYRUN reaches nobody" '[[ ! -s "$TMP/curl.argv" ]] && grep -q dry_run "$TMP/out"'
mkdir -p "$TMP/w/conn"; printf 'TELEGRAM_BOT_TOKEN="123456:AAbb_cc-DD"\n' >"$TMP/w/conn/telegram-ava.env"; printf 'TELEGRAM_BOT_TOKEN=$(id)\n' >"$TMP/w/conn/telegram-eve.env"
check "BOT: the token is read from core's connector file" '[[ "$( source "$BIN"; CONNECTORS_DIR="$TMP/w/conn"; _bk_agent_bot ava )" == "123456:AAbb_cc-DD" ]]'
check "BOT: a malformed token, or no file, is no channel" '( source "$BIN"; CONNECTORS_DIR="$TMP/w/conn"; ! _bk_agent_bot eve && ! _bk_agent_bot nobody )'
printf '#!/usr/bin/env bash\n[[ "$*" == "agent telegram-access get ava --json" ]] && echo %s\n' "'{\"ok\":true,\"data\":{\"access\":{\"allowFrom\":[\"1234567890\",-1005]}}}'" >"$TMP/w/fake5dive"; chmod +x "$TMP/w/fake5dive"
check "DMS: the owner comes from core's telegram-access verb (one person paired, a group skipped)" '[[ "$( source "$BIN"; BACKUP_5DIVE_BIN="$TMP/w/fake5dive"; _bk_agent_dms ava | paste -sd, )" == "1234567890" ]]'

# --- it5 (DIVE-7893's finding): the key goes to the OWNER, never to a guest ----------
# fake5dive_access <access json>: core's telegram-access get answers with it for ava.
fake5dive_access() {
  printf '#!/usr/bin/env bash\n[[ "$*" == "agent telegram-access get ava --json" ]] && cat <<'"'"'J'"'"'\n{"ok":true,"data":{"access":%s}}\nJ\n' "$1" >"$TMP/w/fake5dive"
  chmod +x "$TMP/w/fake5dive"
}
dms() { ( source "$BIN"; BACKUP_5DIVE_BIN="$TMP/w/fake5dive"; _bk_agent_dms ava | paste -sd, ); }
fake5dive_access '{"allowFrom":["111","222"],"owners":["111"],"ownersSeed":2}'
check "OWNER ONLY: allowFrom = owner + guest, the owners record names the owner -> only the owner" '[[ "$(dms)" == "111" ]]'
fake5dive_access '{"allowFrom":["111","222"],"owners":["333","111"]}'
check "OWNER ONLY: an owner no longer in allowFrom is dropped (as the telegram plugin ownerChatIds does)" '[[ "$(dms)" == "111" ]]'
fake5dive_access '{"allowFrom":["111","222"],"owners":[]}'
check "OWNER ONLY: an empty owners record (owner not paired yet) -> nobody, never the guests" '[[ -z "$(dms)" ]]'
fake5dive_access '{"allowFrom":["111","222"]}'
check "OWNER ONLY: no owners record and two people paired -> nobody (no guessing who owns it)" '[[ -z "$(dms)" ]]'
fake5dive_access '{"allowFrom":["111",-1005]}'
check "OWNER ONLY: no owners record and ONE person paired -> that person (a group is not a person)" '[[ "$(dms)" == "111" ]]'
# Through the whole delivery: real _bk_agent_dms, the harness's bot and send stubs.
fake5dive_access '{"allowFrom":["111","222"],"owners":["111"]}'
: >"$TMP/tg"
( source "$BIN"; BACKUP_5DIVE_BIN="$TMP/w/fake5dive"; REGISTRY="$TMP/w/reg.json"; printf '{"agents":{"ava":{"type":"claude"}}}' >"$REGISTRY"
  _bk_agent_bot() { printf '123:bot'; }; _bk_send() { printf 'chat=%s text=%s\n' "$2" "$4" >>"$TMP/tg"; echo '{"ok":true}'; }
  _bk_owner_dm ABCDEFGHJKLMNPQRSTUVWXYZ2345 ) >/dev/null 2>&1; echo $? >"$TMP/rc"
check "OWNER ONLY, delivered: the owner gets the key, the guest on the same bot does not" '[[ $(rc) == 0 ]] && gq "^chat=111 " "$TMP/tg" && ! gq "^chat=222 " "$TMP/tg"'
fake5dive_access '{"allowFrom":["111","222"]}'
: >"$TMP/tg"
( source "$BIN"; BACKUP_5DIVE_BIN="$TMP/w/fake5dive"; REGISTRY="$TMP/w/reg.json"
  _bk_agent_bot() { printf '123:bot'; }; _bk_send() { printf 'chat=%s\n' "$2" >>"$TMP/tg"; echo '{"ok":true}'; }
  _bk_owner_dm ABCDEFGHJKLMNPQRSTUVWXYZ2345 ) >/dev/null 2>&1; echo $? >"$TMP/rc"
check "OWNER ONLY, delivered: no owner known -> nothing sent, rc 1 (retried next night)" '[[ $(rc) == 1 && ! -s "$TMP/tg" ]]'

# --- it5 (DIVE-7893, lodar 16:30:39Z): a partner's client reads its own text ----------
# The approved texts, from the pinned gate quote: ru = lines 2-6, en = lines 9-13.
H="$TMP/w/home"; mkdir -p "$H"
cat >"$TMP/w/q.ru" <<'Q'
Ключ резервных копий вашего сервера: XXXX-XXXX-…

Сохраните его в надёжном месте вне этого чата, например в менеджере паролей. Каждую ночь копия ваших сотрудников шифруется этим ключом и сохраняется в отдельном хранилище.

Ключ есть только у вас. Без него копии не откроет никто, в том числе OINOA. Если пропадут и сервер, и ключ, восстановить сотрудников не сможет никто.
Q
cat >"$TMP/w/q.en" <<'Q'
Your server's backup key: XXXX-XXXX-…

Save it somewhere safe outside this chat (a password manager). Every night a copy of your employees is encrypted with this key and kept in separate storage.

Only you hold this key. Nobody can open your backups without it, OINOA included. If you lose both the server and this key, nobody can restore them.
Q
cat >"$TMP/w/q.5dive" <<'Q'
Your server's backup key: XXXX-XXXX-…

Save it somewhere safe outside this chat (a password manager). Every night your agents are copied, encrypted with this key, to a second provider.

Only you hold this key. 5dive cannot open your backups. If you lose both the server and this key, nobody can restore them, us included.
Q
cp "$TMP"/w/q.* "$TMP/"   # kept for the APP arms: reset clears $TMP/w
msg() { ( source "$BIN"; _bk_code_pretty() { printf 'XXXX-XXXX-…'; }; _bk_code_message K "$1" ); }
check "TEXT: ru is the approved text, word for word" '[[ "$(msg ru)" == "$(cat "$TMP/w/q.ru")" ]]'
check "TEXT: en is the approved text, word for word" '[[ "$(msg en)" == "$(cat "$TMP/w/q.en")" ]]'
check "TEXT: 5dive is the 16:03Z text, unchanged" '[[ "$(msg 5dive)" == "$(cat "$TMP/w/q.5dive")" ]]'
check "TEXT: no variant is the 5dive text" '[[ "$(msg "")" == "$(cat "$TMP/w/q.5dive")" ]]'
check "TEXT: neither partner text names the platform or the provider" '! msg ru | gq -iE "5dive|cloudflare|r2" && ! msg en | gq -iE "5dive|cloudflare|r2"'
# chan <type> <env line or ""> <lite-lang or "-">: one agent "ava" of <type>.
chan() {
  rm -rf "$H"; local d; case "$1" in antigravity) d="$H/agent-ava/.gemini/channels/telegram" ;; *) d="$H/agent-ava/.$1/channels/telegram" ;; esac
  mkdir -p "$d"; printf '{"agents":{"ava":{"type":"%s"}}}' "$1" >"$TMP/w/reg.json"
  [[ -n "$2" ]] && printf '%s\n' "$2" >"$d/.env"
  [[ "$3" != - ]] && printf '%s' "$3" >"$d/lite-lang"
  return 0
}
variant() { ( source "$BIN"; REGISTRY="$TMP/w/reg.json"; BACKUP_HOME_ROOT="$H"; _bk_code_variant ava ); }
PURL='TELEGRAM_ACCOUNT_URL=https://t.me/partner_bot/app'
chan claude "" -;                         check "PICK: a 5dive box (no partner app link) -> the 5dive text" '[[ "$(variant)" == 5dive ]]'
chan claude "" ru;                        check "PICK: a 5dive box whose owner writes in Russian still gets the approved 5dive text" '[[ "$(variant)" == 5dive ]]'
chan claude "TELEGRAM_ACCOUNT_URL=" ru;   check "PICK: an EMPTY partner line is not a partner" '[[ "$(variant)" == 5dive ]]'
chan claude "$PURL" -;                    check "PICK: partner, language unknown -> Russian" '[[ "$(variant)" == ru ]]'
chan claude "$PURL" "ru";                 check "PICK: partner, ru -> Russian" '[[ "$(variant)" == ru ]]'
chan claude "$PURL" "ru-RU";              check "PICK: partner, ru-RU -> Russian" '[[ "$(variant)" == ru ]]'
chan claude "$PURL" "en";                 check "PICK: partner, en -> English" '[[ "$(variant)" == en ]]'
chan claude "$PURL" "sr";                 check "PICK: partner, sr (known, not Russian) -> English" '[[ "$(variant)" == en ]]'
chan codex "$PURL" "en";                  check "PICK: a codex seat: its channel dir is read too" '[[ "$(variant)" == en ]]'
chan antigravity "$PURL" -;               check "PICK: an antigravity seat: its channel dir (.gemini) is read too" '[[ "$(variant)" == ru ]]'
# Through the whole delivery, on a partner box and on ours.
dm_text() { : >"$TMP/tg"; ( source "$BIN"; BACKUP_5DIVE_BIN="$TMP/w/fake5dive"; REGISTRY="$TMP/w/reg.json"; BACKUP_HOME_ROOT="$H"
  _bk_agent_bot() { printf '123:bot'; }; _bk_send() { printf '%s' "$4" >"$TMP/tg"; echo '{"ok":true}'; }
  _bk_owner_dm ABCDEFGHJKLMNPQRSTUVWXYZ2345 ) >/dev/null 2>&1; cat "$TMP/tg"; }
fake5dive_access '{"allowFrom":["111"],"owners":["111"]}'
KP=$( source "$BIN"; _bk_code_pretty ABCDEFGHJKLMNPQRSTUVWXYZ2345 )
chan claude "$PURL" -;   check "PARTNER, delivered: the owner reads the Russian text with the key" '[[ "$(dm_text)" == "$(sed "s/XXXX-XXXX-…/$KP/" "$TMP/w/q.ru")" ]]'
chan claude "$PURL" en;  check "PARTNER, delivered: an English-speaking owner reads the English text" '[[ "$(dm_text)" == "$(sed "s/XXXX-XXXX-…/$KP/" "$TMP/w/q.en")" ]]'
chan claude "" -;        check "5DIVE BOX, delivered: unchanged, the 5dive text with the key" '[[ "$(dm_text)" == "$(sed "s/XXXX-XXXX-…/$KP/" "$TMP/w/q.5dive")" ]]'
check "NO CORE INTERNALS: the plugin calls none of core's in-process functions" '! grep -nE "_mirror_send|_task_agent_channel|TASK_CH_|_disk_alarm_deliver\(" "$BIN" | grep -v "^[0-9]*:#"'

# --- the executable, as core's dispatcher runs it ---------------------------------
check "ENTRY: sourcing runs nothing" '[[ -z "$( bash -c "source $BIN" 2>&1 )" ]]'
check "ENTRY: --help prints the usage, rc 0" 'bash "$BIN" --help | gq "^usage: 5dive backup"'
check "ENTRY: an unknown command is rc 2" 'bash "$BIN" bogus >/dev/null 2>&1; [[ $? == 2 ]]'
check "ENTRY: --json mode (forwarded by core as FIVEDIVE_JSON_MODE) fails as JSON" '[[ "$(FIVEDIVE_JSON_MODE=1 bash "$BIN" bogus 2>/dev/null | jq -r ".ok, .error.code" | paste -sd,)" == "false,2" ]]'
if [[ $EUID -ne 0 ]]; then
  check "ENTRY: a root verb refuses a non-root caller with core's E_PERMISSION (10)" 'bash "$BIN" run >/dev/null 2>&1; [[ $? == 10 ]]'
fi
check "ENTRY: status needs no root and says off on a box never set up" 'FIVE_BACKUP_STATE="$TMP/none" FIVE_BACKUP_CRON="$TMP/none/c" FIVE_BACKUP_DIR="$TMP/none" bash "$BIN" status | gq "^backup: off"'

# --- restic install on a stock Ubuntu 24.04 box (drill defect 1) -------------------
# The drill's setup died on `bunzip2: command not found` on 3 of 3 stock boxes.
# These arms run the REAL installer (the harness stubs it everywhere else) with a
# PATH that has no bzip2 at all, against a .bz2 the curl stub serves as the
# release asset and whose sha256 is pinned for the arm.
nobz() {   # <dir> <names to leave out...>: every tool on PATH except those
  local d="$1" x n; shift; mkdir -p "$d"
  for x in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    for n in "$x"/*; do
      [[ -x "$n" && ! -e "$d/${n##*/}" ]] || continue
      case " $* " in *" ${n##*/} "*) continue ;; esac
      ln -s "$n" "$d/${n##*/}"
    done
  done
}
FAKEBZ="$TMP/restic.bz2"
printf '#!/bin/sh\necho "restic 0.17.3 compiled with go1.23.3 on linux/amd64"\n' >"$TMP/fake-restic"
python3 -c 'import bz2,sys; open(sys.argv[2],"wb").write(bz2.compress(open(sys.argv[1],"rb").read()))' "$TMP/fake-restic" "$FAKEBZ"
printf '#!/bin/sh\necho "restic 0.16.0 compiled with go1.21 on linux/amd64"\n' >"$TMP/old-restic"
python3 -c 'import bz2,sys; open(sys.argv[2],"wb").write(bz2.compress(open(sys.argv[1],"rb").read()))' "$TMP/old-restic" "$TMP/old.bz2"
BZ_NONE=(bunzip2 bzip2 bzcat bzip2recover)
nobz "$TMP/p-py" "${BZ_NONE[@]}" apt-get
nobz "$TMP/p-bare" "${BZ_NONE[@]}" apt-get python3 python3.12 python3.11 python3.10 python
# apt-get stub for the bare box: "installs" bzip2 by putting the real one on PATH.
REALBZ=$(command -v bunzip2 || true)
printf '#!/bin/sh\necho "apt-get $*" >>"%s/apt.log"\ncase "$*" in *install*bzip2*) ln -sf "%s" "%s/bunzip2" ;; esac\nexit 0\n' "$TMP" "$REALBZ" "$TMP/p-bare" >"$TMP/p-bare/apt-get"; chmod +x "$TMP/p-bare/apt-get"
install_arm() {   # <PATH> <asset> -> rc of the real _bk_restic_install
  ( source "$BIN"; set +e
    BACKUP_RESTIC_SHA256[amd64]=$(sha256sum "$2" | cut -d' ' -f1); BACKUP_RESTIC_SHA256[arm64]=${BACKUP_RESTIC_SHA256[amd64]}
    curl() { local o="" p="" a; for a in "$@"; do [[ "$p" == -o ]] && o="$a"; p="$a"; done
      [[ "$*" == *github.com/restic/restic/releases/download/v0.17.3/* ]] && cp "$ASSET" "$o"; }
    ASSET="$2" PATH="$1" _bk_restic_install ) >/dev/null 2>&1
}
command -v python3 >/dev/null || bad "INSTALL: python3 is needed to build the arms"
reset; rm -f "$FIVE_BACKUP_RESTIC"; install_arm "$TMP/p-py" "$FAKEBZ"; r=$?
check "INSTALL (1): no bzip2 on the box: restic is installed anyway (rc 0) and runs as 0.17.3" '[[ $r == 0 ]] && "$FIVE_BACKUP_RESTIC" version | gq "^restic 0.17.3 "'
reset; rm -f "$FIVE_BACKUP_RESTIC"; : >"$TMP/apt.log"; install_arm "$TMP/p-bare" "$FAKEBZ"; r=$?
check "INSTALL (1): no bzip2 and no python3: bzip2 comes from apt, then restic installs" '[[ -n "$REALBZ" && $r == 0 ]] && grep -q "install .*bzip2" "$TMP/apt.log" && "$FIVE_BACKUP_RESTIC" version | gq "^restic 0.17.3 "'
rm -f "$TMP/p-bare/bunzip2"
reset; rm -f "$FIVE_BACKUP_RESTIC"; install_arm "$TMP/p-py" "$TMP/old.bz2"; r=$?
check "INSTALL: a binary that is not the pinned version is refused and removed" '[[ $r != 0 && ! -e "$FIVE_BACKUP_RESTIC" ]]'
reset; rm -f "$FIVE_BACKUP_RESTIC"
r=$( ( source "$BIN"; set +e; BACKUP_RESTIC_SHA256[amd64]=00; BACKUP_RESTIC_SHA256[arm64]=00
       curl() { local o="" p="" a; for a in "$@"; do [[ "$p" == -o ]] && o="$a"; p="$a"; done; cp "$FAKEBZ" "$o"; }
       _bk_restic_install >/dev/null 2>&1; echo $? ) )
check "INSTALL: a download whose sha256 is not the pinned one is never installed" '[[ $r != 0 && ! -e "$FIVE_BACKUP_RESTIC" ]]'

# --- EXECUTED: bin/backup run the way core runs it (drill defects 2 and 3) ---------
# Everything above SOURCES the file, so it never ran under the entry trailer's
# `set -euo pipefail`; that is how every `backup run` on a real box exited 2
# with 89/89 green here. These arms EXECUTE it: `bash backup/bin/backup <verb>`
# in a child process, the stubs are programs on PATH, not shell functions, and
# FIVE_BACKUP_EUID stands in for root.
X="$TMP/xbin"; mkdir -p "$X"
cat >"$X/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/curl.argv"
o="" d="" k="" prev="" url="" chat="" textf=""
for a in "$@"; do
  case "$prev" in -o) o="$a" ;; --data) d="$a" ;; -K) k="$a" ;;
    --data-urlencode) case "$a" in chat_id=*) chat="${a#chat_id=}" ;; text@*) textf="${a#text@}" ;; esac ;; esac
  prev="$a"; url="$a"
done
cat >>"$T/curl.stdin"; printf '%s\n' "$d" >>"$T/curl.body"
if [[ -n "$k" ]] && grep -q 'api.telegram.org/bot' "$k"; then
  printf 'chat=%s text=%s\n' "$chat" "$(cat "$textf")" >>"$T/tg"; echo '{"ok":true}'; exit 0
fi
case "$url" in
  *list-type=2*) [[ -n "${LIST_FAIL:-}" ]] && exit 22
     printf '<ListBucketResult><Prefix>o-0123456789abcdef01234567/</Prefix>'
     for r in "$T"/repos/box-*; do [[ -d "$r" ]] && printf '<CommonPrefixes><Prefix>o-0123456789abcdef01234567/%s/</Prefix></CommonPrefixes>' "${r##*/}"; done
     printf '</ListBucketResult>' ;;
  */enroll) printf '%s' "$ENROLL_BODY" >"$o"; printf '%s' "$ENROLL_HTTP" ;;
  */report) printf '{"ok":true}' >"$o"; printf 200 ;;
esac
exit 0
EOF
# A fake account database: getent/useradd/groupadd act on $T/passwd and $T/group
# the way the real tools do (a taken uid/gid is refused, no -u means next free).
cat >"$X/getent" <<'EOF'
#!/usr/bin/env bash
f="$T/$1"; [[ "$1" == passwd || "$1" == group ]] || exit 2
[[ $# -lt 2 ]] && { cat "$f"; exit 0; }
awk -F: -v k="$2" '$1==k || $3==k {print; found=1} END {exit !found}' "$f" || exit 2
EOF
cat >"$X/useradd" <<'EOF'
#!/usr/bin/env bash
echo "useradd $*" >>"$T/sys"; u="" g="" h="" s=/bin/bash p=""
for a in "$@"; do case "$p" in -u) u="$a" ;; -g) g="$a" ;; -d) h="$a" ;; -s) s="$a" ;; esac; p="$a"; done; n="${*: -1}"
awk -F: -v n="$n" '$1==n {f=1} END {exit !f}' "$T/passwd" && exit 9
if [[ -n "$u" ]]; then awk -F: -v u="$u" '$3==u {f=1} END {exit !f}' "$T/passwd" && exit 4
else u=$(awk -F: '$3>=1000 && $3<60000 {print $3}' "$T/passwd" | sort -n | tail -1); u=$(( ${u:-999} + 1 )); fi
gid=$(awk -F: -v g="$g" '$1==g || $3==g {print $3; exit}' "$T/group")
echo "$n:x:$u:${gid:-$u}::$h:$s" >>"$T/passwd"
EOF
cat >"$X/groupadd" <<'EOF'
#!/usr/bin/env bash
echo "groupadd $*" >>"$T/sys"; g="" p=""
for a in "$@"; do [[ "$p" == -g ]] && g="$a"; p="$a"; done; n="${*: -1}"
awk -F: -v n="$n" '$1==n {f=1} END {exit !f}' "$T/group" && exit 9
if [[ -n "$g" ]]; then awk -F: -v g="$g" '$3==g {f=1} END {exit !f}' "$T/group" && exit 4
else g=$(awk -F: '$3>=1000 && $3<60000 {print $3}' "$T/group" | sort -n | tail -1); g=$(( ${g:-999} + 1 )); fi
echo "$n:x:$g:" >>"$T/group"
EOF
for t in usermod systemctl; do printf '#!/usr/bin/env bash\necho "%s $*" >>"$T/sys"\n' "$t" >"$X/$t"; done
for t in chown chgrp; do printf '#!/usr/bin/env bash\necho "%s $*" >>"$T/own"\n' "$t" >"$X/$t"; done
printf '#!/usr/bin/env bash\n[[ "$*" == "agent telegram-access get ava --json" ]] && echo %s\n' "'{\"ok\":true,\"data\":{\"access\":{\"allowFrom\":[1234567890]}}}'" >"$X/5dive"
chmod +x "$X"/*
xreset() {   # reset, plus the executed box: a fake account db and a bot for ava
  reset; : >"$TMP/own"
  printf 'root:x:0:0::/root:/bin/bash\n' >"$TMP/passwd"; printf 'root:x:0:\n' >"$TMP/group"
  mkdir -p "$TMP/w/conn"; printf 'TELEGRAM_BOT_TOKEN=123456:AAbb_cc-DD\n' >"$TMP/w/conn/telegram-ava.env"
}
xrun() {   # bash bin/backup <verb...> as core runs it; rc in $TMP/rc
  env PATH="$X:$PATH" FIVE_BACKUP_EUID=0 REGISTRY="$REGISTRY" FIVEDIVE_CONNECTOR_DIR="$TMP/w/conn" BACKUP_5DIVE_BIN="$X/5dive" \
    ENROLL_BODY="$ENROLL_BODY" ENROLL_HTTP="$ENROLL_HTTP" STAGE_UID="${STAGE_UID:-1007}" STAGE_GID="${STAGE_GID:-1007}" \
    bash "$BIN" "$@" >"$TMP/out" 2>&1; echo $? >"$TMP/rc"
}
check "EXECUTED: the file still runs under core's errexit (the trailer is there)" 'tail -n 6 "$BIN" | gq "set -euo pipefail"'

xreset; xrun setup
check "EXECUTED setup: rc 0, scheduled" '[[ $(rc) == 0 && -f "$FIVE_BACKUP_CRON" ]] || { cat "$TMP/out"; false; }'
xreset; xrun run
check "EXECUTED (2): the FIRST run on a never-set-up box (no status.json) exits 0" '[[ $(rc) == 0 && ! -e "$FIVE_BACKUP_STATE/status.json.tmp" ]] || { cat "$TMP/out"; false; }'
check "EXECUTED (2): it records the run in status.json" 'jq -e ".ok == true and .snapshot == \"abc123\" and .lastOkAt != null" "$FIVE_BACKUP_STATE/status.json" >/dev/null'
check "EXECUTED (2): it reports the run to the API (ok, with the snapshot)" 'grep "\"snapshot\":\"abc123\"" "$TMP/curl.body" | gq "\"ok\":true"'
check "EXECUTED: the first run made the key and DMed the owner its code, once" '[[ -s "$FIVE_BACKUP_DIR/key" && $(grep -c "^chat=1234567890 " "$TMP/tg") == 1 ]] && grep -q "$(_bk_code_pretty "$(code_on_box)")" "$TMP/tg"'
check "EXECUTED CUSTODY: the code is in no API body, header or argv" 'K=$(code_on_box); ! grep -q "$K" "$TMP/curl.argv" "$TMP/curl.body" "$TMP/curl.stdin"'
xrun status
check "EXECUTED status: shows the run" '[[ $(rc) == 0 ]] && grep -q "^last run: .* ok$" "$TMP/out"'
: >"$TMP/curl.body"; xrun run
check "EXECUTED: the second run exits 0 and DMs nothing new" '[[ $(rc) == 0 && $(grep -c "^chat=" "$TMP/tg") == 1 ]] && grep -q "\"ok\":true" "$TMP/curl.body"'
export RESTIC_BACKUP_RC=1; : >"$TMP/curl.body"; xrun run; export RESTIC_BACKUP_RC=0
check "EXECUTED: a FAILED run is visible: rc 1, status.json not ok, reported not ok" '[[ $(rc) == 1 ]] && jq -e ".ok == false and .lastOkAt != null" "$FIVE_BACKUP_STATE/status.json" >/dev/null && grep -q "\"ok\":false" "$TMP/curl.body"'
xrun status
check "EXECUTED status: says FAILED" 'grep -q "FAILED" "$TMP/out"'
xrun code
check "EXECUTED code: prints the code" '[[ $(rc) == 0 ]] && grep -qx "$(_bk_code_pretty "$(code_on_box)")" "$TMP/out"'
xrun sources
check "EXECUTED sources: names this box" '[[ $(rc) == 0 ]] && grep -qx "box-42  (this box)" "$TMP/out"'
xrun uninstall
check "EXECUTED uninstall: rc 0, schedule gone" '[[ $(rc) == 0 && ! -e "$FIVE_BACKUP_CRON" ]]'
xreset; ENROLL_HTTP=503; ENROLL_BODY='{"code":"backup_not_configured"}'; xrun run
check "EXECUTED: an unready API: the run fails visibly (rc 1, status says why)" '[[ $(rc) == 1 ]] && jq -e ".ok == false" "$FIVE_BACKUP_STATE/status.json" >/dev/null'

# The fresh box at another provider: its `ubuntu` user holds the old agent's uid
# and its group the old gid, the way OVH's image held uid 1000 in the drill.
OLDU=$(id -u); OLDG=$(id -g)
if (( OLDU >= 1000 && OLDG > 0 )); then
  xreset; seed box-7 "$GOOD"
  printf 'ubuntu:x:%s:%s::/home/ubuntu:/bin/bash\n' "$OLDU" "$OLDG" >>"$TMP/passwd"; printf 'ubuntu:x:%s:\n' "$OLDG" >>"$TMP/group"
  mkdir -p "$FIVE_BACKUP_ROOT/etc/5dive" "$FIVE_BACKUP_ROOT/home/ubuntu"; echo "CONNECTORD_TOKEN=NEW_BOX" >"$FIVE_BACKUP_ROOT/etc/5dive/connectord.env"
  echo mine >"$FIVE_BACKUP_ROOT/home/ubuntu/.profile"
  STAGE_UID=$OLDU STAGE_GID=$OLDG xrun run   # the fresh box's first nightly run: waits for the code
  check "EXECUTED fresh box: the first run waits for the owner's code (rc 0, no key)" '[[ $(rc) == 0 && ! -e "$FIVE_BACKUP_DIR/key" ]]'
  STAGE_UID=$OLDU STAGE_GID=$OLDG xrun restore --code="$GOOD" --from=box-7 --yes
  NEWU=$(awk -F: '$1=="agent-ava"{print $3}' "$TMP/passwd"); NEWG=$(awk -F: '$1=="agent-ava"{print $3}' "$TMP/group")
  check "EXECUTED restore: rc 0, memory back, agent user recreated under a NEW uid and gid" '[[ $(rc) == 0 ]] && grep -q "blue door" "$FIVE_BACKUP_ROOT/home/agent-ava/MEMORY.md" && [[ -n "$NEWU" && "$NEWU" != "$OLDU" && -n "$NEWG" && "$NEWG" != "$OLDG" ]] || { cat "$TMP/out"; false; }'
  check "UID TAKEN (3): every restored file of the agent is re-owned to its new uid" 'grep -qxF "chown -h $NEWU $FIVE_BACKUP_ROOT/home/agent-ava/MEMORY.md" "$TMP/own" && grep -qxF "chown -h $NEWU $FIVE_BACKUP_ROOT/home/agent-ava" "$TMP/own"'
  check "UID TAKEN (3): and to its new gid" 'grep -qxF "chgrp -h $NEWG $FIVE_BACKUP_ROOT/home/agent-ava/MEMORY.md" "$TMP/own"'
  check "UID TAKEN (3): every staged file of the old uid under the restored paths is re-owned" 'n=$(find "$FIVE_BACKUP_ROOT/home/agent-ava" "$FIVE_BACKUP_ROOT/var/lib/5dive" -uid "$OLDU" | wc -l); [[ $n -gt 2 && $(grep -c "^chown -h $NEWU " "$TMP/own") -ge $n ]]'
  check "UID TAKEN (3): nothing the fresh box had of its own is touched (ubuntu, its identity)" '! grep -q "/home/ubuntu\|connectord.env" "$TMP/own" && [[ "$(cat "$FIVE_BACKUP_ROOT/home/ubuntu/.profile")" == mine ]]'
  : >"$TMP/tg"; : >"$TMP/curl.body"; xrun run
  check "EXECUTED fresh box: the next run after the restore exits 0, reports ok, DMs no new code" '[[ $(rc) == 0 && ! -s "$TMP/tg" ]] && grep -q "\"ok\":true" "$TMP/curl.body" && opens_repo box-42 "$GOOD"'
  xreset; seed box-7 "$GOOD"
  STAGE_UID=$OLDU STAGE_GID=$OLDG xrun restore --code="$GOOD" --from=box-7 --yes
  check "UID FREE: a restore whose uid and gid are free here re-owns nothing" '[[ $(rc) == 0 && ! -s "$TMP/own" ]] && grep -q "useradd -M -u $OLDU " "$TMP/sys"'
else
  echo "skip — the uid-collision arms need a harness user with uid >= 1000 (this one is $OLDU)"
fi

# --- the manifests: what `5dive plugin add 5dive-ai/5dive-backup` reads -------------
M=backup/.claude-plugin/plugin.json
check "MANIFEST: the plugin is named after its folder (contract 1)" '[[ "$(jq -r .name "$M")" == backup ]]'
check "MANIFEST: the marketplace points at ./backup, one plugin" '[[ "$(jq -r ".plugins|length" .claude-plugin/marketplace.json)" == 1 && "$(jq -r ".plugins[0].source" .claude-plugin/marketplace.json)" == ./backup ]]'
check "MANIFEST: the verb is backup, and bin/backup is executable" 'jq -e ".fivedive.capabilities|index(\"verb\")" "$M" >/dev/null && [[ "$(jq -r ".fivedive.verbs[0].name" "$M")" == backup && -x "$BIN" ]]'
check "MANIFEST: setup runs this plugin's own setup verb" '[[ "$(jq -r .fivedive.setup.command "$M")" == "sudo 5dive backup setup" ]]'

# KEY OFF (lodar 2026-11-07 21:47Z, "feels invasive"): with no opt-in, enable and the nightly run
# send the owner NOTHING, keep the code on the box and leave code-delivered unset.
reset; unset FIVE_BACKUP_KEY_TELEGRAM; ( cmd_backup enable ) >"$TMP/en.out" 2>&1
check "KEY OFF: enable sends no Telegram message by default" '[[ -s "$FIVE_BACKUP_DIR/key" && ! -s "$TMP/tg" ]]'
check "KEY OFF: the code is not marked delivered, so a later channel still delivers it" '[[ ! -e "$FIVE_BACKUP_STATE/code-delivered" ]]'
check "KEY OFF: enable says the code stays on the box" 'grep -q "stays on this box" "$TMP/en.out"'
( cmd_backup run ) >/dev/null 2>&1
check "KEY OFF: the nightly run sends nothing either" '[[ ! -s "$TMP/tg" && ! -e "$FIVE_BACKUP_STATE/code-delivered" ]]'
export FIVE_BACKUP_KEY_TELEGRAM=1

# APP (DIVE-7899, lodar 2026-11-07 21:55Z): the owner reads the code in the app, on a tap. The API
# runs `code --json --seen`; the answer carries the approved warning, and --seen ends every other channel.
reset; unset FIVE_BACKUP_KEY_TELEGRAM; ( cmd_backup enable ) >/dev/null 2>&1
( cmd_backup code --json ) >"$TMP/app.out" 2>&1
check "APP: code --json answers {ok, code, lang 5dive, the approved 5dive warning}" 'jq -e --arg c "$(_bk_code_pretty "$(code_on_box)")" --arg w "$(tail -n 1 "$TMP/q.5dive")" ".ok == true and .code == \$c and .lang == \"5dive\" and .warning == \$w" "$TMP/app.out" >/dev/null'
check "APP: a read without --seen leaves the code undelivered" '[[ ! -e "$FIVE_BACKUP_STATE/code-delivered" ]]'
( cmd_backup code --json --seen ) >"$TMP/app.out" 2>&1
check "APP: --seen marks the code delivered and still answers it" '[[ -s "$FIVE_BACKUP_STATE/code-delivered" ]] && jq -e ".ok == true" "$TMP/app.out" >/dev/null'
export FIVE_BACKUP_KEY_TELEGRAM=1; ( cmd_backup run ) >/dev/null 2>&1
check "APP: once seen, the nightly run never sends it on another channel (even opted in)" '[[ ! -s "$TMP/tg" ]]'
( cmd_backup code --bogus ) >"$TMP/app.out" 2>&1; echo $? >"$TMP/rc"
check "APP: an unknown flag refuses with the usage code" '[[ $(rc) == 2 ]]'
rm -f "$FIVE_BACKUP_DIR/key"; ( cmd_backup code --json --seen ) >"$TMP/app.out" 2>&1; echo $? >"$TMP/rc"
check "APP: no key -> a JSON not-found error (rc 4), no code" '[[ $(rc) == 4 ]] && jq -e ".ok == false and .error.code == 4" "$TMP/app.out" >/dev/null'
# The variant the app reads: a partner seat anywhere on the box gives the partner's text.
boxv() { ( source "$BIN"; REGISTRY="$TMP/w/reg.json"; BACKUP_HOME_ROOT="$H"; _bk_box_variant ); }
warnv() { ( source "$BIN"; _bk_code_warning "$1" ); }
chan claude "" -;      check "APP: a 5dive box -> the 5dive variant" '[[ "$(boxv)" == 5dive ]]'
chan claude "$PURL" -; check "APP: a partner box -> Russian" '[[ "$(boxv)" == ru ]]'
chan codex "$PURL" en; check "APP: a partner box, English owner -> English" '[[ "$(boxv)" == en ]]'
check "APP: each warning is the approved text's last paragraph, word for word" '[[ "$(warnv 5dive)" == "$(tail -n 1 "$TMP/q.5dive")" && "$(warnv ru)" == "$(tail -n 1 "$TMP/q.ru")" && "$(warnv en)" == "$(tail -n 1 "$TMP/q.en")" ]]'

echo "---"; echo "passed=$PASSED failed=$FAILED"
(( FAILED == 0 ))
