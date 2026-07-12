#!/usr/bin/env bash
# Interactive SQLite shell on the culling DB (defaults to the trial DB).
#   ./dbshell.sh [DB]       box mode, cells wrapped to terminal width
#   ./dbshell.sh -l [DB]    line mode (one "col = value" per line) — best for full `SELECT *`
#
# Three ways to read wide data:
#   • select * from brief   -> compact overview: key columns, caption/subject trimmed to 1 line
#   • .mode line ; select *  -> every field, one per line (nothing truncated)
#   • substr(caption,1,15)||'…'  -> ad-hoc trim of any long column in your own SELECT
# Note: `--wrap` WRAPS long cells onto multiple lines; it does not truncate. To truncate, use
# the `brief` view or substr(). A full `select *` is 37 cols (~436 chars) — too wide for any
# table mode, so use line mode for that.
set -euo pipefail

LINE=0
[[ "${1:-}" == "-l" || "${1:-}" == "--line" ]] && { LINE=1; shift; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${1:-$HERE/trial_out/trial.db}"
[[ -f "$DB" ]] || { echo "No DB at: $DB" >&2; exit 1; }

# Detect terminal width; cap per-column wrap so wide values don't blow out the table.
COLS=$(tput cols 2>/dev/null || echo 120)
WRAP=$(( COLS / 3 )); (( WRAP < 32 )) && WRAP=32; (( WRAP > 72 )) && WRAP=72

if (( LINE )); then MODE=".mode line"; else MODE=".mode box --wrap $WRAP --wordwrap on"; fi

# Session-only compact view (never touches the DB file): key culling columns, long text trimmed.
BRIEF="CREATE TEMP VIEW IF NOT EXISTS brief AS SELECT
  filename, status, verdict, quality_stars AS stars, aesthetic AS aes, exposure_flag AS exp,
  CAST(round(sharpness) AS INT) AS sharp, scene, people_count AS ppl, eyes_closed AS eyes,
  CASE WHEN length(subject)>16 THEN substr(subject,1,15)||char(8230) ELSE subject END AS subject,
  CASE WHEN length(caption)>30 THEN substr(caption,1,29)||char(8230) ELSE caption END AS caption,
  prompt_version AS pver
  FROM images;"

echo "sqlite3 $DB  (${COLS}-col term)  |  compact: select * from brief  ·  full row: .mode line  ·  .quit"
exec sqlite3 "$DB" \
  -cmd ".timeout 5000" \
  -cmd ".headers on" \
  -cmd ".nullvalue NULL" \
  -cmd "$BRIEF" \
  -cmd "$MODE"
