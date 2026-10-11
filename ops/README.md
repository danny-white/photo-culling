# Ingest automation

Watches `/mnt/passport/Pictures/YYYY/YYYY-MM-DD` for new shoot folders (year-folders only —
other top-level folders on the drive, like screenshot dumps or `$RECYCLE.BIN`, are deliberately
out of scope), culls any that have gone quiet for 15+ minutes (avoids grabbing a still-copying
import), and merges a plugin-data TSV for each into one accumulating `/mnt/Passport_AICullInbox/pending.tsv`
(so several shoots worth of syncing pile up into a single Lightroom sync instead of one file per
shoot). Since the Mac
already mounts that same path (as `/Volumes/Passport/AICullInbox`), no network push is needed;
the Lightroom plugin's file picker defaults straight into that inbox. Applying it in Lightroom is
still a manual click — see [`lightroom-plugin/README.md`](../lightroom-plugin/README.md) — this
only automates the "run the AI + drop the data where LrC can see it" half.

## Mounts

This box mounts the passport share **twice**, deliberately narrow on both sides:

| Mount | Path | Mode | Scope |
|---|---|---|---|
| `//mycloud/passport` | `/mnt/passport` | read-only (guest) | whole share, for scanning `Pictures/` only |
| `//mycloud/Passport/AICullInbox` | `/mnt/Passport_AICullInbox` | read-write | **only** this subfolder |

The write mount targets the `AICullInbox` subpath directly (not the share root), so `Pictures/`
is structurally unreachable through it — a bug in the watcher can't touch the actual library,
not just "isn't supposed to."

**Both are persisted in `/etc/fstab`** with `nofail,_netdev` so a reboot never blocks on them (or
fails boot outright) if the NAS or drive happens to be unreachable — they just don't come up, and
the watcher's own `mountpoint` check catches that on the next poll. Entries:
```
//mycloud/passport /mnt/passport cifs username=guest,uid=1000,forceuid,gid=1000,forcegid,ro,_netdev,nofail 0 0
//mycloud/Passport/AICullInbox /mnt/Passport_AICullInbox cifs username=guest,uid=1000,forceuid,gid=1000,forcegid,file_mode=0664,dir_mode=0775,rw,_netdev,nofail 0 0
```
To add them (one-time):
```bash
printf '%s\n%s\n' \
  '//mycloud/passport /mnt/passport cifs username=guest,uid=1000,forceuid,gid=1000,forcegid,ro,_netdev,nofail 0 0' \
  '//mycloud/Passport/AICullInbox /mnt/Passport_AICullInbox cifs username=guest,uid=1000,forceuid,gid=1000,forcegid,file_mode=0664,dir_mode=0775,rw,_netdev,nofail 0 0' \
  | sudo tee -a /etc/fstab
sudo mount -a
```
`sudo mount -a` mounts anything in `/etc/fstab` not already mounted — safe to run any time,
including while the watcher is active, since it leaves already-mounted entries alone.

`watch_ingest.sh` still checks `mountpoint` + the exact source path before writing anything, so if
fstab ever fails to bring a mount up (NAS off, drive unplugged), that poll aborts loudly in the
log instead of silently dropping TSVs into an empty local directory — and picks back up cleanly
on the next 15-minute tick once the mount returns.

The `photo-cull-ingest.timer` itself needs no manual restart after a reboot — `loginctl
show-user $USER -p Linger` should read `Linger=yes`, which is what lets the systemd `--user`
manager (and its enabled timers) start at boot without an interactive login. If a fresh box ever
shows `Linger=no`, enable it with `loginctl enable-linger $USER`.

## One-time setup

```bash
ln -s /home/danny/photo-culling/ops/photo-cull-ingest.service ~/.config/systemd/user/
ln -s /home/danny/photo-culling/ops/photo-cull-ingest.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now photo-cull-ingest.timer
```

### Batch-complete email (optional but recommended)

The watcher emails `NOTIFY_EMAIL` (set at the top of `watch_ingest.sh`) exactly once whenever
the pending queue drains from >0 back to 0 -- i.e. "the batch you just imported is fully culled
and ready to sync," whether that took one 15-minute poll or several. Idle polls (nothing pending)
and in-progress polls (still >0 after this run) stay silent.

Needs `msmtp` + a one-time Gmail App Password (not your normal Google password):

```bash
sudo apt install -y msmtp msmtp-mta
```
1. https://myaccount.google.com/apppasswords -> generate an app password (requires 2-Step
   Verification on the Google account).
2. Edit `~/.msmtprc` (already created with everything else filled in) and add the password line
   inside the `account aicull` block:
   ```
   password    <the 16-char app password, no spaces>
   ```
3. `chmod 600 ~/.msmtprc` -- msmtp refuses to run otherwise.
4. Test it: `echo "test" | msmtp your@email.com` (or just wait for a real batch to drain).

If `msmtp` isn't installed or isn't configured yet, the watcher still runs fine -- it just logs
"batch complete... but msmtp isn't installed" instead of emailing. Failures show up in
`~/.msmtp.log` and in `trial_out/ingest_watch.log`.

## Operating it

- `journalctl --user -u photo-cull-ingest.service -f` — watch it fire.
- `tail -f trial_out/ingest_watch.log` — the watcher's own log (what it culled/exported/skipped/
  aborted).
- `trial_out/ingest_markers/<shoot>.done` — one marker per exported shoot folder, storing the
  folder's newest-file mtime at last export. Delete a marker (or touch a new file into that
  shoot) to force a re-cull + re-export on the next poll.
- `systemctl --user start photo-cull-ingest.service` — run a poll right now instead of waiting.
- `/mnt/Passport_AICullInbox/pending.tsv` accumulates every shoot processed since the last applied
  Lightroom sync (merged by shoot folder + filename, not overwritten) — one sync catches up
  everything. The plugin moves it to `applied/` once a full, uncanceled sync finishes, and the
  next shoot starts a fresh `pending.tsv`. You can also regenerate a one-off combined TSV any time
  with `photo_cull.py export --plugin-data ... --db trial_out/trial.db` (no `--folder`).

## Why polling instead of inotify

Recursive `inotifywait` on a big passport-drive tree is expensive and fragile across mounts/
unmounts. A 15-minute poll plus a 15-minute stability window is cheap (nothing to do if no
folder's newest file changed) and tolerant of the drive being unplugged between imports.
