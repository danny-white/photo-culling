#!/usr/bin/env bash
# Overnight adversarial review of qwen's NEW-prompt outputs. Launched once at 00:00 by a
# systemd --user transient timer (unit: adv-review). Runs a headless Claude agent that samples
# fresh frames in batches, reviews them per review/adversarial-review-prompt.md, and appends
# findings to review/adversarial-review-findings.md (crash-safe, per batch).
set -uo pipefail

PROJ=/home/danny/photo-culling
MODEL=claude-opus-4-8      # swap to claude-sonnet-5 for cheaper / more frames per dollar
BUDGET=10                  # USD cap; agent stops gracefully when hit (findings already on disk)
LOG="$PROJ/trial_out/adversarial_review_run.log"

export HOME="${HOME:-/home/danny}"
export PATH="$HOME/.local/bin:$PATH"
cd "$PROJ" || exit 1

echo "=== adversarial review started $(date -Is)  (model=$MODEL budget=\$$BUDGET) ===" >> "$LOG"
claude -p "$(cat "$PROJ/review/adversarial_review_driver.md")" \
  --model "$MODEL" \
  --dangerously-skip-permissions \
  --max-budget-usd "$BUDGET" \
  >> "$LOG" 2>&1
echo "=== adversarial review exited rc=$? at $(date -Is) ===" >> "$LOG"
