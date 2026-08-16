#!/usr/bin/env bash
# Ingest watcher: poll for new/updated shoot folders under $LIBRARY_ROOT, cull them, export a
# plugin-data TSV, and push it to the Mac's AI-Cull inbox so the Lightroom plugin can apply it
# with one click (Library -> Plug-in Extras -> Sync AI Cull Data...).
#
# Run periodically by the `photo-cull-ingest.timer` systemd --user unit (see ops/README.md).
# Safe to run concurrently with a manual `photo_cull.py run` -- both just resume the same DB.
set -uo pipefail

PROJ=/home/danny/photo-culling
DB="$PROJ/trial_out/trial.db"
LIBRARY_ROOT=/mnt/passport/Pictures
MARKERS="$PROJ/trial_out/ingest_markers"     # one file per shoot folder we've synced
LOG="$PROJ/trial_out/ingest_watch.log"
STABLE_MINUTES=15                             # a folder must be quiet this long before we touch it

# --- fill these in for your setup ---
MAC_HOST="CHANGEME.local"                     # e.g. dannys-mbp.local, or a LAN IP
MAC_INBOX="AICullInbox"                       # relative to the Mac user's home dir
# -------------------------------------

mkdir -p "$MARKERS"
cd "$PROJ" || exit 1
log() { echo "[$(date -Is)] $*" >> "$LOG"; }

shopt -s nullglob
for folder in "$LIBRARY_ROOT"/*/*/; do
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
        continue  # already culled + synced at this folder state
    fi

    log "processing $folder"
    if ! ./venv/bin/python photo_cull.py run "$folder" --db "$DB" >> "$LOG" 2>&1; then
        log "run FAILED for $folder -- leaving unmarked, will retry next poll"
        continue
    fi

    tsv="$PROJ/trial_out/ingest_tsv/${name}.tsv"
    mkdir -p "$(dirname "$tsv")"
    if ! ./venv/bin/python photo_cull.py export --plugin-data "$tsv" --folder "$folder" \
            --db "$DB" --csv "$PROJ/trial_out/report.csv" >> "$LOG" 2>&1; then
        log "export FAILED for $folder -- leaving unmarked, will retry next poll"
        continue
    fi

    if [ "$MAC_HOST" = "CHANGEME.local" ]; then
        log "MAC_HOST not configured -- skipping scp push, TSV left at $tsv"
    elif scp -q "$tsv" "$MAC_HOST:$MAC_INBOX/" >> "$LOG" 2>&1; then
        log "pushed $tsv -> $MAC_HOST:$MAC_INBOX/"
    else
        log "scp push FAILED for $tsv -- leaving unmarked, will retry next poll"
        continue
    fi

    echo "$newest" > "$marker"
    log "done: $folder"
done
