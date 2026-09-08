#!/usr/bin/env bash
# Assembles a throwaway git repository from the backlog fixture, in the state an eval needs.
#
#   setup-fixture.sh <target dir> [pick|resume|dirty]
#
#   pick    (default) a clean default branch: B-01 open P1, B-02 question, B-03 wip with no branch,
#           B-04 done, B-05 open P3 blocked by B-02, B-06 dropped.
#   resume  the same, plus a branch feat/b-01-retry-failed-overdue-notices with one commit that
#           flips B-01 to wip and an "Iteration 1" findings entry - a previous iteration stopped.
#   dirty   the same as pick, with an uncommitted edit in the working tree.
set -euo pipefail
target=${1:?target dir}
variant=${2:-pick}
here=$(cd "$(dirname "$0")" && pwd)
rm -rf "$target" && mkdir -p "$target" && cp -R "$here/backlog-fixture/." "$target/"
cd "$target"
git init -q -b main
git add -A && git -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "chore: fixture"
case "$variant" in
  pick) ;;
  resume)
    git checkout -q -b feat/b-01-retry-failed-overdue-notices
    f=docs/backlog/B-01-retry-failed-overdue-notices.md
    sed -i.bak 's/^status: open/status: wip/' "$f" && rm "$f.bak"
    printf '\n## Iteration 1 (2026-09-01)\n\nRead the retry path in `loans-service/src/loans_service/jobs/overdue_notices.py`; the failure is recorded before the send. Stopped before writing the test.\n' >> "$f"
    python3 scripts/backlog_index.py >/dev/null
    git add -A && git -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "chore(backlog): take B-01

Refs: B-01"
    git checkout -q main ;;
  dirty)
    printf '\n<!-- half-written note -->\n' >> docs/features/feature-overdue-notices.md ;;
  *) echo "unknown variant $variant" >&2; exit 2 ;;
esac
echo "fixture ready at $target ($variant)"
