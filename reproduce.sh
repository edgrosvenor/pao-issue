#!/usr/bin/env bash
#
# Reproduction for laravel/pao (aka the abandoned nunomaduro/pao) silently
# swallowing phpstan output when phpstan fails to start (e.g. a missing config).
#
# pao only activates when it detects an AI-agent session (via env vars such as
# AI_AGENT, CLAUDECODE, CURSOR_AGENT, CODEX_*, ...). In normal CI it is dormant,
# so we explicitly export AI_AGENT=1 to activate it.
#
# IMPORTANT: if your shell is itself an agent session (e.g. you run this inside
# Claude Code), AI_AGENT / CLAUDECODE may already be set in the environment and
# would make pao active even for the "PAO_DISABLE" control. We therefore strip
# those vars first and set them explicitly per-scenario, so the comparison is
# clean and deterministic regardless of where you run it.

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PHPSTAN="./vendor/bin/phpstan"
MISSING_CONFIG="/tmp/pao-issue-does-not-exist.neon"
rm -f "$MISSING_CONFIG"

# Run a command with a clean agent environment, optionally re-injecting vars.
clean() {
  env -u AI_AGENT -u CLAUDECODE -u CLAUDE_CODE -u CURSOR_AGENT -u CODEX_SANDBOX \
      -u CODEX_CI -u CODEX_THREAD_ID -u GEMINI_CLI -u OPENCODE -u OPENCODE_CLIENT \
      "$@"
}

hr() { printf '%s\n' "----------------------------------------------------------------------"; }

run_scenario() {
  local label="$1"; shift
  hr
  echo "### ${label}"
  echo "\$ $*"
  echo "--- begin captured output (stdout+stderr) ---"
  "$@" 2>&1
  local code=$?
  echo "--- end captured output ---"
  echo "exit code: ${code}"
  echo
  return 0
}

echo "pao reproduction: phpstan output swallowed under an AI-agent session"
echo

# ---------------------------------------------------------------------------
# A (CONTROL): phpstan SUCCESS, pao ACTIVE.
# Prints the expected JSON summary {"tool":"phpstan","result":"passed","errors":0}.
# This shows pao IS active and working on the normal path.
# ---------------------------------------------------------------------------
run_scenario "A (control) - phpstan SUCCESS, pao ACTIVE (AI_AGENT=1)" \
  clean env AI_AGENT=1 "$PHPSTAN" analyse --configuration=phpstan.neon

# ---------------------------------------------------------------------------
# B (BUG): phpstan FAILS to start (missing config), pao ACTIVE.
# Expected: the real phpstan error, OR at minimum pao's raw-output fallback.
# Actual: completely empty output, exit 1. Total silent failure.
# ---------------------------------------------------------------------------
run_scenario "B (bug) - missing config, pao ACTIVE (AI_AGENT=1)" \
  clean env AI_AGENT=1 "$PHPSTAN" analyse --configuration="$MISSING_CONFIG"

# ---------------------------------------------------------------------------
# C (PROOF IT IS PAO): identical to B but with PAO_DISABLE=1.
# The real phpstan error is now visible:
#   "Project config file at path ... does not exist."
# This proves the empty output in B is caused by pao, not by phpstan or config.
# ---------------------------------------------------------------------------
run_scenario "C (proof) - missing config, pao DISABLED (PAO_DISABLE=1)" \
  clean env AI_AGENT=1 PAO_DISABLE=1 "$PHPSTAN" analyse --configuration="$MISSING_CONFIG"

# ---------------------------------------------------------------------------
# D (bonus): a real phpstan lint error path works under pao (for contrast with B).
# We drop in a file with an undefined variable, then remove it again.
# Prints pao JSON with result=failed and the error detail. This proves the
# swallow in B is specific to the startup-failure / no-`totals` path.
# ---------------------------------------------------------------------------
cat > app/PaoIssueBadFile.php <<'PHP'
<?php

namespace App;

class PaoIssueBadFile
{
    public function broken(): int
    {
        return $undefinedVariable;
    }
}
PHP

run_scenario "D (bonus) - real phpstan lint error, pao ACTIVE (AI_AGENT=1)" \
  clean env AI_AGENT=1 "$PHPSTAN" analyse --configuration=phpstan.neon

# Show what phpstan WOULD have printed for D, with pao disabled, for contrast.
run_scenario "D' (proof) - same lint error, pao DISABLED (PAO_DISABLE=1)" \
  clean env AI_AGENT=1 PAO_DISABLE=1 "$PHPSTAN" analyse --configuration=phpstan.neon

rm -f app/PaoIssueBadFile.php
rm -f "$MISSING_CONFIG"

hr
echo "Summary:"
echo "  A: pao active + success    -> JSON summary printed (works, control)"
echo "  B: pao active + bad config -> EMPTY output, exit 1 (the bug)"
echo "  C: pao disabled + bad config -> real phpstan error is visible (proof it is pao)"
echo "  D: pao active + lint error -> JSON failure printed (works)"
echo "  D': pao disabled + lint error -> real phpstan error table (for contrast)"
echo
echo "Conclusion: the normal paths (A, D) work, but when phpstan fails to start"
echo "(B: missing config -> no JSON 'totals'), pao active swallows ALL output and"
echo "exits non-zero with nothing printed. Disabling pao (C) restores the real"
echo "error. This is a pao defect, not a phpstan or project-config defect."
