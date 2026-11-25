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

## Installing the units

Every unit lives in `ops/` and is a symlink from `~/.config/systemd/user/`, so the repo is the
only copy and `git log` shows every change. Never edit the file under `~/.config/systemd/user/`;
edit the one in `ops/`.

| Unit | What it does |
|---|---|
| `photo-review.service` | The review server: Culling Bay's web pages and API on port 8000, the desktop monitor. Starts at login, restarts on failure. `KillMode=process`, so a tagging run it started survives a restart. |
| `photo-cull-ingest.service` | One poll of the ingest watcher (`watch_ingest.sh`). A oneshot with a 12-hour limit, so a run stuck on a stale NAS mount is stopped instead of blocking every later poll. |
| `photo-cull-ingest.timer` | Starts the poll 5 minutes after boot, then every 15 minutes. |
| `culling-bay-backup.service` | One run of `backup.sh`: the databases and small state to the NAS, then the code to GitHub (see "Backups"). Low CPU and disk priority, 1-hour limit. |
| `culling-bay-backup.timer` | Runs it every night at 03:17. If the PC was off then, it runs once at the next boot. |

```bash
ln -sf ~/photo-culling/ops/photo-review.service ~/.config/systemd/user/
ln -sf ~/photo-culling/ops/photo-cull-ingest.service ~/.config/systemd/user/
ln -sf ~/photo-culling/ops/photo-cull-ingest.timer ~/.config/systemd/user/
ln -sf ~/photo-culling/ops/culling-bay-backup.service ~/.config/systemd/user/
ln -sf ~/photo-culling/ops/culling-bay-backup.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now photo-cull-ingest.timer     # timers: enable --now
systemctl --user enable --now culling-bay-backup.timer
systemctl --user enable --now photo-review.service        # first install only
```

After changing a unit in `ops/`, run `systemctl --user daemon-reload`. A changed `ExecStart`
also needs `systemctl --user restart photo-review.service` (the server is down for a few seconds).

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
- `trial_out/ingest_markers/<shoot>.done` — one marker per finished shoot folder, holding its
  signature, `v2 <folder mtime> <newest photo mtime> <photo count>` (epoch seconds). A "photo" is
  a file `photo_cull.py` would register: its `ALL_EXTENSIONS` in any case, no dotfiles. The
  watcher asks `photo_cull.py folder-state --print-extensions` for the list on every poll, so the
  two can't drift apart. Everything else in a shoot folder (`.DS_Store` and `._` files from the
  Mac, Lightroom's `.xmp` sidecars, videos) is ignored, so it can't send a finished folder back
  to Lightroom. The folder's own mtime is the time files were last copied in (a card copy keeps
  each file's camera date, so the file times can't see it). A folder is looked at again when a
  photo has come or gone or the newest photo changed. If only the folder's own mtime moved, the
  marker is quietly rewritten and nothing is processed. A folder is *busy*, and skipped for the
  poll, while its own mtime or any file's mtime (photo or not) is under 15 minutes old.
  To force a re-cull + re-export of a folder, delete its marker. Do that after replacing a photo
  in place with a different file of the same name and camera date (for example a recovered copy
  of an empty original): the count and newest photo don't change, so the watcher can't see it.
  A folder with no photos in it is skipped.
  Markers from before 24 Nov 2026 hold a single number (the newest file's mtime). The first poll
  rewrites those in the new form *without* processing, when the number still matches the newest
  file (or the newest photo, with only non-photos newer since), the folder's photo count equals
  its rows in the DB and nothing in it is pending or retryable. Any other old marker is
  processed, which appends that folder to `pending.tsv` again.
- **Failed photos.** `run` is called with `--retry-failed`. A photo that failed to tag is tried
  again on every poll, up to 4 tries in all (`MAX_ATTEMPTS` in `photo_cull.py`), and a folder
  with such photos stays unmarked, so the next poll comes back to it. Empty files (0 bytes) and
  photos that used all their tries are "unreadable": they stop holding the folder back. The log
  says `retry pending for <folder>: N photos` while it waits. If Ollama isn't answering, `run`
  exits 3 and the watcher logs `run deferred: Ollama not answering` and ends that poll.
- **Trying it safely.** Every path is an environment variable with the live value as its default:
  `PROJ`, `DB`, `LIBRARY_ROOT`, `INBOX`, `INBOX_SOURCE`, `MARKERS`, `LOG`, `PY`, `STABLE_MINUTES`,
  `NOTIFY_EMAIL`, and `CHECK_MOUNT=0` (skips the two mount checks; tests only). `DRY_RUN=1` logs
  what it would do (to stdout and the log) and runs no step and writes no marker. Never run the
  script with the defaults to "see what happens": that is the live run. `review/tests/test_watch_ingest.py`
  runs the real script against a temp library with a stub Python.
- `systemctl --user start photo-cull-ingest.service` — run a poll right now instead of waiting.
- `/mnt/Passport_AICullInbox/pending.tsv` accumulates every shoot processed since the last applied
  Lightroom sync (merged by shoot folder + filename, not overwritten) — one sync catches up
  everything. The plugin moves it to `applied/` once a full, uncanceled sync finishes, and the
  next shoot starts a fresh `pending.tsv`. You can also regenerate a one-off combined TSV any time
  with `photo_cull.py export --plugin-data ... --db trial_out/trial.db` (no `--folder`).

## Why polling instead of inotify

Recursive `inotifywait` on a big passport-drive tree is expensive and fragile across mounts/
unmounts. A 15-minute poll plus a 15-minute stability window is tolerant of the drive being
unplugged between imports, and needs nothing running between polls.

## Backups

`culling-bay-backup.timer` runs `ops/backup.sh` every night at 03:17 (and once at the next boot if
the PC was off then). It copies what cannot be rebuilt cheaply to the NAS, then pushes the code to
GitHub.

**What is saved.** One folder per day, `/mnt/nas_drive/backups/culling-bay/<YYYY-MM-DD>/`
(Drive share; in FileBrowser it is `My Drive` > `backups` > `culling-bay`). The newest 14 days are
kept; older dated folders are deleted. Each folder holds:

| File | What it is |
|---|---|
| `annotations.db` | Every phone decision, the day states and the Practice progress. |
| `trial.db` | The photo index: weeks of GPU tagging, embeddings, GPS and shot info. |
| `state.tar.gz` | `trial_out/mobile` (`practice.json`, `pano.json`), `trial_out/ingest_markers`, `trial_out/known-unreadable.txt`, the eval labels, grades, runs and audits (`eval/set.json`, `labels/`, `grades/`, `runs/`, `audits/`, `report.json`; not `eval/images/`), `ops/*.service` and `ops/*.timer`, and `systemd-user/`: what the units in `~/.config/systemd/user/` resolve to. |

Both databases are WAL databases that the server writes to while the backup runs, so they are copied
with SQLite's own backup (never `cp`), and each copy must pass `PRAGMA quick_check` or the run fails.
The script refuses to write unless `/mnt/nas_drive` is mounted from `//mycloud/Drive`, and it waits up
to 2 minutes for the share (just after a boot). A day's folder is built under a hidden
`.incoming-...` name and renamed into place, so a run that dies never leaves half a backup. A second
run on the same day replaces that day's folder.

**Run one now:**

```bash
systemctl --user start culling-bay-backup.service
cat ~/photo-culling/trial_out/backup-status.json
tail -3 ~/photo-culling/trial_out/backup.log
```

`backup-status.json` says when it ran, whether it worked (`ok`, `error`), the folder and file sizes,
and how the push went (`push.ok`, `push.message`). `last_ok_at` is the last run that worked, kept
across failed runs. `GET /m/api/pipeline-health` (the Pi status page) reads it and warns: "No backup
yet"; "Backup is N days old" (2 days or more is a warning, 4 or more is bad); "Last backup failed: ...";
"GitHub push didn't go through: ...".

**Restore `annotations.db`.** Pick the day, stop the server, put the old files aside, copy the backup in:

```bash
B=/mnt/nas_drive/backups/culling-bay/2026-11-24        # the day to restore
systemctl --user stop photo-review.service
cd ~/photo-culling/trial_out
mkdir -p before-restore && mv annotations.db* before-restore/    # keeps the live file and its -wal/-shm
cp "$B/annotations.db" annotations.db
sqlite3 annotations.db "PRAGMA quick_check"                      # must print: ok
systemctl --user start photo-review.service
```

Deleting the old `-wal` and `-shm` files matters: a leftover `-wal` from the old file would be
applied on top of the restored one. Decisions made since that night's backup are gone.

**Restore `trial.db`.** The same, but the ingest watcher also writes to it, so stop that first and make
sure no tagging run is going (`pgrep -af photo_cull.py` prints nothing):

```bash
B=/mnt/nas_drive/backups/culling-bay/2026-11-24
systemctl --user stop photo-cull-ingest.timer photo-cull-ingest.service photo-review.service
cd ~/photo-culling/trial_out
mkdir -p before-restore && mv trial.db* before-restore/
cp "$B/trial.db" trial.db
sqlite3 trial.db "PRAGMA quick_check"                            # must print: ok
systemctl --user start photo-review.service photo-cull-ingest.timer
```

**Restore small state.** Unpack into a scratch folder and copy back only what is needed (unpacking
straight into the project would overwrite `ops/` and `eval/`):

```bash
mkdir -p /tmp/restore && tar -xzf "$B/state.tar.gz" -C /tmp/restore && ls /tmp/restore
```

**GitHub.** After the copy, `backup.sh` pushes `main` to `origin` (a plain push of that one branch;
never `--force`, never other branches). **The GitHub repo is public.** So first it scans every line
the unpushed commits add, in all of them (a token added in one commit and removed in the next would
still go public), for secret-shaped text: private-key headers, `ghp_`/`github_pat_` tokens, `sk-`
keys, Slack `xox` tokens, AWS `AKIA` keys, a password being set (the word, then `=` or `:`, then a value), and long quoted values after `api_key`,
`token` or `secret`. On a match nothing is pushed; the status and the health page name the file and
the kind of match, never the text. The backup itself still counts as done.

If a push is blocked: read the commits (`git log -p origin/main..main`). A real secret has to come out
of those commits (rewrite them, and treat the secret as leaked and replace it). A false alarm is a
human call: push by hand with `git push origin main`, which also clears the block, since the scan
only looks at commits GitHub does not have yet. If `origin/main` has commits that this copy lacks, the
push is skipped ("diverged") and left for a human. The push uses the git credentials already set up
for github.com on this PC. It is recorded, not retried, until the next night.

**Settings** (environment variables, for tests and odd cases; defaults in the script): `PROJ`, `DEST`,
`DEST_MOUNT`, `DEST_SOURCE`, `KEEP`, `CHECK_MOUNT` (0 only in tests), `PUSH` (0 turns the push off),
`REMOTE`, `BRANCH`, `STATUS`, `LOG`, `UNIT_DIR`, `MOUNTS_FILE`, `MOUNT_WAIT`. The tests
(`review/tests/test_backup.py`) run the script against temp directories and a temp bare repo.
