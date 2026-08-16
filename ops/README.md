# Ingest automation

Watches `/mnt/passport/Pictures/*/*` for new shoot folders, culls any that have gone quiet for
15+ minutes (avoids grabbing a still-copying import), and exports a plugin-data TSV per shoot
into `/mnt/Passport_Writeable/AICullInbox/` — a folder on the passport drive itself. Since the
Mac already mounts that same share (as `/Volumes/Passport`), no network push is needed; the
Lightroom plugin's file picker defaults straight into that inbox. Applying it in Lightroom is
still a manual click — see [`lightroom-plugin/README.md`](../lightroom-plugin/README.md) — this
only automates the "run the AI + drop the data where LrC can see it" half.

Note: this box mounts the share twice — `/mnt/passport` is a read-only guest mount (fine for
scanning `Pictures/`), `/mnt/Passport_Writeable` is a read-write mount of the same share (needed
to drop TSVs). Both resolve to `/Volumes/Passport` on the Mac.

## One-time setup

```bash
ln -s /home/danny/photo-culling/ops/photo-cull-ingest.service ~/.config/systemd/user/
ln -s /home/danny/photo-culling/ops/photo-cull-ingest.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now photo-cull-ingest.timer
```

Nothing else to configure — no host/credentials, since the handoff is just a shared drive.

## Operating it

- `journalctl --user -u photo-cull-ingest.service -f` — watch it fire.
- `tail -f trial_out/ingest_watch.log` — the watcher's own log (what it culled/exported/skipped).
- `trial_out/ingest_markers/<shoot>.done` — one marker per exported shoot folder, storing the
  folder's newest-file mtime at last export. Delete a marker (or touch a new file into that
  shoot) to force a re-cull + re-export on the next poll.
- `systemctl --user start photo-cull-ingest.service` — run a poll right now instead of waiting.
- `/mnt/passport/AICullInbox/` accumulates one TSV per shoot over time; each is independently
  applicable (or you can regenerate a single combined TSV any time with
  `photo_cull.py export --plugin-data ... --db trial_out/trial.db`, no `--folder`).

## Why polling instead of inotify

Recursive `inotifywait` on a big passport-drive tree is expensive and fragile across mounts/
unmounts. A 15-minute poll plus a 15-minute stability window is cheap (nothing to do if no
folder's newest file changed) and tolerant of the drive being unplugged between imports.
