# 5dive backup

Every night, a 5dive-hosted server sends an encrypted copy of its agents to a
second provider. If the server is lost, one command brings the agents back on a
fresh one.

**Only the owner holds the key.** It is made on the server and sent once to the
owner's Telegram as a recovery code. 5dive stores only encrypted data and cannot
open it. Lose both the server and the code, and nobody can restore it, 5dive
included.

## Where it goes

- **On a server 5dive hosts:** 5dive's storage (an EU bucket), set up by the 5dive provisioner. Nothing to do.
- **Anywhere else:** your own storage, `sudo 5dive backup enable --to=<restic repository>` (a local path, `s3:`, `b2:`, `sftp:`, `rest:`, `azure:`, `gs:`, `swift:`, `rclone:`). Its keys go in the box's secret store, never the command line: `sudo 5dive secret write AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY --connector=backup`. This path never talks to 5dive.

The key, the recovery code, restore and status work the same on both. It is not part of the open-source 5dive CLI: a self-installed server gets it only if its owner adds it (`5dive plugin add backup@5dive-backup`).

## Commands

```
5dive backup status                 last backup and its result
sudo 5dive backup run               back up now (the nightly job runs this)
sudo 5dive backup code              show the recovery code again
sudo 5dive backup sources           this owner's servers that have a backup
sudo 5dive backup restore --code=XXXX-XXXX-... [--from=box-N | --to=<repo>] --yes
                                    on a fresh server: bring the agents back
sudo 5dive backup enable [--new-key] [--to=<restic repository>]
sudo 5dive backup setup | uninstall
```

## What is in the copy

Homes (agent memory and chats), `/var/lib/5dive` (agents, task board),
`/etc/5dive`, the agents' unit settings, sudoers and crontabs. Caches and
`node_modules` are left out. A restore never brings back the old server's own
identity: the fresh server keeps its own.

## How it works

- [restic](https://restic.net) 0.17.3 (pinned, checksum-verified) encrypts and
  deduplicates. The password is the recovery code; it reaches restic from a
  0600 file, never a command line.
- One Cloudflare R2 bucket in the EU. Before every run the server asks 5dive's
  API for a 36-hour credential that opens only its owner's folder. It cannot
  read or write any other owner's.
- Each server writes its own repository (`box-<id>`) in that folder, so a fresh
  server can restore an older one by name.
- A failed night shows in `5dive backup status` and is reported to 5dive.
- The server provider's own snapshots are untouched; this is an extra copy.

## Install

The provisioner runs, as root:

```
5dive plugin add 5dive-ai/5dive-backup --yes
5dive plugin setup backup@5dive-backup --yes
```

## Tests

```
bash tests/backup_unit.sh          # no root, network or box needed
bash tests/negative-controls.sh    # each guard broken in turn must go red
```
