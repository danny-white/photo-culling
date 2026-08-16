# Ingest automation

Watches `/mnt/passport/Pictures/*/*` for new shoot folders, culls any that have gone quiet for
15+ minutes (avoids grabbing a still-copying import), exports a plugin-data TSV scoped to that
shoot, and pushes it to the Mac over `scp`. Applying it in Lightroom is still a manual click —
see [`lightroom-plugin/README.md`](../lightroom-plugin/README.md) — this only automates the
"run the AI + get the data to the Mac" half.

## One-time setup

1. **Edit `watch_ingest.sh`** and set `MAC_HOST` (e.g. `dannys-mbp.local`, or a LAN IP) and
   `MAC_INBOX` (a folder in the Mac user's home dir — matches the plugin's default file-picker
   location, `~/AICullInbox`). Until `MAC_HOST` is set, the watcher still culls and exports but
   just leaves the TSV in `trial_out/ingest_tsv/` instead of pushing it.
2. **Passwordless SSH to the Mac**, since this runs unattended:
   ```bash
   ssh-copy-id danny@MAC_HOST   # or however you reach it
   ```
3. On the Mac, create the inbox folder once: `mkdir -p ~/AICullInbox`.
4. **Install the systemd units:**
   ```bash
   ln -s /home/danny/photo-culling/ops/photo-cull-ingest.service ~/.config/systemd/user/
   ln -s /home/danny/photo-culling/ops/photo-cull-ingest.timer ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now photo-cull-ingest.timer
   ```

## Operating it

- `journalctl --user -u photo-cull-ingest.service -f` — watch it fire.
- `tail -f trial_out/ingest_watch.log` — the watcher's own log (what it culled/pushed/skipped).
- `trial_out/ingest_markers/<shoot>.done` — one marker per synced shoot folder, storing the
  folder's newest-file mtime at last sync. Delete a marker (or touch a new file into that shoot)
  to force a re-cull + re-export on the next poll.
- `systemctl --user start photo-cull-ingest.service` — run a poll right now instead of waiting.

## Why polling instead of inotify

Recursive `inotifywait` on a big passport-drive tree is expensive and fragile across mounts/
unmounts. A 15-minute poll plus a 15-minute stability window is cheap (nothing to do if no
folder's newest file changed) and tolerant of the drive being unplugged between imports.
