# Changes

## 1.1.1 — 2026-11-08 (DIVE-7899, the code in the app)

- `5dive backup code --json` answers `{ok, code, lang, warning}`: the warning is
  the approved key text's last paragraph, in the box's variant (a partner seat
  anywhere on the box gives the partner's RU/EN text). The app shows it under
  the code in Settings > Backup.
- `--seen`: the owner has read it, so `code-delivered` is written and the
  nightly run never sends it on another channel. Arms APP ×11, mutants m21-m22.

## 1.1.0 — 2026-11-07 (DIVE-7873)

Your own storage (lodar: «should we make it customizable?»).

- `5dive backup enable --to=<restic repository>`: back up to a local path or any
  restic backend (s3, b2, sftp, rest, azure, gs, swift, rclone) instead of 5dive's
  storage. Its keys come from the box's secret store (`5dive secret write …
  --connector=backup`), only the variables restic reads, never argv. A password
  inside the URL is refused.
- That path makes no request to the 5dive API (no enrol, no report, no listing),
  and it runs on a server 5dive does not host. `restore --to=` brings a backup back
  from it on a fresh box. The key and the recovery code are unchanged, and so is 1.0.1's rule:
  no Telegram message with the code unless `FIVE_BACKUP_KEY_TELEGRAM=1`.
- A local destination is left out of its own backup. `status` names the destination.
- Tests: backup_unit TO1-TO10 (zero API requests asserted on enable, run, sources
  and restore); mutants m10-m12. `tests/to_real_restic.sh <restic>` runs the same
  round trip with the real restic 0.17.3 (not in CI: it needs the release).

## 1.0.1 — 2026-11-07 (key message off)

- The recovery code is no longer sent as a Telegram message from the box's bot
  (lodar: «feels invasive»). It stays on the box (`5dive backup code`), the
  nightly run sends nothing, and `code-delivered` stays unset. The owner will
  see it in the app's Settings > Backup. `FIVE_BACKUP_KEY_TELEGRAM=1` turns
  the old message back on. Arms KEY OFF ×4, mutant m20.

## 1.0.0 — 2026-11-07 (DIVE-7873)

First release, moved out of the open-source CLI before it ever shipped there
(lodar: «lets not scare self hosters with that. should have been a plugin»).
The code is the core port at 5dive-ai/5dive 6be8e033 (both rounds of review
fixes included). What changed in the move:

- `5dive backup setup` / `uninstall`: the nightly schedule and restic, written
  by `5dive plugin setup` instead of the CLI's install.sh.
- The owner's recovery-code DM goes through core's
  `5dive agent telegram-access get` and the plugin's own send, instead of
  core's in-process helpers. DMs only; groups never get the code.

Fixed before release, from the fresh-box restore drill (a stock Ubuntu 24.04 box,
then a fresh OVH server):

- restic now installs on a server with no bzip2 (stock Ubuntu 24.04 on Hetzner,
  OVH and the cloud image has none): python3 unpacks the release, and bzip2
  comes from apt as a last resort. It counts as installed only once it runs as
  the pinned version.
- `backup run` no longer exits 2 on a box's first run (no status.json yet), so
  every run is recorded in `backup status` and reported, failures included.
- A restore onto a server where the agent's old uid or gid is taken (OVH's
  `ubuntu` is uid 1000) gives the restored files to the agent's new uid and gid.
  Only files the restore put in place change owner; the new server's own
  files and identity are left alone.
- Tests now also EXECUTE `bin/backup` under its own `set -euo pipefail`
  (setup, run, status, code, sources, restore, uninstall), not only source it.
  Mutants m13-m16.

Fixed before release, from review of the owner's key message (DIVE-7893):

- The backup key goes to the server's OWNER only, never to everyone the bot
  talks to. A guest added in the app or a partner's cabinet used to get it too.
  The owner is the telegram plugin's own owners record; a bot with no such
  record and two or more people paired sends nobody the key (the owner can
  read it with `5dive backup code`).
- A partner's client server (OINOA) gets the partner's text, approved by lodar:
  Russian, or English when the owner's Telegram language is known and is not
  Russian. It names no platform and no provider. 5dive's own servers get the
  same text as before.
- Tests: OWNER ONLY and partner PICK arms; mutants m17-m19.
