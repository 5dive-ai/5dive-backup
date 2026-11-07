# Changes

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
