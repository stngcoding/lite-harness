#!/usr/bin/env bash
# my-ralph.sh — drain a PRD's "ready-for-agent" sub-issues, then PR the whole PRD.
#
# Per-PRD flow (Implement → Review → Close, then PR → Review):
#   1. Pick the highest-priority *processable* ready-for-agent sub-issue; its
#      `## Parent` reference selects the active PRD (a parent-less issue is its
#      own PRD-of-one).
#   2. Check out a branch named "<parent#>-<slug>" off origin/<BASE>.
#   3. For each of the PRD's sub-issues (only those whose `## Blocked by`
#      issues are closed):
#        - Implement: the agent implements AND self-reviews via its own
#          diff-verifier sub-agent, fixing findings (advisory, biased).
#        - Commit immediately → a precise, recoverable per-issue slice.
#        - Gate: analyze + tests + an INDEPENDENT diff-verifier process that
#          reviews exactly baseline..HEAD (authoritative, unbiased).
#        - PASS → close the sub-issue. FAIL → tag the attempt, roll back to
#          baseline, comment, relabel ready-for-human.
#   4. When the PRD's sub-issues are drained AND none failed, push the branch,
#      open ONE PR to <BASE>, then run a PR-level diff-verifier on the whole
#      PR diff. PR starts as a draft and is marked ready only if that review
#      passes.
#
# Resilience: set -uo pipefail (NO -e) so a single flaky gh/git/grep call never
# aborts a multi-hour drain; critical git steps are checked explicitly.
#
# Usage:
#   ./scripts/my-ralph.sh
#   STATE=open BASE=main ./scripts/my-ralph.sh
#
# Environment:
#   REPO   owner/repo      (default: auto-detected from git)
#   STATE  open|closed|all (default: open)
#   BASE   PR base branch  (default: main)
#   MODEL  implementer model (default: sonnet)

set -uo pipefail

REPO="${REPO:-}"
STATE="${STATE:-open}"
BASE="${BASE:-dev}"
MODEL="${MODEL:-sonnet}"

if [[ -z "$REPO" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "Error: could not detect GitHub repo. Run inside a clone or set REPO=owner/name" >&2
    exit 1
  }
fi

echo "Repo:  $REPO"
echo "State: $STATE"
echo "Base:  $BASE"
echo ""

# ── helpers ──────────────────────────────────────────────────────────────────

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-50
}

# Parent issue number from a body's `## Parent` section; falls back to the
# issue's own number when no parent is declared (standalone = PRD-of-one).
parent_of() { # $1=body  $2=own_number
  local p
  p=$(awk '/^## *Parent/{f=1;next} /^## /{f=0} f' <<<"$1" \
    | grep -oE '#[0-9]+|/issues/[0-9]+' | grep -oE '[0-9]+' | head -1)
  printf '%s' "${p:-$2}"
}

# Blocker issue numbers from a body's `## Blocked by` section (empty if none).
blockers_of() { # $1=body
  awk '/^## *Blocked by/{f=1;next} /^## /{f=0} f' <<<"$1" \
    | grep -oE '#[0-9]+' | grep -oE '[0-9]+' || true
}

all_blockers_closed() { # $1=body  → 0 if every blocker is CLOSED
  local b state
  for b in $(blockers_of "$1"); do
    state=$(gh issue view "$b" --repo "$REPO" --json state -q .state 2>/dev/null || echo OPEN)
    [[ "$state" == "CLOSED" ]] || return 1
  done
  return 0
}

# Priority-sorted ready-for-agent issues, one compact JSON object per line.
ready_issues() {
  gh issue list --repo "$REPO" --state "$STATE" --label ready-for-agent --limit 100 \
    --json number,title,body,labels,url 2>/dev/null \
    | jq -c '
        def score:
          [.labels[].name | ascii_downcase] as $l |
          if   ($l|any(test("critical|p0|urgent|blocker"))) then 0
          elif ($l|any(test("high|p1|important")))          then 1
          elif ($l|any(test("bug|defect|fix")))             then 2
          elif ($l|any(test("medium|p2")))                  then 3
          elif ($l|any(test("enhancement|feature")))        then 4
          elif ($l|any(test("low|p3|minor")))               then 5
          else 6 end;
        sort_by([score, .number]) | .[]
      ' 2>/dev/null || true
}

park_drift() { # keep the working tree clean before switching branches
  if [[ -n "$(git status --porcelain)" ]]; then
    local name="ralph-parked-$(date +%s)"
    git stash push -u -m "$name" >/dev/null 2>&1 \
      && echo "  Parked uncommitted drift in stash: $name"
  fi
}

# Implement one sub-issue through the hybrid gate. Returns 0=PASS, 1=FAIL.
process_sub() { # $1=issue_json
  local issue="$1" number title body labels url comments baseline
  number=$(jq -r '.number' <<<"$issue")
  title=$(jq -r '.title' <<<"$issue")
  body=$(jq -r '.body // "(no description provided)"' <<<"$issue")
  labels=$(jq -r '[.labels[].name] | join(", ")' <<<"$issue")
  url=$(jq -r '.url' <<<"$issue")
  comments=$(gh issue view "$number" --repo "$REPO" --json comments \
    --jq '.comments[] | "**\(.author.login)** (\(.createdAt)):\n\(.body)\n"' 2>/dev/null || true)

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Issue #${number}: ${title}"
  echo "  ${url}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  baseline=$(git rev-parse HEAD)

  # ── Implement, with the agent's OWN reviewer sub-agent (advisory self-review) ──
  claude --model "$MODEL" --dangerously-skip-permissions --output-format stream-json --verbose -p \
"## GitHub Issue #${number}: ${title}
${labels:+Labels: ${labels}
}
${body}
${comments:+
### Comments
${comments}
}
---
You're a Flutter Engineer Expert. Implement this issue in the codebase.

<before-implement>
- Read the issue description and comments.
- Use the Explore agent to locate relevant code before modifying anything.
- If the task touches a domain topic (websocket, streaming, widgets, approval, history, etc.), delegate to the domain-doc-researcher agent first and honor the constraints it returns.
</before-implement>

<during-implement>
- Prefer retrieval-led reasoning over pre-training-led reasoning for all Flutter/Dart tasks.
- FULL implementations only — no placeholders, stubs, or TODOs.
- Self-documenting code; comments only to explain a decision, never to divide a file into sections.
- Do NOT commit. The harness commits for you.
</during-implement>

<self-review>
- When the implementation is complete, use the Task tool to spawn the 'diff-verifier' agent to review your uncommitted changes against this issue.
- If it returns VERDICT: FAIL, fix every bullet it lists, then run it again. Repeat until VERDICT: PASS.
- Then STOP. Do NOT commit.
</self-review>
"\
    | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' 2>/dev/null

  echo ""

  # ── Commit-first: turn the work into a precise, recoverable slice ──
  if [[ -z "$(git status --porcelain)" ]]; then
    echo "  No changes produced for #${number} → FAIL."
    gh issue edit "$number" --repo "$REPO" \
      --remove-label ready-for-agent --add-label ready-for-human >/dev/null 2>&1 || true
    gh issue comment "$number" --repo "$REPO" \
      --body "AFK loop produced no changes for this issue — needs human attention." >/dev/null 2>&1 || true
    return 1
  fi
  git add -A
  git commit -q -m "feat(#${number}): ${title}

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" \
    || { echo "  commit failed for #${number}"; return 1; }

  # ── Mechanical gate ──
  local analyze_ok=1 test_ok=1
  fvm flutter analyze >/tmp/ralph-analyze.log 2>&1 || analyze_ok=0
  fvm flutter test    >/tmp/ralph-test.log    2>&1 || test_ok=0

  # ── Authoritative gate: a FRESH, independent reviewer over THIS slice only ──
  local verdict
  verdict=$(claude --agent diff-verifier --dangerously-skip-permissions \
    --output-format stream-json --verbose -p \
"Review the changes for GitHub issue #${number}: ${title}

${body}

Mechanical results: analyze=$([[ $analyze_ok == 1 ]] && echo PASS || echo FAIL), tests=$([[ $test_ok == 1 ]] && echo PASS || echo FAIL).
The changes for THIS issue are exactly the commit range ${baseline}..HEAD. Run \`git diff ${baseline}..HEAD\` and read each changed file in full. Judge whether they satisfy the acceptance criteria and obey the repo conventions, then emit the verdict line." \
    | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' 2>/dev/null || true)

  if [[ $analyze_ok == 1 && $test_ok == 1 ]] && grep -q "VERDICT: PASS" <<<"$verdict"; then
    gh issue close "$number" --repo "$REPO" \
      --comment "Verified by AFK loop on branch \`$(git rev-parse --abbrev-ref HEAD)\`: analyze + tests + independent review all green." >/dev/null 2>&1 || true
    echo "  #${number} PASS → closed."
    return 0
  fi

  # ── FAIL: preserve the attempt, roll back to baseline, hand to a human ──
  git tag -f "ralph-fail/${number}" HEAD >/dev/null 2>&1 || true
  git reset --hard "$baseline" >/dev/null 2>&1
  gh issue edit "$number" --repo "$REPO" \
    --remove-label ready-for-agent --add-label ready-for-human >/dev/null 2>&1 || true
  gh issue comment "$number" --repo "$REPO" \
    --body "$(printf 'AFK verify FAILED (analyze=%s test=%s).\n\nFailed attempt preserved at tag `ralph-fail/%s` (recover with `git checkout ralph-fail/%s`).\n\n**Reviewer**\n%s\n\n**Logs**\n```\n%s\n```' \
      "$analyze_ok" "$test_ok" "$number" "$number" "$verdict" "$(tail -n 20 /tmp/ralph-analyze.log /tmp/ralph-test.log 2>/dev/null)")" >/dev/null 2>&1 || true
  echo "  #${number} FAIL → tagged ralph-fail/${number}, rolled back, relabeled ready-for-human."
  return 1
}

# ── main: one outer pass per PRD ──────────────────────────────────────────────

while true; do
  # Select the active PRD from the highest-priority processable sub-issue.
  active_parent=""
  while IFS= read -r issue; do
    [[ -z "$issue" ]] && continue
    num=$(jq -r '.number' <<<"$issue")
    bdy=$(jq -r '.body // ""' <<<"$issue")
    all_blockers_closed "$bdy" || continue
    active_parent=$(parent_of "$bdy" "$num")
    break
  done < <(ready_issues)

  if [[ -z "$active_parent" ]]; then
    echo "No processable ready-for-agent issues remain. Done."
    break
  fi

  ptitle=$(gh issue view "$active_parent" --repo "$REPO" --json title -q .title 2>/dev/null || echo "prd-${active_parent}")
  branch="${active_parent}-$(slugify "$ptitle")"

  echo ""
  echo "════════════════════════════════════════════════════"
  echo "  PRD #${active_parent}: ${ptitle}"
  echo "  Branch: ${branch}"
  echo "════════════════════════════════════════════════════"

  # Get onto the PRD branch off the latest base (resume if it already exists).
  park_drift
  git fetch origin "$BASE" --quiet 2>/dev/null || true
  if git show-ref --verify --quiet "refs/heads/${branch}"; then
    git checkout "$branch" >/dev/null 2>&1 || { echo "  cannot checkout ${branch}; skipping PRD"; continue; }
  else
    git checkout -B "$branch" "origin/${BASE}" >/dev/null 2>&1 \
      || git checkout -b "$branch" >/dev/null 2>&1 \
      || { echo "  cannot create ${branch}; skipping PRD"; continue; }
  fi

  # Drain this PRD's sub-issues, re-evaluated each pass so newly-unblocked
  # sub-issues become available as their blockers close.
  prd_failed=0
  while true; do
    sub=""
    while IFS= read -r issue; do
      [[ -z "$issue" ]] && continue
      num=$(jq -r '.number' <<<"$issue")
      bdy=$(jq -r '.body // ""' <<<"$issue")
      [[ "$(parent_of "$bdy" "$num")" == "$active_parent" ]] || continue
      all_blockers_closed "$bdy" || continue
      sub="$issue"
      break
    done < <(ready_issues)
    [[ -z "$sub" ]] && break
    process_sub "$sub" || prd_failed=1
  done

  # One PR per PRD, only on a clean sweep with real commits.
  git fetch origin "$BASE" --quiet 2>/dev/null || true
  ahead=$(git rev-list --count "origin/${BASE}..HEAD" 2>/dev/null || echo 0)
  if [[ "$prd_failed" == 0 && "${ahead:-0}" -gt 0 ]]; then
    if ! git push -u origin "$branch" >/dev/null 2>&1; then
      echo "  push failed for ${branch}; leaving for human."
      continue
    fi
    pr_url=$(gh pr create --repo "$REPO" --base "$BASE" --head "$branch" --draft \
      --title "PRD #${active_parent}: ${ptitle}" \
      --body "$(printf 'Implemented by the AFK loop for PRD #%s.\n\nEach sub-issue passed analyze + tests + an independent review before landing.\n\nCloses #%s\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)' "$active_parent" "$active_parent")" \
      2>/dev/null) \
      || pr_url=$(gh pr view "$branch" --repo "$REPO" --json url -q .url 2>/dev/null || true)
    echo "  PR: ${pr_url:-<none>}"

    # PR-level review phase: independent diff-verifier over the WHOLE PR diff.
    if [[ -n "${pr_url:-}" ]]; then
      pr_verdict=$(claude --agent diff-verifier --dangerously-skip-permissions \
        --output-format stream-json --verbose -p \
"Review the FULL pull request for PRD #${active_parent}: ${ptitle}.
The PR diff is exactly the commit range origin/${BASE}..HEAD. Run \`git diff origin/${BASE}..HEAD\`, read each changed file in full, judge whether the PRD is coherently and correctly implemented across all its sub-issues and obeys the repo conventions, then emit the verdict line." \
        | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' 2>/dev/null || true)
      gh pr comment "$pr_url" --repo "$REPO" \
        --body "$(printf '**AFK PR review (diff-verifier)**\n\n%s' "$pr_verdict")" >/dev/null 2>&1 || true
      if grep -q "VERDICT: PASS" <<<"$pr_verdict"; then
        gh pr ready "$pr_url" --repo "$REPO" >/dev/null 2>&1 || true
        echo "  PR review PASS → marked ready."
      else
        echo "  PR review FAIL → left as draft for human."
      fi
    fi
  else
    echo "  PRD #${active_parent} not PR'd (failed_subs=${prd_failed}, commits_ahead=${ahead:-0}). Branch left for human."
  fi
done
