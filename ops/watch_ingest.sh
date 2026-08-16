#!/usr/bin/env bash
# Ingest watcher: poll for new/updated shoot folders under $LIBRARY_ROOT, cull them, and export a
# plugin-data TSV to $INBOX -- a folder on the passport drive itself, which the Mac already
# mounts (as /Volumes/Passport), so no network push is needed. The Lightroom plugin's file
# picker defaults there; applying it is still a manual click (Library -> Plug-in Extras -> Sync
# AI Cull Data...).
#
# Run periodically by the `photo-cull-ingest.timer` systemd --user unit (see ops/README.md).
# Safe to run concurrently with a manual `photo_cull.py run` -- both just resume the same DB.
set -uo pipefail

PROJ=/home/danny/photo-culling
DB="$PROJ/trial_out/trial.db"
LIBRARY_ROOT=/mnt/passport/Pictures           # read-only guest mount -- fine, we only read here
INBOX=/mnt/Passport_Writeable/AICullInbox     # rw mount of the same share; = /Volumes/Passport/AICullInbox on the Mac
MARKERS="$PROJ/trial_out/ingest_markers"      # one file per shoot folder we've synced
LOG="$PROJ/trial_out/ingest_watch.log"
STABLE_MINUTES=15                             # a folder must be quiet this long before we touch it

mkdir -p "$MARKERS" "$INBOX"
cd "$PROJ" || exit 1
log() { echo "[$(date -Is)] $*" >> "$LOG"; }

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

    tsv="$INBOX/${name}.tsv"
    if ! ./venv/bin/python photo_cull.py export --plugin-data "$tsv" --folder "$folder" \
            --db "$DB" --csv "$PROJ/trial_out/report.csv" >> "$LOG" 2>&1; then
        log "export FAILED for $folder -- leaving unmarked, will retry next poll"
        continue
    fi

    echo "$newest" > "$marker"
    log "done: $folder -> $tsv"
done
