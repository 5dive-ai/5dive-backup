# 5dive-backup

Official 5dive plugin: a nightly, owner-encrypted backup of a 5dive cloud server's agents, restorable on a fresh server.

The encryption key is made on the server and held only by the server and its owner. 5dive stores ciphertext only.

Installed on 5dive cloud servers. It is not part of the open-source `5dive` CLI. A self-hosted server gets it only if its owner adds it with `5dive plugin add`.
