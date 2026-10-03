#!/usr/bin/env bash
# Keeps the compactor's dependency boundary honest.
#
# The compactor is the one part of the agent runtime that must never depend on
# the agent runtime. If it grew a back-reference, compaction could recurse into
# itself, and the cycle would compile fine while failing at run time during a
# long session, which is the worst possible moment to discover it.
#
# Two rules are enforced:
#
#   1. Nothing under src/core/compactor/ may import from src/core/agent/.
#   2. Nothing under src/core/agent/runtime/ may import from
#      src/core/agent/runtime/context_compaction.zig's private helpers. The
#      compactor is reached only through its typed entry points.
#
# Run it from the repository root. Exits non-zero with every violation listed.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compactor_dir="$root/src/core/compactor"

if [[ ! -d "$compactor_dir" ]]; then
  echo "error: $compactor_dir does not exist" >&2
  exit 1
fi

status=0

# Rule 1: no upward import into the agent runtime.
#
# Matched on the resolved import path rather than the raw text so a renamed
# directory cannot smuggle the dependency past the check.
violations="$(
  grep -rn --include='*.zig' \
    -E '@import\("(\.\./)+agent/' "$compactor_dir" || true
)"
if [[ -n "$violations" ]]; then
  echo "error: the compactor must not depend on the agent runtime" >&2
  echo "$violations" >&2
  status=1
fi

# Rule 2: every compactor module must be reachable, so a new file cannot sit
# outside the import graph and rot unnoticed.
unreachable="$(
  for module in "$compactor_dir"/*.zig; do
    name="$(basename "$module")"
    # grep rather than git grep: a new module is untracked until it is committed,
    # and the check has to work before that.
    if ! grep -rqE "@import\(\"[^\"]*${name}\"\)" "$root/src"; then
      echo "$module"
    fi
  done
)"
if [[ -n "$unreachable" ]]; then
  echo "error: compactor modules not reachable from src/" >&2
  echo "$unreachable" >&2
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  echo "compactor boundary: ok"
fi

exit "$status"