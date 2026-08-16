# Ingest automation

Watches `/mnt/passport/Pictures/YYYY/YYYY-MM-DD` for new shoot folders (year-folders only —
other top-level folders on the drive, like screenshot dumps or `$RECYCLE.BIN`, are deliberately
out of scope), culls any that have gone quiet for 15+ minutes (avoids grabbing a still-copying
import), and exports a plugin-data TSV per shoot into `/mnt/Passport_AICullInbox/`. Since the Mac
already mounts that same path (as `/Volumes/Passport/AICullInbox`), no network push is needed;
the Lightroom plugin's file picker defaults straight into that inbox. Applying it in Lightroom is
still a manual click — see [`lightroom-plugin/README.md`](../lightroom-plugin/README.md) — this
only automates the "run the AI + drop the data where LrC can see it" half.

## Mounts

This box mounts the passport share **twice**, deliberately narrow on both sides:

| Mount | Path | Mode | Scope |
|---|---|---|---|
| `//192.168.1.5/passport` | `/mnt/passport` | read-only (guest) | whole share, for scanning `Pictures/` only |
| `//192.168.1.5/Passport/AICullInbox` | `/mnt/Passport_AICullInbox` | read-write | **only** this subfolder |

The write mount targets the `AICullInbox` subpath directly (not the share root), so `Pictures/`
is structurally unreachable through it — a bug in the watcher can't touch the actual library,
not just "isn't supposed to."

**Both are transient (no `/etc/fstab` entry) — neither survives a reboot.** After a restart,
re-run:
```bash
sudo mount -t cifs //192.168.1.5/passport /mnt/passport \
  -o username=guest,uid=1000,forceuid,gid=1000,forcegid,ro
sudo mount -t cifs "//192.168.1.5/Passport/AICullInbox" /mnt/Passport_AICullInbox \
  -o username=root,uid=1000,forceuid,gid=1000,forcegid,file_mode=0664,dir_mode=0775,rw
```
`watch_ingest.sh` checks `mountpoint` + the exact source path before writing anything, so a
missed remount fails loudly in the log rather than silently dropping TSVs into an empty local
directory.

## One-time setup

```bash
ln -s /home/danny/photo-culling/ops/photo-cull-ingest.service ~/.config/systemd/user/
ln -s /home/danny/photo-culling/ops/photo-cull-ingest.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now photo-cull-ingest.timer
```

## Operating it

- `journalctl --user -u photo-cull-ingest.service -f` — watch it fire.
- `tail -f trial_out/ingest_watch.log` — the watcher's own log (what it culled/exported/skipped/
  aborted).
- `trial_out/ingest_markers/<shoot>.done` — one marker per exported shoot folder, storing the
  folder's newest-file mtime at last export. Delete a marker (or touch a new file into that
  shoot) to force a re-cull + re-export on the next poll.
- `systemctl --user start photo-cull-ingest.service` — run a poll right now instead of waiting.
- `/mnt/Passport_AICullInbox/` accumulates one TSV per shoot over time; each is independently
  applicable (or you can regenerate a single combined TSV any time with
  `photo_cull.py export --plugin-data ... --db trial_out/trial.db`, no `--folder`).

## Why polling instead of inotify

Recursive `inotifywait` on a big passport-drive tree is expensive and fragile across mounts/
unmounts. A 15-minute poll plus a 15-minute stability window is cheap (nothing to do if no
folder's newest file changed) and tolerant of the drive being unplugged between imports.
