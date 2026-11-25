#!/usr/bin/env bash
# Daily backup of Culling Bay's irreplaceable state to the NAS, then a push of the code to GitHub.
# Run by culling-bay-backup.timer (see ops/README.md, "Backups"). Safe to run by hand.
#
# What goes to $DEST/<YYYY-MM-DD>/ (the newest $KEEP days are kept):
#   annotations.db  every phone decision and the Practice progress
#   trial.db        the photo index (weeks of GPU tagging)
#   state.tar.gz    the small files that cannot be rebuilt cheaply: trial_out/mobile (practice.json,
#                   pano.json), ingest_markers, known-unreadable.txt, the eval labels and audits,
#                   and the systemd units (those in ops/ and what ~/.config/systemd/user/ holds)
# Both databases are WAL databases that the server writes to while this runs, so they are copied
# with SQLite's own backup (never cp) and each copy is checked with PRAGMA quick_check.
#
# Then it pushes $BRANCH to $REMOTE, after scanning the commits that would go out for secret-shaped
# text. The GitHub repo is PUBLIC, so a match skips the push and says which file, never the secret.
#
# The result goes to $STATUS (read by /m/api/pipeline-health) and one line per run to $LOG.
# Exit status: 0 when the backup itself worked (a blocked or failed push is only recorded in the
# status), non-zero when it did not.
#
# Every setting can be overridden from the environment; the tests do, with temp directories.
set -Eeuo pipefail

PROJ=${PROJ:-/home/danny/photo-culling}
DEST=${DEST:-/mnt/nas_drive/backups/culling-bay}
DEST_MOUNT=${DEST_MOUNT:-/mnt/nas_drive}
DEST_SOURCE=${DEST_SOURCE:-//mycloud/Drive}
KEEP=${KEEP:-14}
CHECK_MOUNT=${CHECK_MOUNT:-1}               # 0 is for tests only
PUSH=${PUSH:-1}
REMOTE=${REMOTE:-origin}
BRANCH=${BRANCH:-main}
STATUS=${STATUS:-$PROJ/trial_out/backup-status.json}
LOG=${LOG:-$PROJ/trial_out/backup.log}
UNIT_DIR=${UNIT_DIR:-$HOME/.config/systemd/user}   # where the live units are looked up
MOUNTS_FILE=${MOUNTS_FILE:-/proc/mounts}
MOUNT_WAIT=${MOUNT_WAIT:-120}               # seconds to wait for the share, e.g. right after a boot

TRIAL_OUT="$PROJ/trial_out"
STAGE="$TRIAL_OUT/.backup-staging"          # local scratch; the NAS only ever gets finished files
INC=""                                      # $DEST/.incoming-<stamp>, until it is renamed into place
FOLDER=""                                   # the dated folder, once it is in place
FILES_JSON="[]"
PUSH_JSON='{"ok": null, "skipped": true, "ahead_before": null, "message": "not run"}'
PUSH_MSG="not run"
LAST_OK_AT=""                               # when the last good backup finished (from the old status)
STATUS_WRITTEN=0
LAST_LINE=0

log() { echo "[$(date -Is)] $*" >> "$LOG" 2>/dev/null || true; }

# A JSON string from any text: one line, printable ASCII only, quotes and backslashes escaped.
json_str() {
    local s=$1
    s=${s//$'\n'/ }; s=${s//$'\r'/ }; s=${s//$'\t'/ }
    s=$(printf '%s' "$s" | LC_ALL=C tr -cd ' -~')
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    printf '"%s"' "$s"
}
json_or_null() { if [ -n "$1" ]; then json_str "$1"; else printf 'null'; fi; }

# write_status true|false [error]: $STATUS is replaced in one rename, so a reader never sees half of it.
write_status() {
    local ok=$1 err=${2:-} at last_ok tmp="$STATUS.tmp.$$"
    at=$(date -Is)
    last_ok=$LAST_OK_AT
    if [ "$ok" = true ]; then last_ok=$at; fi
    {
        printf '{\n'
        printf '  "at": %s,\n' "$(json_str "$at")"
        printf '  "ok": %s,\n' "$ok"
        printf '  "last_ok_at": %s,\n' "$(json_or_null "$last_ok")"
        printf '  "dest": %s,\n' "$(json_str "$DEST")"
        printf '  "folder": %s,\n' "$(json_or_null "$FOLDER")"
        printf '  "files": %s,\n' "$FILES_JSON"
        printf '  "push": %s' "$PUSH_JSON"
        if [ -n "$err" ]; then printf ',\n  "error": %s' "$(json_str "$err")"; fi
        printf '\n}\n'
    } > "$tmp" && mv -f -- "$tmp" "$STATUS"
}

fail() {
    log "FAILED: $1"
    write_status false "$1" || true
    STATUS_WRITTEN=1
    exit 1
}

set_push() {  # ok(true|false|null) skipped(true|false) ahead(number|null) message
    PUSH_MSG=$4
    PUSH_JSON="{\"ok\": $1, \"skipped\": $2, \"ahead_before\": $3, \"message\": $(json_str "$4")}"
}

on_exit() {
    local rc=$?
    if [ -n "$INC" ] && [ -d "$INC" ]; then rm -rf -- "$INC"; fi       # a half-written copy
    if [ -d "$STAGE" ]; then rm -rf -- "$STAGE"; fi
    if [ "$rc" -ne 0 ] && [ "$STATUS_WRITTEN" -eq 0 ]; then
        if [ -n "$FOLDER" ]; then
            # The backup is in place; only the push step died on something unexpected.
            set_push false false null "the push step stopped unexpectedly (script line $LAST_LINE)"
            log "ok folder=$FOLDER, but the push step stopped unexpectedly (line $LAST_LINE)"
            write_status true || true
            exit 0
        fi
        log "FAILED: the backup script stopped unexpectedly (line $LAST_LINE)"
        write_status false "the backup script stopped unexpectedly (line $LAST_LINE)" || true
    fi
}

mkdir -p "$TRIAL_OUT" "$(dirname "$STATUS")" "$(dirname "$LOG")"

# One backup at a time (the timer and a run by hand could overlap). Taken before the cleanup trap
# is set, so a second copy of the script never deletes the first one's scratch directory.
exec 9> "$TRIAL_OUT/.backup.lock"
if ! flock -n 9; then
    log "another backup is already running; this one does nothing"
    exit 0
fi
trap 'LAST_LINE=$LINENO' ERR
trap on_exit EXIT

LAST_OK_AT=$(sed -n 's/.*"last_ok_at": *"\([^"]*\)".*/\1/p' "$STATUS" 2>/dev/null | head -1 || true)

[[ $KEEP =~ ^[1-9][0-9]*$ ]] || fail "KEEP must be a whole number of days, 1 or more (it is '$KEEP')"
case "$DEST" in /*) ;; *) fail "DEST must be an absolute path (it is '$DEST')" ;; esac

# --- 1. The NAS share must really be mounted (as watch_ingest.sh does for its inbox) -------------
# Otherwise a "backup" would land on this PC's own disk under /mnt/nas_drive and look fine.
mount_problem() {
    if ! timeout 20 mountpoint -q "$DEST_MOUNT"; then
        echo "the NAS Drive share is not mounted ($DEST_MOUNT)"
    elif ! awk -v s="$DEST_SOURCE" -v m="${DEST_MOUNT%/}" '$1 == s && ($2 == m || (m == "" && $2 == "/")) { f = 1 } END { exit !f }' "$MOUNTS_FILE"; then
        echo "$DEST_MOUNT is mounted, but not from $DEST_SOURCE; refusing to write"
    fi
}
if [ "$CHECK_MOUNT" = 1 ]; then
    waited=0
    while problem=$(mount_problem) && [ -n "$problem" ]; do
        if [ "$waited" -ge "$MOUNT_WAIT" ]; then fail "$problem"; fi
        sleep 5
        waited=$((waited + 5))
    done
    case "${DEST%/}/" in
        "${DEST_MOUNT%/}/"*) ;;
        *) fail "DEST ($DEST) is not on the mount $DEST_MOUNT" ;;
    esac
fi

# --- 2. The databases, by SQLite's backup, each copy checked -------------------------------------
rm -rf -- "$STAGE"
mkdir -p "$STAGE"
for name in annotations.db trial.db; do
    src="$TRIAL_OUT/$name"
    [ -f "$src" ] || fail "$name is missing ($src)"
    if ! err=$(sqlite3 "file:$src?mode=ro" ".timeout 30000" ".backup '$STAGE/$name'" 2>&1); then
        fail "copying $name failed: $err"
    fi
    check=$(sqlite3 "file:$STAGE/$name?mode=ro" "PRAGMA quick_check" 2>&1 || true)
    [ "$check" = ok ] || fail "the copy of $name failed PRAGMA quick_check: ${check%%$'\n'*}"
done

# --- 3. The small state that cannot be rebuilt cheaply -------------------------------------------
list="$STAGE/state-files.txt"
: > "$list"
add() { if [ -e "$PROJ/$1" ]; then echo "$1" >> "$list"; fi; }
add trial_out/mobile
add trial_out/ingest_markers
add trial_out/known-unreadable.txt
# Danny's audit verdicts and Claude's reference labels. Not eval/images: those are copies of library photos.
for p in set.json labels grades runs audits report.json; do add "eval/$p"; done
shopt -s nullglob
for p in "$PROJ"/ops/*.service "$PROJ"/ops/*.timer; do add "ops/$(basename "$p")"; done
# What systemd runs today, resolved through any symlink (before the symlink switch this is the
# only copy of photo-review.service).
mkdir -p "$STAGE/systemd-user"
for p in "$UNIT_DIR"/photo-* "$UNIT_DIR"/culling-bay-*; do
    if [ -e "$p" ]; then cp -L -- "$p" "$STAGE/systemd-user/$(basename "$p")"; fi
done
shopt -u nullglob
tar_rc=0
tar -czf "$STAGE/state.tar.gz" -C "$PROJ" -T "$list" -C "$STAGE" systemd-user 2> "$STAGE/tar.err" || tar_rc=$?
if [ "$tar_rc" -eq 1 ]; then
    log "note: a state file changed while it was being archived (tar status 1); the archive is still used"
elif [ "$tar_rc" -ne 0 ]; then
    fail "making state.tar.gz failed: $(head -c 200 "$STAGE/tar.err")"
fi
tar -tzf "$STAGE/state.tar.gz" > /dev/null 2>&1 || fail "state.tar.gz does not read back"

# --- 4. Copy to the NAS: a hidden folder first, then one rename -----------------------------------
day=$(date +%F)
stamp=$(date +%Y%m%dT%H%M%S)-$$
mkdir -p "$DEST" || fail "cannot create $DEST"
# Leftovers of a run that died (a half-written copy, or a replaced day), once they are a day old.
/usr/bin/find "$DEST" -mindepth 1 -maxdepth 1 -type d \( -name '.incoming-*' -o -name '.old-*' \) \
    -mmin +1440 -exec rm -rf -- {} + 2>/dev/null || log "note: could not remove old .incoming-/.old- folders"
INC="$DEST/.incoming-$stamp"
mkdir "$INC" || fail "cannot create $INC"
FILES_JSON="["
sep=""
for f in annotations.db trial.db state.tar.gz; do
    cp -- "$STAGE/$f" "$INC/$f" || fail "copying $f to $DEST failed"
    want=$(stat -c %s "$STAGE/$f")
    got=$(stat -c %s "$INC/$f" 2>/dev/null || echo -1)
    [ "$want" = "$got" ] || fail "$f arrived at $got bytes, not $want"
    FILES_JSON+="$sep{\"name\": $(json_str "$f"), \"bytes\": $want}"
    sep=", "
done
FILES_JSON+="]"
final="$DEST/$day"
if [ -e "$final" ]; then
    # A second run today: the new folder is complete before the old one is touched.
    old="$DEST/.old-$day-$stamp"
    mv -- "$final" "$old" || fail "cannot move today's earlier backup aside"
    if ! mv -- "$INC" "$final"; then
        mv -- "$old" "$final" || true
        fail "cannot put today's new backup in place (the earlier one is back)"
    fi
    rm -rf -- "$old" || log "note: could not remove $old"
else
    mv -- "$INC" "$final" || fail "cannot rename $INC to $final"
fi
INC=""
FOLDER=$day

# --- 5. Prune: dated folders beyond the newest $KEEP; anything else in $DEST is left alone -------
mapfile -t dated < <(ls -1A "$DEST" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r || true)
for ((i = KEEP; i < ${#dated[@]}; i++)); do
    name=${dated[i]}
    [ "$name" = "$day" ] && continue
    if [ -d "$DEST/$name" ] && [ ! -L "$DEST/$name" ]; then
        rm -rf -- "${DEST:?}/$name" || log "note: could not remove old backup $name"
    fi
done

# --- 6. Push $BRANCH to $REMOTE, unless the scan finds something that must not be public ----------
# Plain push of one branch: never --force, never other branches. A rejected push is recorded, not retried.
tidy() {  # one short line from git's output: no credentials in URLs, no long text
    local m
    m=$(printf '%s\n' "$1" | grep -E 'fatal|error|rejected|denied|failed' | head -1 || true)
    [ -n "$m" ] || m=$(printf '%s\n' "$1" | head -1)
    printf '%s' "$m" | sed 's#://[^/@ ]*@#://#' | cut -c1-200
}

# scan <range>: prints "<file>: <what>" for each kind of secret-shaped text the range ADDS (the
# history is what goes public, so a token added in one commit and removed in the next still counts).
# It names the file and the kind, never the text. Returns non-zero if the range cannot be read.
scan() {
    local range=$1 added="$STAGE/added.txt" hits=() files
    if ! git -C "$PROJ" log -p -U0 --no-color --no-ext-diff --format= "$range" -- 2> /dev/null |
        awk '/^diff --git /{ n = index($0, " b/"); f = substr($0, n + 3); next }
             /^\+\+\+ /{ next }
             /^\+/{ print f "\t" substr($0, 2) }' > "$added"; then
        return 1
    fi
    look() {  # <what> <ERE> [i]
        files=$(grep -a"${3:-}E" -e "$2" "$added" | cut -f1 | sort -u | head -3 | paste -sd, - || true)
        if [ -n "$files" ]; then hits+=("$files: $1"); fi
    }
    look "a private key" 'BEGIN [A-Z ]*PRIVATE KEY'
    look "a GitHub token" 'gh[pousr]_[A-Za-z0-9]{20,}'
    look "a GitHub token" 'github_pat_[A-Za-z0-9_]{20,}'
    look "an sk- key" '\bsk-[A-Za-z0-9_-]{20,}'
    look "a Slack token" '\bxox[baprs]-[A-Za-z0-9]'
    look "an AWS access key" 'AKIA[0-9A-Z]{16}'
    look "a password" 'password[[:space:]]*[:=][[:space:]]*[^[:space:]=]' i
    look "a long quoted api_key, token or secret" "(api_?key|token|secret)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][A-Za-z0-9+/_.=-]{20,}[\"']" i
    rm -f -- "$added"
    local IFS=';'
    printf '%s' "${hits[*]:-}" | sed 's/;/; /g'
}

do_push() {
    set +e                      # every step below is checked by hand
    if [ "$PUSH" != 1 ]; then
        set_push null true null "pushing is turned off (PUSH=$PUSH)"; set -e; return
    fi
    export GIT_TERMINAL_PROMPT=0
    local tip base="" out ahead range found
    if ! tip=$(git -C "$PROJ" rev-parse -q --verify "refs/heads/$BRANCH^{commit}"); then
        set_push false false null "this copy has no branch called $BRANCH"; set -e; return
    fi
    if out=$(timeout 120 git -C "$PROJ" fetch --quiet "$REMOTE" "$BRANCH" 2>&1); then
        base=$(git -C "$PROJ" rev-parse -q --verify 'FETCH_HEAD^{commit}')
    else
        timeout 60 git -C "$PROJ" ls-remote --exit-code --heads "$REMOTE" "$BRANCH" > /dev/null 2>&1
        if [ $? -ne 2 ]; then    # 2 = reached the remote, which has no such branch yet (a first push)
            set_push false false null "could not reach $REMOTE: $(tidy "$out")"; set -e; return
        fi
    fi
    if [ -n "$base" ]; then range="$base..$tip"; ahead=$(git -C "$PROJ" rev-list --count "$range")
    else range=$tip; ahead=$(git -C "$PROJ" rev-list --count "$tip"); fi
    if [ "${ahead:-0}" -eq 0 ]; then
        set_push true false 0 "nothing to push"; set -e; return
    fi
    if [ -n "$base" ] && ! git -C "$PROJ" merge-base --is-ancestor "$base" "$tip"; then
        set_push false false "$ahead" "push skipped: $REMOTE/$BRANCH has commits this copy does not (the two have diverged)"
        set -e; return
    fi
    if ! found=$(scan "$range"); then
        set_push false false "$ahead" "push skipped: the commits could not be scanned for secrets"; set -e; return
    fi
    if [ -n "$found" ]; then
        set_push false false "$ahead" "push blocked: $found"; set -e; return
    fi
    if out=$(timeout 300 git -C "$PROJ" push --porcelain "$REMOTE" "$tip:refs/heads/$BRANCH" 2>&1); then
        set_push true false "$ahead" "pushed $ahead commit(s) to $REMOTE/$BRANCH"
    else
        set_push false false "$ahead" "push rejected: $(tidy "$out")"
    fi
    set -e
}
log "backup in place: $DEST/$FOLDER"
do_push

# --- 7. Status and log ---------------------------------------------------------------------------
write_status true || fail "could not write $STATUS"
STATUS_WRITTEN=1
bytes=$(du -sb "$DEST/$FOLDER" 2>/dev/null | cut -f1 || true)
log "ok folder=$FOLDER bytes=${bytes:-?} push: $PUSH_MSG"
exit 0
