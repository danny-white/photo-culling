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
#
# A folder is finished when its marker holds its current signature
# ("v2 <dir mtime> <newest file mtime> <file count>") AND nothing in it is pending or still worth
# retrying. A folder is looked at again when its signature changes (files copied in late move the
# folder's own mtime, even if the files keep their camera dates) or while it has failed photos
# that have tries left (one try per poll, `photo_cull.py` MAX_ATTEMPTS in all).
#
# Every setting below can be overridden from the environment; the defaults are the live paths.
# That is how review/tests/test_watch_ingest.py runs this script against a temp library. Try a
# change with DRY_RUN=1: it logs what it would do and runs no step and writes no marker.
set -uo pipefail

PROJ=${PROJ:-/home/danny/photo-culling}
DB=${DB:-$PROJ/trial_out/trial.db}
LIBRARY_ROOT=${LIBRARY_ROOT:-/mnt/passport/Pictures}   # read-only guest mount -- fine, we only read here
LIBRARY_ROOT=${LIBRARY_ROOT%/}
INBOX=${INBOX:-/mnt/Passport_AICullInbox}              # narrow rw mount, scoped to just this subfolder
INBOX_SOURCE=${INBOX_SOURCE:-//mycloud/Passport/AICullInbox}   # what /proc/mounts must say it is
MARKERS=${MARKERS:-$PROJ/trial_out/ingest_markers}     # one file per shoot folder we've synced
LOG=${LOG:-$PROJ/trial_out/ingest_watch.log}
PY=${PY:-./venv/bin/python}                            # run from $PROJ, so this is the venv's Python
CHECK_MOUNT=${CHECK_MOUNT:-1}                          # 0 skips both mount guards: for tests only
STABLE_MINUTES=${STABLE_MINUTES:-15}                   # a folder must be quiet this long before we touch it
NOTIFY_EMAIL=${NOTIFY_EMAIL:-97danny.white@gmail.com}  # emailed via msmtp (~/.msmtprc) when a batch drains to 0
DRY_RUN=${DRY_RUN:-0}                                  # 1: log what would happen, run nothing, write nothing

[ "$DRY_RUN" = 1 ] || mkdir -p "$MARKERS"
cd "$PROJ" || exit 1
log() {
    local line
    line="[$(date -Is)] $*"
    echo "$line" >> "$LOG"
    if [ "$DRY_RUN" = 1 ]; then echo "$line"; fi
}

# $INBOX is a mount from /etc/fstab (nofail,_netdev, so a reboot never waits on it), but it can
# still be missing when the NAS or drive was off at boot. If it's not actually mounted, bail
# loudly instead of silently writing TSVs into an empty local directory that the Mac never sees.
if [ "$CHECK_MOUNT" = 1 ]; then
    if ! mountpoint -q "$INBOX"; then
        log "ABORT: $INBOX is not mounted -- re-run the mount command and retry."
        exit 1
    fi
    if ! grep -q "^${INBOX_SOURCE} " /proc/mounts; then
        log "ABORT: $INBOX is mounted but not to the expected share path -- refusing to write."
        exit 1
    fi
fi

# Snapshot before/after this invocation's work, purely from DB status -- lets us detect "the
# queue just fully drained" (steady-state: idle at 0, a new import bumps pending>0, this
# eventually brings it back to 0) regardless of how many 15-min poll cycles it took, and
# regardless of whether this script or a separate manual run did the actual processing.
pending_before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM images WHERE status='pending'" 2>/dev/null || echo 0)
ok_before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM images WHERE status='ok'" 2>/dev/null || echo 0)

# "<dir mtime> <newest file mtime> <file count>" for a folder, in epoch seconds, from one find.
# The folder's own mtime is the time files were last copied in or removed (on this CIFS mount a
# copy keeps each file's camera mtime, so the file times alone can't see a copy in progress).
# Prints nothing and fails for a folder with no files in it.
folder_signature() {
    local listing
    listing=$(find "$1" -printf '%d %y %T@\n' 2>/dev/null)
    awk '
        $1 == 0 && $2 == "d" { dirm = int($3); have = 1 }
        $2 == "f"            { n++; t = int($3); if (t > newest) newest = t }
        END { if (have && n > 0) print dirm, newest, n; else exit 1 }' <<< "$listing"
}

shopt -s nullglob
now=$(date +%s)
window=$((STABLE_MINUTES * 60))

# Folders with failed photos that have tries left, whatever their signature says. One call.
declare -A retryable=()
while IFS= read -r f; do
    [ -n "$f" ] && retryable["$f"]=1
done < <("$PY" photo_cull.py folder-state --db "$DB" --retryable-only "$LIBRARY_ROOT" 2>>"$LOG")

declare -A reason=() sig_at_scan=()
todo=()           # folders to process this poll
old_format=()     # folders whose marker is the old single number: upgrade it, or process
# Scoped to YYYY/YYYY-MM-DD -- the date-organized library only. $LIBRARY_ROOT also has other
# top-level folders (screenshots, $RECYCLE.BIN, one-off trip dumps, ...) that are NOT meant to
# be auto-culled; a bare */*/ glob would silently wander into those.
for folder in "$LIBRARY_ROOT"/[0-9][0-9][0-9][0-9]/*/; do
    folder="${folder%/}"
    marker="$MARKERS/$(basename "$folder").done"

    sig=$(folder_signature "$folder") || continue          # empty folder
    read -r dirm newest count <<< "$sig"
    # Busy: copied into, or a file written, within the last STABLE_MINUTES (avoids culling a
    # shoot mid-copy). Skipped this poll; the next one sees it again.
    if [ $((now - dirm)) -lt "$window" ] || [ $((now - newest)) -lt "$window" ]; then
        continue
    fi
    cur="v2 $sig"
    sig_at_scan["$folder"]="$cur"
    stored=$(cat "$marker" 2>/dev/null || true)

    if [ "$stored" = "$cur" ]; then
        # unchanged since it was finished; only failed photos with tries left bring it back
        [ -n "${retryable[$folder]:-}" ] && { todo+=("$folder"); reason["$folder"]="failed photos with tries left"; }
    elif [[ "$stored" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if [ -n "${retryable[$folder]:-}" ]; then
            todo+=("$folder"); reason["$folder"]="failed photos with tries left"
        elif [ "${stored%%.*}" = "$newest" ]; then
            old_format+=("$folder")                         # same newest file as when it was marked
        else
            todo+=("$folder"); reason["$folder"]="old marker, newest file changed"
        fi
    elif [ -z "$stored" ]; then
        todo+=("$folder"); reason["$folder"]="no marker"
    else
        todo+=("$folder"); reason["$folder"]="signature changed"
    fi
done

# Old markers hold only the newest file's mtime. Reprocessing every such folder would append
# all of them to the Lightroom inbox's pending.tsv again, so a folder whose marker still matches
# its newest file, whose photo count equals its rows in the DB, and with nothing pending or
# retryable, just gets its marker rewritten. Anything else is processed. One folder-state call.
if [ "${#old_format[@]}" -gt 0 ]; then
    answered=0
    while IFS=$'\t' read -r f disk rows pending retry _; do
        [ -n "${sig_at_scan[$f]:-}" ] || continue
        answered=$((answered + 1))
        if [ "$disk" = "$rows" ] && [ "$pending" = 0 ] && [ "$retry" = 0 ]; then
            if [ "$DRY_RUN" = 1 ]; then
                log "DRY RUN: would upgrade the old marker for $f without processing ($disk photos, all in the DB)"
            else
                printf '%s\n' "${sig_at_scan[$f]}" > "$MARKERS/$(basename "$f").done"
                log "marker upgraded for $f (nothing changed since it was finished)"
            fi
        else
            todo+=("$f")
            reason["$f"]="old marker, $disk photos on disk but $rows in the DB ($pending pending, $retry to retry)"
        fi
    done < <("$PY" photo_cull.py folder-state --db "$DB" "${old_format[@]}" 2>>"$LOG")
    if [ "$answered" -ne "${#old_format[@]}" ]; then
        log "old markers not checked: folder-state answered for $answered of ${#old_format[@]} folders; will try next poll"
    fi
fi

if [ "${#todo[@]}" -gt 0 ]; then
    mapfile -t todo < <(printf '%s\n' "${todo[@]}" | sort)
fi

for folder in "${todo[@]}"; do
    name="$(basename "$folder")"
    marker="$MARKERS/$name.done"

    if [ "$DRY_RUN" = 1 ]; then
        log "DRY RUN: would process $folder (${reason[$folder]})"
        continue
    fi

    # The scan can be hours old after a long backlog: look again, and take the signature as it
    # is now. A file copied in while we run changes it, so the folder comes round again.
    now=$(date +%s)
    sig=$(folder_signature "$folder") || continue
    read -r dirm newest count <<< "$sig"
    if [ $((now - dirm)) -lt "$window" ] || [ $((now - newest)) -lt "$window" ]; then
        continue
    fi
    cur="v2 $sig"

    log "processing $folder"
    "$PY" photo_cull.py run "$folder" --db "$DB" --retry-failed >> "$LOG" 2>&1
    rc=$?
    if [ "$rc" -eq 3 ]; then
        # Ollama isn't answering (see photo_cull.py EXIT_OLLAMA_DOWN). Nothing was lost and every
        # other folder would hit the same wall, so stop here; the next poll starts again.
        log "run deferred: Ollama not answering"
        break
    elif [ "$rc" -ne 0 ]; then
        log "run FAILED for $folder -- leaving unmarked, will retry next poll"
        continue
    fi

    # Best-effort semantic-search indexing. Not fatal -- the shoot still exports/marks done even
    # if this fails (e.g. the embedding model isn't loaded); a later `embed` backfill catches it.
    if ! "$PY" photo_cull.py embed --db "$DB" --folder "$folder" >> "$LOG" 2>&1; then
        log "embed FAILED for $folder (non-fatal, continuing)"
    fi

    # Best-effort picture embeddings (CLIP, CPU), for Culling Bay's More like this and searches
    # by what is in a picture. Not fatal; `embed-images` with no --folder backfills.
    if ! "$PY" photo_cull.py embed-images --db "$DB" --folder "$folder" >> "$LOG" 2>&1; then
        log "embed-images FAILED for $folder (non-fatal, continuing)"
    fi

    # Best-effort GPS + nearest town, for Culling Bay Mobile's places. Not fatal either.
    if ! "$PY" photo_cull.py geotag --db "$DB" --folder "$folder" >> "$LOG" 2>&1; then
        log "geotag FAILED for $folder (non-fatal, continuing)"
    fi

    # Best-effort drive mode, sequence and AF point from the camera's tags, for Culling Bay's
    # exact bursts and brackets and its focus check. Not fatal either.
    if ! "$PY" photo_cull.py shotinfo --db "$DB" --folder "$folder" >> "$LOG" 2>&1; then
        log "shotinfo FAILED for $folder (non-fatal, continuing)"
    fi

    # Best-effort two-line day summary from the annotations (local text model). Not fatal.
    if ! "$PY" photo_cull.py daysum --db "$DB" --folder "$folder" >> "$LOG" 2>&1; then
        log "daysum FAILED for $folder (non-fatal, continuing)"
    fi

    # Best-effort phone previews (320 px thumbnail, 1616 px view) into review/cache on this PC, so
    # the phone's grids never wait on the NAS. Not fatal; review/previews.py with no --folder backfills.
    if ! "$PY" review/previews.py --db "$DB" --folder "$folder" --workers 4 >> "$LOG" 2>&1; then
        log "previews FAILED for $folder (non-fatal, continuing)"
    fi

    tsv="$INBOX/pending.tsv"
    if ! "$PY" photo_cull.py export --plugin-data "$tsv" --plugin-data-append --folder "$folder" \
            --db "$DB" --csv "$PROJ/trial_out/report.csv" >> "$LOG" 2>&1; then
        log "export FAILED for $folder -- leaving unmarked, will retry next poll"
        continue
    fi

    # Finished only when nothing here is pending and nothing failed that has tries left. Empty
    # files and photos that used all their tries are "unreadable": they don't hold the marker back.
    state=$("$PY" photo_cull.py folder-state --db "$DB" "$folder" 2>>"$LOG")
    IFS=$'\t' read -r _ disk rows pending retry unreadable <<< "$state"
    if [ -z "${retry:-}" ]; then
        log "retry pending for $folder: could not read the folder's state; will look again next poll"
    elif [ "$pending" -eq 0 ] && [ "$retry" -eq 0 ]; then
        printf '%s\n' "$cur" > "$marker"
        log "done: $folder -> $tsv"
    else
        log "retry pending for $folder: $((pending + retry)) photos"
    fi
done

# Batch-complete notification: only fires on the exact poll that brings the queue from >0 back
# to 0 -- silent on idle polls (pending_before=0) and on in-progress polls (pending_after>0),
# whether draining took one cycle or many.
pending_after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM images WHERE status='pending'" 2>/dev/null || echo 0)
ok_after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM images WHERE status='ok'" 2>/dev/null || echo 0)
if [ "$DRY_RUN" != 1 ] && [ "$pending_before" -gt 0 ] && [ "$pending_after" -eq 0 ]; then
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
