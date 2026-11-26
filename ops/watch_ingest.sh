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
# ("v2 <dir mtime> <newest photo mtime> <photo count> <photo bytes>") AND nothing in it is pending
# or still worth retrying. "Photo" means a file photo_cull.py would register (its ALL_EXTENSIONS, any case,
# no dotfiles): a .DS_Store, an AppleDouble ._ file, a Lightroom .xmp sidecar or a video appearing
# must not send a finished folder back to Lightroom. A folder is looked at again when a photo has
# come or gone or the newest photo changed (files copied in late keep their camera dates, but a
# new one still changes the count), or while it has failed photos that have tries left (one try
# per poll, `photo_cull.py` MAX_ATTEMPTS in all). The byte total catches a photo replaced by a
# different file of the same name and camera date. If only the folder's own mtime moved, the
# marker is rewritten and nothing is processed. Busy is wider: the folder's mtime or ANY file's mtime
# within STABLE_MINUTES, since a copy in progress can show up as any file.
#
# An idle poll looks at each folder's own mtime only (one stat call for all of them) and takes the
# full signature, which needs a find over the folder, just for folders whose mtime differs from
# their marker's, folders with no marker or an old-format one, and folders with failed photos to
# retry. Once every 24 hours ($MARKERS/.last-full-scan) it takes every folder's signature, which
# catches a photo rewritten in place. It logs one "poll: ..." line at least once an hour (the
# health check reads it to see the watcher is alive), and one email when a poll finishes folders
# and leaves nothing pending.
#
# A visit whose only reason is failed photos to retry (the photos themselves unchanged) is a
# "retry-only" visit: it runs `run --retry-failed` and, only if at least one photo became ok, the
# follow-up steps and the export. Otherwise the folder isn't sent to Lightroom again. A visit for
# a new or changed folder always does everything. A folder left unfinished by a visit keeps a
# "<shoot>.visited" file with the signature that visit handled, so the next visit can tell.
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
NOTIFY_EMAIL=${NOTIFY_EMAIL:-97danny.white@gmail.com}  # emailed via msmtp (~/.msmtprc) when a poll finishes folders
DRY_RUN=${DRY_RUN:-0}                                  # 1: log what would happen, run nothing, write nothing

FULL_SCAN_EVERY=$((24 * 3600))   # seconds between passes that take every folder's signature
HEARTBEAT_EVERY=3600             # seconds between "poll:" lines on a poll that processed nothing
SECONDS=0

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

# How many photos are done before this poll's work, for the email's "processed" count.
ok_before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM images WHERE status='ok'" 2>/dev/null || echo 0)

# The extensions a run registers, from photo_cull.py itself so the two can't drift apart. The
# folder signature counts only these. Without them no signature can be taken, so stop.
EXTS=$("$PY" photo_cull.py folder-state --print-extensions 2>>"$LOG" | tr '\n' ' ')
if [ -z "${EXTS// /}" ]; then
    log "poll skipped: could not read the photo extensions from photo_cull.py"
    exit 1
fi

# "<dir mtime> <newest photo mtime> <photo count> <newest mtime of any file> <photo bytes>" for a
# folder (times in epoch seconds), from one find. A photo is a file photo_cull.py registers (see EXTS). The folder's
# own mtime is the time files were last copied in or removed (on this CIFS mount a copy keeps each
# file's camera mtime, so the file times alone can't see a copy in progress). The last number
# covers every file: it is for the busy test, and for old markers, which held that number.
# Fails (prints nothing) only if the folder itself can't be read; a folder with no photos gives 0 0.
folder_signature() {
    local listing
    listing=$(find "$1" -printf '%d\t%Y\t%T@\t%s\t%f\n' 2>/dev/null)
    awk -F'\t' -v exts="$EXTS" '
        BEGIN { n = split(exts, e, " "); for (i = 1; i <= n; i++) ok[e[i]] = 1 }
        $1 == 0 && $2 == "d" { dirm = int($3); have = 1 }
        $2 == "f" {
            t = int($3); if (t > anynewest) anynewest = t
            name = $5; for (i = 6; i <= NF; i++) name = name "\t" $i
            if (substr(name, 1, 1) != "." && match(name, /\.[^.]*$/) && (tolower(substr(name, RSTART)) in ok)) {
                photos++; bytes += $4; if (t > newest) newest = t
            }
        }
        END { if (have) printf "%.0f %.0f %.0f %.0f %.0f\n", dirm, newest, photos, anynewest, bytes; else exit 1 }' <<< "$listing"
}

shopt -s nullglob
now=$(date +%s)
window=$((STABLE_MINUTES * 60))

# Is it time for the daily pass that takes every folder's signature?
full_scan=0
if [ ! -e "$MARKERS/.last-full-scan" ] || [ $((now - $(stat -c %Y "$MARKERS/.last-full-scan"))) -ge "$FULL_SCAN_EVERY" ]; then
    full_scan=1
fi

# Folders with failed photos that have tries left, whatever their signature says. One call.
declare -A retryable=()
while IFS= read -r f; do
    [ -n "$f" ] && retryable["$f"]=1
done < <("$PY" photo_cull.py folder-state --db "$DB" --retryable-only "$LIBRARY_ROOT" 2>>"$LOG")

declare -A reason=() sig_at_scan=() retry_only=()
todo=()           # folders to process this poll
# queue FOLDER WHY [retry]: process FOLDER this poll. "retry" says its photos are unchanged, so
# the visit is only about failed photos that have tries left.
queue() {
    todo+=("$1"); reason["$1"]="$2"
    if [ "${3:-}" = retry ]; then retry_only["$1"]=1; fi
}
old_format=()     # folders whose marker is the old single number: upgrade it, or process
# Scoped to YYYY/YYYY-MM-DD -- the date-organized library only. $LIBRARY_ROOT also has other
# top-level folders (screenshots, $RECYCLE.BIN, one-off trip dumps, ...) that are NOT meant to
# be auto-culled; a bare */*/ glob would silently wander into those.
folders=("$LIBRARY_ROOT"/[0-9][0-9][0-9][0-9]/*/)
folders=("${folders[@]%/}")
# Every folder's own mtime, in one stat call: all an unchanged folder costs.
declare -A dir_mtime=()
if [ "${#folders[@]}" -gt 0 ]; then
    while IFS=$'\t' read -r t f; do
        dir_mtime["$f"]=$t
    done < <(stat --printf '%Y\t%n\n' -- "${folders[@]}" 2>/dev/null)
fi
n_folders=${#folders[@]}
n_changed=0       # folders that differ from their marker, or have no usable one
n_processed=0     # folders `run` was started for
for folder in "${folders[@]}"; do
    marker="$MARKERS/$(basename "$folder").done"
    stored=""
    [ -f "$marker" ] && { IFS= read -r stored < "$marker" || true; }
    d="${dir_mtime[$folder]:-}"
    [ -n "$d" ] || continue                                 # could not stat it

    # Unchanged since it was finished: same folder mtime as its v2 marker, nothing to retry. Skip
    # it without a find or a Python call, except on the daily full pass.
    flagged=1
    if [[ "$stored" =~ ^v2\ ([0-9]+)\  ]] && [ "${BASH_REMATCH[1]}" = "$d" ] && [ -z "${retryable[$folder]:-}" ]; then
        flagged=0
    fi
    if [ "$flagged" = 0 ] && [ "$full_scan" = 0 ]; then
        continue
    fi
    [ "$flagged" = 1 ] && n_changed=$((n_changed + 1))

    sig=$(folder_signature "$folder") || continue          # could not read it
    read -r dirm newest count anynewest bytes <<< "$sig"
    # Busy: copied into, or any file written, within the last STABLE_MINUTES (avoids culling a
    # shoot mid-copy). Skipped this poll; the next one sees it again.
    if [ $((now - dirm)) -lt "$window" ] || [ $((now - anynewest)) -lt "$window" ]; then
        continue
    fi
    cur="v2 $dirm $newest $count $bytes"
    if [ "$count" -eq 0 ]; then
        # No photos here (empty, or only sidecars and videos): nothing to ingest. Note the folder's
        # mtime so later polls skip it by a stat, as they do any other finished folder.
        if [ "$stored" != "$cur" ] && [ "$DRY_RUN" != 1 ]; then printf '%s\n' "$cur" > "$marker"; fi
        if [ -n "${retryable[$folder]:-}" ]; then   # rows left from files that are gone: let them run out
            queue "$folder" "failed photos with tries left" retry
        fi
        continue
    fi
    sig_at_scan["$folder"]="$cur"
    # a change only the daily full pass could find (a photo rewritten without moving the folder's mtime)
    if [ "$flagged" = 0 ] && [ "$stored" != "$cur" ]; then n_changed=$((n_changed + 1)); fi

    # The signature the last visit handled, if it left the folder unfinished (see the header).
    visited=""
    [ -f "$MARKERS/$(basename "$folder").visited" ] && { IFS= read -r visited < "$MARKERS/$(basename "$folder").visited" || true; }

    if [ "$stored" = "$cur" ]; then
        # unchanged since it was finished; only failed photos with tries left bring it back
        [ -n "${retryable[$folder]:-}" ] && queue "$folder" "failed photos with tries left" retry
    elif [[ "$stored" =~ ^v2\ [0-9]+\ ${newest}\ ${count}\ ${bytes}$ ]]; then
        # Same photos, same newest photo; only the folder's own mtime moved (a .DS_Store, a
        # sidecar, a video, something written and removed). Nothing to ingest: note the new mtime.
        if [ "$DRY_RUN" = 1 ]; then
            log "DRY RUN: would refresh the marker for $folder (only the folder's own mtime moved)"
        else
            printf '%s\n' "$cur" > "$marker"
        fi
        [ -n "${retryable[$folder]:-}" ] && queue "$folder" "failed photos with tries left" retry
    elif [[ "$stored" =~ ^v2\ [0-9]+\ ${newest}\ ${count}$ ]]; then
        # A marker from before the byte total was added, naming the same photos: add it, process nothing.
        if [ "$DRY_RUN" = 1 ]; then
            log "DRY RUN: would add the byte total to the marker for $folder (nothing else changed)"
        else
            printf '%s\n' "$cur" > "$marker"
        fi
        [ -n "${retryable[$folder]:-}" ] && queue "$folder" "failed photos with tries left" retry
    elif [[ "$stored" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if [ "${stored%%.*}" = "$anynewest" ] || [ "${stored%%.*}" = "$newest" ]; then
            # The number is the newest file when it was marked: still the newest file, or the newest
            # photo with only non-photos (sidecars, videos) newer since. Photos: see the count below.
            old_format+=("$folder")
        else
            queue "$folder" "old marker, newest file changed"
        fi
    elif [[ "$visited" =~ ^v2\ [0-9]+\ ${newest}\ ${count}\ ${bytes}$ ]]; then
        # An earlier visit handled these very photos and left some failed: only those need another try.
        queue "$folder" "photos unchanged since the last visit; failed photos with tries left" retry
    elif [ -z "$stored" ]; then
        queue "$folder" "no marker"
    else
        queue "$folder" "signature changed"
    fi
done

if [ "$full_scan" = 1 ] && [ "$DRY_RUN" != 1 ]; then
    touch "$MARKERS/.last-full-scan"
fi

# Old markers hold only the newest file's mtime. Reprocessing every such folder would append
# all of them to the Lightroom inbox's pending.tsv again, so a folder whose marker still matches
# its newest file, whose photo count equals its rows in the DB, and with nothing pending or
# retryable, just gets its marker rewritten. If only failed photos with tries left stand in the way
# (nothing pending, counts equal) the visit is retry-only; anything else is processed in full. One
# folder-state call.
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
        elif [ "$disk" = "$rows" ] && [ "$pending" = 0 ]; then
            queue "$f" "old marker still matches; failed photos with tries left" retry
        else
            queue "$f" "old marker, $disk photos on disk but $rows in the DB ($pending pending, $retry to retry)"
        fi
    done < <("$PY" photo_cull.py folder-state --db "$DB" "${old_format[@]}" 2>>"$LOG")
    if [ "$answered" -ne "${#old_format[@]}" ]; then
        log "old markers not checked: folder-state answered for $answered of ${#old_format[@]} folders; will try next poll"
    fi
fi

if [ "${#todo[@]}" -gt 0 ]; then
    mapfile -t todo < <(printf '%s\n' "${todo[@]}" | sort)
fi

done_folders=()        # folders finished (marker written) this poll
batch_retry=0          # photos still pending or waiting for a retry, in folders this poll processed
batch_unreadable=0     # originals that can't be read, in folders this poll processed
tsv="$INBOX/pending.tsv"

# read_state FOLDER: the folder's counts from photo_cull's folder-state, in st_disk, st_rows,
# st_pending, st_retry and st_unreadable. Fails if they can't be read.
read_state() {
    local line
    line=$("$PY" photo_cull.py folder-state --db "$DB" "$1" 2>>"$LOG") || return 1
    IFS=$'\t' read -r _ st_disk st_rows st_pending st_retry st_unreadable <<< "$line"
    [ -n "${st_unreadable:-}" ]
}

# settle NOTE: after a visit, with the counts in st_*. Finished only when nothing is pending and
# nothing failed that has tries left: the marker is written and the folder logged as done. Empty
# files and photos that used all their tries ("unreadable") don't hold it back. Otherwise the
# folder stays unmarked, with the signature this visit handled kept in <shoot>.visited.
settle() {
    batch_retry=$((batch_retry + st_pending + st_retry))
    batch_unreadable=$((batch_unreadable + st_unreadable))
    if [ "$st_pending" -eq 0 ] && [ "$st_retry" -eq 0 ]; then
        printf '%s\n' "$cur" > "$marker"
        rm -f "$MARKERS/$name.visited"
        done_folders+=("$name")
        log "done: $folder -> $tsv"
    else
        printf '%s\n' "$cur" > "$MARKERS/$name.visited"
        log "retry pending for $folder: $((st_pending + st_retry)) photos$1"
    fi
}

for folder in "${todo[@]}"; do
    name="$(basename "$folder")"
    marker="$MARKERS/$name.done"

    if [ "$DRY_RUN" = 1 ]; then
        if [ -n "${retry_only[$folder]:-}" ]; then
            log "DRY RUN: would process $folder (${reason[$folder]}): retry-only visit, steps and export only if a photo is recovered"
        else
            log "DRY RUN: would process $folder (${reason[$folder]}): full visit, steps and export"
        fi
        continue
    fi

    # The scan can be hours old after a long backlog: look again, and take the signature as it
    # is now. A file copied in while we run changes it, so the folder comes round again.
    now=$(date +%s)
    sig=$(folder_signature "$folder") || continue
    read -r dirm newest count anynewest bytes <<< "$sig"
    if [ $((now - dirm)) -lt "$window" ] || [ $((now - anynewest)) -lt "$window" ]; then
        continue
    fi
    cur="v2 $dirm $newest $count $bytes"

    log "processing $folder"
    n_processed=$((n_processed + 1))
    # A retry-only visit: how many photos are ok now, to tell afterwards whether any recovered.
    retry_visit=0
    if [ -n "${retry_only[$folder]:-}" ] && read_state "$folder"; then
        retry_visit=1
        ok_pre=$((st_rows - st_pending - st_retry - st_unreadable))
    fi
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

    # Retry-only visit and no photo became ok: nothing new to index or send to Lightroom.
    if [ "$retry_visit" = 1 ] && read_state "$folder" \
            && [ $((st_rows - st_pending - st_retry - st_unreadable)) -le "$ok_pre" ]; then
        settle " (none recovered this time)"
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

    # Best-effort face finding (SCRFD + ArcFace, CPU), so a later phase can group faces into people.
    # Not fatal; `faces` with no --folder backfills.
    if ! "$PY" photo_cull.py faces --db "$DB" --folder "$folder" >> "$LOG" 2>&1; then
        log "faces FAILED for $folder (non-fatal, continuing)"
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

    if ! "$PY" photo_cull.py export --plugin-data "$tsv" --plugin-data-append --folder "$folder" \
            --db "$DB" --csv "$PROJ/trial_out/report.csv" >> "$LOG" 2>&1; then
        log "export FAILED for $folder -- leaving unmarked, will retry next poll"
        continue
    fi

    if read_state "$folder"; then
        settle ""
    else
        log "retry pending for $folder: could not read the folder's state; will look again next poll"
    fi
done

# Batch-complete email: one per poll that finished at least one folder and left nothing pending
# in the DB (a poll that stopped early, with Ollama down, leaves rows pending and stays silent; the
# poll that finishes the batch sends it). Idle polls send nothing.
if [ "$DRY_RUN" != 1 ] && [ "${#done_folders[@]}" -gt 0 ]; then
    pending_after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM images WHERE status='pending'" 2>/dev/null || echo 0)
    ok_after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM images WHERE status='ok'" 2>/dev/null || echo 0)
    if [ "$pending_after" -eq 0 ]; then
        processed=$((ok_after - ok_before))
        [ "$processed" -ge 0 ] || processed=0
        listed=$(printf '  %s\n' "${done_folders[@]:0:20}")
        [ "${#done_folders[@]}" -le 20 ] || listed+=$'\n'"  ... and $((${#done_folders[@]} - 20)) more"
        subject="Photo cull: batch complete ($processed processed)"
        body="Batch finished: ${#done_folders[@]} folder(s) done, $processed photo(s) processed this run; $ok_after culled in all, $pending_after pending.

Folders done:
$listed

Photos waiting for a retry: $batch_retry (the watcher tries again every 15 minutes, up to 4 tries each)
Originals that can't be read: $batch_unreadable (empty or damaged files; see the pipeline health page)

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
fi

# Heartbeat: one line, at most once an hour and always when something was processed, so the log
# (and the health check reading it) shows the watcher is alive on idle polls too.
if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN: poll: $n_folders folders, $n_changed changed, ${#todo[@]} to process, ${SECONDS}s"
else
    beat="$MARKERS/.last-heartbeat"
    if [ "$n_processed" -gt 0 ] || [ ! -e "$beat" ] || [ $(($(date +%s) - $(stat -c %Y "$beat"))) -ge "$HEARTBEAT_EVERY" ]; then
        log "poll: $n_folders folders, $n_changed changed, $n_processed processed, ${SECONDS}s"
        touch "$beat"
    fi
fi
