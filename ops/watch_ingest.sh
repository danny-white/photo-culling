#!/usr/bin/env bash
# Ingest watcher: poll for new/updated shoot folders under $LIBRARY_ROOT, cull them, and export a
# plugin-data TSV to $INBOX -- a folder on the passport drive itself, which the Mac already
# mounts (as /Volumes/Passport/AICullInbox), so no network push is needed. The Lightroom plugin's
# file picker defaults there; applying it is still a manual click (Library -> Plug-in Extras ->
# Sync AI Cull Data...).
#
# All shoots processed since the last applied sync accumulate into one $INBOX/pending.tsv (merged
# by shoot-folder+filename, not overwritten) -- one Lightroom sync catches up everything instead
# of clicking through one TSV per shoot. The plugin moves pending.tsv to applied/ once a full,
# uncanceled sync finishes, so the next poll after that starts a fresh pending.tsv.
#
# $INBOX is mounted as its OWN narrow CIFS mount (//mycloud/Passport/AICullInbox), not the
# share root -- Pictures/ is structurally unreachable through it, so a bug here can't touch the
# actual library. $LIBRARY_ROOT is a separate, read-only guest mount, used only for scanning.
#
# Run periodically by the `photo-cull-ingest.timer` systemd --user unit (see ops/README.md).
# Safe to run concurrently with a manual `photo_cull.py run` -- both just resume the same DB.
set -uo pipefail

PROJ=/home/danny/photo-culling
DB="$PROJ/trial_out/trial.db"
LIBRARY_ROOT=/mnt/passport/Pictures           # read-only guest mount -- fine, we only read here
INBOX=/mnt/Passport_AICullInbox               # narrow rw mount, scoped to just this subfolder
MARKERS="$PROJ/trial_out/ingest_markers"      # one file per shoot folder we've synced
LOG="$PROJ/trial_out/ingest_watch.log"
STABLE_MINUTES=15                             # a folder must be quiet this long before we touch it
NOTIFY_EMAIL=97danny.white@gmail.com          # emailed via msmtp (~/.msmtprc) when a batch drains to 0

mkdir -p "$MARKERS"
cd "$PROJ" || exit 1
log() { echo "[$(date -Is)] $*" >> "$LOG"; }

# $INBOX is a transient CIFS mount (no fstab entry) -- it will NOT come back after a reboot on
# its own. If it's not actually mounted, bail loudly instead of silently writing TSVs into an
# empty local directory that the Mac never sees.
if ! mountpoint -q "$INBOX"; then
    log "ABORT: $INBOX is not mounted -- re-run the mount command and retry."
    exit 1
fi
if ! grep -q "^//mycloud/Passport/AICullInbox " /proc/mounts; then
    log "ABORT: $INBOX is mounted but not to the expected share path -- refusing to write."
    exit 1
fi

# Snapshot before/after this invocation's work, purely from DB status -- lets us detect "the
# queue just fully drained" (steady-state: idle at 0, a new import bumps pending>0, this
# eventually brings it back to 0) regardless of how many 15-min poll cycles it took, and
# regardless of whether this script or a separate manual run did the actual processing.
pending_before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM images WHERE status='pending'" 2>/dev/null || echo 0)
ok_before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM images WHERE status='ok'" 2>/dev/null || echo 0)

shopt -s nullglob
# Scoped to YYYY/YYYY-MM-DD -- the date-organized library only. $LIBRARY_ROOT also has other
# top-level folders (screenshots, $RECYCLE.BIN, one-off trip dumps, ...) that are NOT meant to
# be auto-culled; a bare */*/ glob would silently wander into those.
for folder in "$LIBRARY_ROOT"/[0-9][0-9][0-9][0-9]/*/; do
    folder="${folder%/}"
    name="$(basename "$folder")"
    marker="$MARKERS/$name.done"

    # Stability: skip if anything in the folder changed more recently than STABLE_MINUTES ago
    # (avoids culling a shoot mid-copy).
    if find "$folder" -newermt "-${STABLE_MINUTES} minutes" -type f -print -quit | grep -q .; then
        continue
    fi

    newest="$(find "$folder" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
    [ -z "$newest" ] && continue  # empty folder

    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$newest" ]; then
        continue  # already culled + exported at this folder state
    fi

    log "processing $folder"
    if ! ./venv/bin/python photo_cull.py run "$folder" --db "$DB" >> "$LOG" 2>&1; then
        log "run FAILED for $folder -- leaving unmarked, will retry next poll"
        continue
    fi

    # Best-effort semantic-search indexing. Not fatal -- the shoot still exports/marks done even
    # if this fails (e.g. the embedding model isn't loaded); a later `embed` backfill catches it.
    if ! ./venv/bin/python photo_cull.py embed --db "$DB" --folder "$folder" >> "$LOG" 2>&1; then
        log "embed FAILED for $folder (non-fatal, continuing)"
    fi

    # Best-effort picture embeddings (CLIP, CPU), for Culling Bay's More like this and searches
    # by what is in a picture. Not fatal; `embed-images` with no --folder backfills.
    if ! ./venv/bin/python photo_cull.py embed-images --db "$DB" --folder "$folder" >> "$LOG" 2>&1; then
        log "embed-images FAILED for $folder (non-fatal, continuing)"
    fi

    # Best-effort GPS + nearest town, for Culling Bay Mobile's places. Not fatal either.
    if ! ./venv/bin/python photo_cull.py geotag --db "$DB" --folder "$folder" >> "$LOG" 2>&1; then
        log "geotag FAILED for $folder (non-fatal, continuing)"
    fi

    # Best-effort drive mode, sequence and AF point from the camera's tags, for Culling Bay's
    # exact bursts and brackets and its focus check. Not fatal either.
    if ! ./venv/bin/python photo_cull.py shotinfo --db "$DB" --folder "$folder" >> "$LOG" 2>&1; then
        log "shotinfo FAILED for $folder (non-fatal, continuing)"
    fi

    # Best-effort two-line day summary from the annotations (local text model). Not fatal.
    if ! ./venv/bin/python photo_cull.py daysum --db "$DB" --folder "$folder" >> "$LOG" 2>&1; then
        log "daysum FAILED for $folder (non-fatal, continuing)"
    fi

    tsv="$INBOX/pending.tsv"
    if ! ./venv/bin/python photo_cull.py export --plugin-data "$tsv" --plugin-data-append --folder "$folder" \
            --db "$DB" --csv "$PROJ/trial_out/report.csv" >> "$LOG" 2>&1; then
        log "export FAILED for $folder -- leaving unmarked, will retry next poll"
        continue
    fi

    echo "$newest" > "$marker"
    log "done: $folder -> $tsv"
done

# Batch-complete notification: only fires on the exact poll that brings the queue from >0 back
# to 0 -- silent on idle polls (pending_before=0) and on in-progress polls (pending_after>0),
# whether draining took one cycle or many.
pending_after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM images WHERE status='pending'" 2>/dev/null || echo 0)
ok_after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM images WHERE status='ok'" 2>/dev/null || echo 0)
if [ "$pending_before" -gt 0 ] && [ "$pending_after" -eq 0 ]; then
    processed=$((ok_after - ok_before))
    subject="Photo cull: batch complete ($processed processed)"
    body="Batch finished. $processed image(s) processed this run; $ok_after total culled, $pending_after pending.

Ready to sync in Lightroom: Library -> Plug-in Extras -> Sync AI Cull Data..."
    if command -v msmtp >/dev/null 2>&1; then
        if printf 'Subject: %s\nTo: %s\n\n%s\n' "$subject" "$NOTIFY_EMAIL" "$body" | msmtp "$NOTIFY_EMAIL"; then
            log "sent batch-complete email ($processed processed)"
        else
            log "msmtp send FAILED (check ~/.msmtprc and ~/.msmtp.log) -- batch WAS complete ($processed processed)"
        fi
    else
        log "batch complete ($processed processed) but msmtp isn't installed -- no email sent"
    fi
fi
