# DIVE-7873 negative controls. Each function breaks ONE guarded behaviour of
# backup/bin/backup in the tree it is run in; tests/negative-controls.sh runs
# each on a throwaway copy and requires tests/backup_unit.sh to go red.
# m1-m6 are the it2 controls carried from the core port (5dive-ai/5dive
# 6be8e033), retargeted at the plugin's file; m7-m9 guard what the move added.
F=backup/bin/backup
# m1: a restore brings back the OLD box's identity -> IDENTITY reds.
m1() { sed -i 's#/etc/5dive/connectord.env /etc/5dive/provisioning.env#/etc/5dive/provisioning.env#' "$F"; }
# m2: enable ignores an EARLIER box's backup under the owner's prefix -> FRESH BOX
# and SEQUENCE step 1 red.
m2() { sed -i 's/if \[\[ -n "\$repos" \]\] && (( ! newkey )); then/if false; then/' "$F"; }
# m3: restore claims backups continue when nothing opens this box's own repo -> MISMATCH reds.
m3() { sed -i 's/own_err="\$BK_REPO already holds a backup under a different key, and nothing on this box opens it"/:/' "$F"; }
# m4: restore probes with the box's old key but never re-keys -> RE-KEY reds.
m4() { sed -i 's/_bk_repo_probe "\$dir\/key" && _bk_rekey "\$dir\/key" "\$pw"; }/_bk_repo_probe "$dir\/key"; }/' "$F"; }
# m5: a failed run's error comes from the log's last line again -> the silent-restic arm reds.
m5() { sed -i 's/local last; last=\$(grep -v/local last; last=$(tail -n 1 "$log"); : $(grep -v/' "$F"; }
# m6: the code leaks into the run report -> CUSTODY reds.
m6() { sed -i 's/_bk_report "\$ok" "\$err" "\$bytes" "\$snap"$/_bk_report "$ok" "$err $(cat "$dir\/key")" "$bytes" "$snap"/' "$F"; }
# m7: the code goes to every chat the bot is paired with, groups included -> the DMs-only arm reds.
m7() { sed -i 's/\[\[ "\$chat" =~ \^\[0-9\]+\$ \]\] || continue   # a positive id/[[ "$chat" =~ ^-?[0-9]+$ ]] || continue   # a positive id/' "$F"; }
# m8: setup overwrites the per-box schedule enable wrote -> SETUP idempotence reds.
m8() { sed -i 's/  if \[\[ ! -f "\$c" \]\]; then/  if true; then/' "$F"; }
# m9: the bot token rides curl's argv again -> SEND reds.
m9() { sed -i 's#  curl -s --connect-timeout 5 --max-time 10 -X POST -K "\$cfg"#  curl -s --connect-timeout 5 --max-time 10 -X POST "https://api.telegram.org/bot${token}/sendMessage"#' "$F"; }
# m13-m16 guard the it4 drill fixes (main's fresh-box drill, 11-07). m10-m12 are
# taken by the custom-destination branch stacked on this one.
# m13: restic is decompressed with bunzip2 only again -> INSTALL (1) reds (stock Ubuntu has no bzip2).
m13() { sed -i 's/^  if command -v bunzip2 >\/dev\/null 2>&1; then bunzip2 -c "\$1" >"\$2" \&\& return 0; fi$/  bunzip2 -c "$1" >"$2"; return/' "$F"; }
# m14: the first run's status read dies on the missing status.json under errexit -> EXECUTED (2) reds.
m14() { sed -i 's/prev_ok=\$(jq -r .\.lastOkAt \/\/ empty. "\$s\/status\.json" 2>\/dev\/null) || prev_ok=""/prev_ok=$(jq -r ".lastOkAt \/\/ empty" "$s\/status.json" 2>\/dev\/null)/' "$F"; }
# m15: a restore never re-owns files whose uid changed -> UID TAKEN (3) reds.
m15() { sed -i 's/^  _bk_restore_reown "\$stage" "\$(_bk_root)" ||/  true ||/' "$F"; }
# m16: the re-own walk ignores the restore's skip list -> it re-owns the new box's identity, UID TAKEN (3) reds.
m16() { sed -i 's/^        _bk_restore_skipped "\$p\/\$rel" \&\& continue$/        :/' "$F"; }
# m17-m19 guard it5 (DIVE-7893's finding, and lodar's 16:30:39Z yes to partner servers).
# m17: the key goes to everyone on allowFrom again, guests included -> OWNER ONLY reds.
m17() { sed -i 's/^          then \[\$a.owners\[\] | tostring | select(. as \$o | \$allow | index(\$o))\]$/          then $allow/' "$F"; }
# m18: a partner box gets the 5dive text (no partner pick) -> PICK and PARTNER, delivered red.
m18() { sed -i "s/^  grep -qE '\^TELEGRAM_ACCOUNT_URL=.+' \"\$d\/.env\" 2>\/dev\/null || { printf 5dive; return 0; }$/  printf 5dive; return 0/" "$F"; }
# m19: a partner owner whose language is unknown gets English, not Russian -> PICK reds.
m19() { sed -i 's/^  case "\${v,,}" in ""|ru\*) printf ru ;; \*) printf en ;; esac$/  case "${v,,}" in ru*) printf ru ;; *) printf en ;; esac/' "$F"; }
