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
