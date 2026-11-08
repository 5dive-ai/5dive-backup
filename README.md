# 5dive backup

Every night, an encrypted copy of your [5dive](https://github.com/5dive-ai/5dive)
agents (memory, chats, settings, task board) goes to storage you choose. If the
server is lost, one command brings the agents back on a fresh one.

Works on any server running 5dive: one you installed yourself, or one 5dive hosts.

**Only you hold the key.** It is made on your server and shown to you as a
recovery code. Your storage, and 5dive, keep only encrypted data and cannot
open it. Lose both the server and the code, and nobody can restore it, 5dive included.

## Set it up on your own server

```
# 1. add the plugin
sudo 5dive plugin add 5dive-ai/5dive-backup --yes

# 2. save your storage keys (it asks for each one, hidden)
sudo 5dive secret write AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY --connector=backup

# 3. turn it on, pointed at your storage
sudo 5dive backup enable --to=s3:s3.eu-central-1.amazonaws.com/my-bucket/5dive

# 4. back up now, then save the recovery code in a password manager
sudo 5dive backup run
sudo 5dive backup code
```

From then on it runs every night. `5dive backup status` shows the last one.
On your own storage it never talks to 5dive.

**Where it can go:** any [restic repository](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html):
S3 or any S3-compatible storage (`s3:`), Backblaze B2 (`b2:`), an SSH server
(`sftp:`), a restic REST server (`rest:`), Azure (`azure:`), Google Cloud
(`gs:`), OpenStack Swift (`swift:`), anything rclone reaches (`rclone:`), or a
path on another disk. Save that storage's keys in step 2 under the names restic
reads, for example `B2_ACCOUNT_ID,B2_ACCOUNT_KEY`. Keys never go on the command
line, and `--to` refuses a password inside the address.

## Restore on a fresh server

Install 5dive on it, then:

```
sudo 5dive plugin add 5dive-ai/5dive-backup --yes
sudo 5dive secret write AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY --connector=backup
sudo 5dive backup restore --code=XXXX-XXXX-... --to=s3:s3.eu-central-1.amazonaws.com/my-bucket/5dive --yes
```

The agents come back and start, and nightly backups carry on to the same place
under the same code. Without `--yes` it only checks that the code opens the backup.

## On a server 5dive hosts

Nothing to do: it is already on, backing up to 5dive's storage (an EU bucket).
The recovery code is in the app, under Settings > Backup. To restore, run
`sudo 5dive backup restore --code=...` on the new server; `--from=box-N` picks an
older server (`sudo 5dive backup sources` lists them). To use your own storage
instead, do steps 2 and 3 above: the code stays the same, and earlier backups
stay where they are.

## Commands

```
5dive backup status                 last backup and its result
sudo 5dive backup run               back up now (the nightly job runs this)
sudo 5dive backup code              show the recovery code again
sudo 5dive backup sources           where this owner's backups are
sudo 5dive backup restore --code=XXXX-XXXX-... [--to=<repo> | --from=box-N] --yes
                                    on a fresh server: bring the agents back
sudo 5dive backup enable [--to=<repo>] [--new-key]
sudo 5dive backup setup | uninstall
```

## What is in the copy

Homes (agent memory and chats), `/var/lib/5dive` (agents, task board),
`/etc/5dive`, the agents' unit settings, sudoers and crontabs. Caches and
`node_modules` are left out. A restore never brings back the old server's own
identity: the fresh server keeps its own.

## How it works

- [restic](https://restic.net) 0.17.3 (pinned, checksum-verified, installed by
  `enable`) encrypts and deduplicates. The password is the recovery code; it
  reaches restic from a 0600 file, never a command line.
- Your storage keys live in the server's secret store
  (`/etc/5dive/connectors/backup.env`, root only), and only the variables restic
  reads are passed to it.
- On 5dive's storage: one Cloudflare R2 bucket in the EU. Before every run the
  server asks 5dive's API for a 36-hour credential that opens only its owner's
  folder, and each server writes its own repository (`box-<id>`) there. A failed
  night is reported to 5dive.
- A failed night always shows in `5dive backup status`.
- The server provider's own snapshots are untouched; this is an extra copy.

## Tests

```
bash tests/backup_unit.sh          # no root, network or box needed
bash tests/negative-controls.sh    # each guard broken in turn must go red
```
