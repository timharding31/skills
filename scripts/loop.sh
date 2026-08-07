#!/bin/bash
set -e
shopt -s extglob

# box drawing + ${#var} char counting need a UTF-8 locale
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*) ;;
  *) export LC_ALL=en_US.UTF-8 ;;
esac

usage() {
  cat <<EOF
Usage: $0 <spec-dir|spec.json|gh-issue-url> [max-iterations] [--model <model>] [--check]

Works through a spec one issue per iteration until every issue is done.

  $0 .scratch/lab-modeling-v2
  $0 .scratch/lab-modeling-v2/spec.json 10
  $0 .scratch/lab-modeling-v2 --check     # validate + show the board, run nothing
  $0 https://github.com/timharding31/ff-sim/issues/5 --model opus

Spec mode reads a spec.json written by /to-spec and /to-issues. The script — not
the model — picks the next issue (first in array order whose blockers are all
done), injects only that issue plus the spec's summary/invariants/ledger, and
records the result. The agent never edits spec.json.

An issue may carry a "model" field ("haiku" | "sonnet" | "opus", or empty for
the default) to override --model/CLAUDE_MODEL for that iteration only.

GitHub mode works through the sub-issues of a parent issue, letting the model
pick. It requires the gh CLI.

Env:
  MAX_ITERATIONS   default iteration cap (default: 50)
  CLAUDE_MODEL     default model, overridable per issue (default: whatever
                   claude is configured with)
  CLAUDE_CMD       command used to run claude (default: "claude")
  RETRIES          retries per iteration on API errors (default: 3)
  RETRY_DELAY      base backoff seconds, multiplied per attempt (default: 20)
  STALL_LIMIT      stop after N iterations that finish nothing (default: 2)
  PERMISSION_MODE  claude --permission-mode (default: auto; the loop needs
                   gh/git/test commands, which acceptEdits does not cover)
  STREAM_WINDOW    live events kept on screen, older ones collapse to "..."
                   (default: 10; only applies on a terminal)
  NO_COLOR         set to disable colors
EOF
}

# ── Tokyo Night ───────────────────────────────────────────────────────────────
STREAM_TTY=0
[ -t 1 ] && STREAM_TTY=1
STREAM_WINDOW="${STREAM_WINDOW:-10}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BG_DARK=$'\033[48;2;22;22;30m'
  FG=$'\033[38;2;192;202;245m'
  DIM=$'\033[38;2;86;95;137m'
  BLUE=$'\033[38;2;122;162;247m'
  CYAN=$'\033[38;2;125;207;255m'
  GREEN=$'\033[38;2;158;206;106m'
  MAGENTA=$'\033[38;2;187;154;247m'
  RED=$'\033[38;2;247;118;142m'
  YELLOW=$'\033[38;2;224;175;104m'
  ORANGE=$'\033[38;2;255;158;100m'
  TEAL=$'\033[38;2;115;218;202m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  BG_DARK= FG= DIM= BLUE= CYAN= GREEN= MAGENTA= RED= YELLOW= ORANGE= TEAL= BOLD= RESET=
fi

WIDTH=$(tput cols 2>/dev/null || echo 80)
[ "$WIDTH" -gt 92 ] && WIDTH=92
[ "$WIDTH" -lt 48 ] && WIDTH=48
INNER=$((WIDTH - 4))

die() { printf '\n%s✖%s  %s\n\n' "$RED" "$RESET" "$1" >&2; exit 1; }

repeat() { # $1 char, $2 count
  local out= n=$2
  while [ "$n" -gt 0 ]; do out="$out$1"; n=$((n - 1)); done
  printf '%s' "$out"
}

# visible length in characters, ignoring ANSI escapes
vlen() {
  local s=${1//$'\033'\[*([0-9;])m/}
  printf '%s' "${#s}"
}

trunc() { # $1 text, $2 max
  local t=$1
  if [ "${#t}" -gt "$2" ]; then printf '%s…' "${t:0:$(($2 - 1))}"; else printf '%s' "$t"; fi
}

box_top()    { printf '%s╭%s╮%s\n' "$MAGENTA" "$(repeat '─' $((WIDTH - 2)))" "$RESET"; }
box_bottom() { printf '%s╰%s╯%s\n' "$MAGENTA" "$(repeat '─' $((WIDTH - 2)))" "$RESET"; }
box_sep()    { printf '%s├%s┤%s\n' "$MAGENTA" "$(repeat '─' $((WIDTH - 2)))" "$RESET"; }
box_line() { # $1 already-colored content
  local pad=$((INNER - $(vlen "$1")))
  [ "$pad" -lt 0 ] && pad=0
  printf '%s│%s %s%s %s│%s\n' "$MAGENTA" "$RESET" "$1" "$(repeat ' ' "$pad")" "$MAGENTA" "$RESET"
}

progress_bar() { # $1 done, $2 total, $3 width
  local done=$1 total=$2 w=$3 filled
  [ "$total" -eq 0 ] && total=1
  filled=$((done * w / total))
  printf '%s%s%s%s%s' "$GREEN" "$(repeat '━' "$filled")" "$DIM" "$(repeat '━' $((w - filled)))" "$RESET"
}

# Renders claude's --output-format stream-json events live: one line per tool
# call and per assistant message. Non-JSON lines (crashes, API errors) pass
# through so failures stay visible.
#
# On a terminal the rail is a rolling window of the last $STREAM_WINDOW events,
# redrawn in place with a "..." marker standing in for what scrolled off. When
# piped or redirected the events just stream in full, so logs stay complete.
stream_render() {
  stream_events | stream_window
}

stream_window() {
  local -a win=()
  local hidden=0 drawn=0 line

  if [ "$STREAM_TTY" -eq 0 ]; then cat; return; fi

  while IFS= read -r line; do
    win+=("$line")
    if [ "${#win[@]}" -gt "$STREAM_WINDOW" ]; then
      win=("${win[@]:1}")
      hidden=$((hidden + 1))
    fi

    # rewind over the previous frame and clear to end of screen
    [ "$drawn" -gt 0 ] && printf '\033[%dA\033[J' "$drawn"
    drawn=0

    if [ "$hidden" -gt 0 ]; then
      printf '%s │ ...%s %s(%s earlier)%s\n' "$DIM" "$RESET" "$DIM" "$hidden" "$RESET"
      drawn=1
    fi
    for line in "${win[@]}"; do
      printf '%s\n' "$line"
      drawn=$((drawn + 1))
    done
  done
}

stream_events() {
  jq -Rr --unbuffered \
    --arg dim "$DIM" --arg reset "$RESET" --arg blue "$BLUE" --arg fg "$FG" \
    --arg cyan "$CYAN" --arg red "$RED" \
    --argjson w "$((WIDTH - 8))" '
    def cut($n): if ($n > 1 and (length > $n)) then .[0:$n - 1] + "…" else . end;
    def row($icon; $body): "\($dim) │ \($reset)\($icon) \($body)\($reset)";

    . as $raw
    | (fromjson? // null) as $e
    | if $e == null then
        if ($raw | gsub("\\s"; "")) == "" then empty
        else row("\($red)⚠\($reset)"; "\($red)\($raw | cut($w))") end
      elif $e.type == "assistant" then
        $e.message.content[]?
        | if .type == "tool_use" then
            (.name | tostring) as $n
            | ((.input.description // .input.file_path // .input.command
                // .input.pattern // .input.prompt // .input.url // "")
               | tostring | gsub("\\s+"; " ") | cut($w - ($n | length) - 3)) as $d
            | row("\($blue)⏺\($reset)"; "\($fg)\($n)\($reset)\(if $d == "" then "" else "  \($dim)\($d)" end)")
          elif .type == "text" then
            (.text | gsub("\\s+"; " ")) as $t
            | if ($t | gsub(" "; "")) == "" then empty
              else row("\($cyan)·\($reset)"; "\($dim)\($t | cut($w))") end
          else empty end
      else empty end
  '
}

hms() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

# claude's closing message, wrapped rather than truncated — the rail only ever
# shows a clipped one-liner, which is useless when it explains a blocker.
print_message() {
  printf '%s' "$1" | fold -s -w $((WIDTH - 6)) | head -40 | while IFS= read -r l; do
    printf '   %s%s%s\n' "$DIM" "$l" "$RESET"
  done
}

# ── Args ──────────────────────────────────────────────────────────────────────
if [ -z "$1" ]; then usage; exit 1; fi

command -v jq >/dev/null 2>&1 || die "jq is required but not installed."

TARGET=
ITERATIONS=
MODEL="${CLAUDE_MODEL:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --model)
      [ -z "$2" ] && die "--model requires a value (haiku|sonnet|opus|fable)."
      MODEL="$2"; shift 2 ;;
    --model=*) MODEL="${1#--model=}"; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    -*) usage >&2; die "unknown flag $1." ;;
    *)
      if [ -z "$TARGET" ]; then TARGET="${1%/}"
      elif [ -z "$ITERATIONS" ]; then ITERATIONS="$1"
      else die "unexpected argument $1."
      fi
      shift ;;
  esac
done

case "$MODEL" in
  haiku|sonnet|opus|fable|"") ;;
  *) die "unknown model $MODEL (expected haiku, sonnet, opus, or fable)." ;;
esac

MAX_ITERATIONS="${ITERATIONS:-${MAX_ITERATIONS:-50}}"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
RETRIES="${RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-20}"
STALL_LIMIT="${STALL_LIMIT:-2}"
PERMISSION_MODE="${PERMISSION_MODE:-auto}"
NO_PROGRESS=0

if [ -n "$ITERATIONS" ] && ! [[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
  die "max-iterations must be a positive integer, got $ITERATIONS."
fi

# The model in force for the next claude invocation. An issue's "model" field
# beats this default for its iteration only, so one run can put cheap tickets on
# haiku without splitting into several runs.
use_model() { # $1 model name, "" = whatever claude is configured with
  MODEL_ARGS=()
  [ -n "$1" ] && MODEL_ARGS=(--model "$1")
  MODEL_LABEL="${1:-default}"
  case "$1" in
    opus)   MODEL_COLOR="$MAGENTA" ;;
    sonnet) MODEL_COLOR="$BLUE" ;;
    haiku)  MODEL_COLOR="$TEAL" ;;
    fable)  MODEL_COLOR="$ORANGE" ;;
    *)      MODEL_COLOR="$DIM" ;;
  esac
}

use_model "$MODEL"

[ -n "$TARGET" ] || { usage >&2; die "no spec path or GitHub issue URL given."; }

# A github.com URL is the issue tracker; anything else is a spec on disk.
if [[ "$TARGET" =~ ^(https?://|git@) ]] || [[ "$TARGET" == github.com/* ]]; then
  MODE=gh
else
  MODE=spec
fi

# ── Parent: GitHub issue ──────────────────────────────────────────────────────
if [ "$MODE" = gh ]; then
  command -v gh >/dev/null 2>&1 || die "gh is required for GitHub issues but is not installed."

  if [[ ! "$TARGET" =~ ^https?://github\.com/([^/]+)/([^/]+)/issues/([0-9]+)$ ]]; then
    die "$TARGET is not a GitHub issue URL (expected https://github.com/<owner>/<repo>/issues/<n>)."
  fi

  OWNER="${BASH_REMATCH[1]}"; REPO="${BASH_REMATCH[2]}"; PARENT="${BASH_REMATCH[3]}"
  SLUG="$OWNER/$REPO"

  PARENT_TITLE=$(gh issue view "$PARENT" --repo "$SLUG" --json title --jq '.title')
  SOURCE_LABEL="$SLUG"
  BOARD_LABEL="${SLUG}#${PARENT}"
  SOURCE_DETAIL="$TARGET"
fi

# ── Parent: spec.json ─────────────────────────────────────────────────────────
# Written by /to-spec (context only) and /to-issues (the issues array). See
# ~/.claude/skills/to-spec/resources/spec.schema.json.
if [ "$MODE" = spec ]; then
  SPEC="$TARGET"
  [ -d "$SPEC" ] && SPEC="$SPEC/spec.json"

  [ -f "$SPEC" ] || die "no spec.json at $SPEC."
  jq -e . "$SPEC" >/dev/null 2>&1 || die "$SPEC is not valid JSON."

  SPEC_DIR=$(dirname "$SPEC")
  PARENT_TITLE=$(jq -r '.title // .slug // "untitled"' "$SPEC")
  SOURCE_LABEL=$(jq -r '.slug // empty' "$SPEC")
  [ -n "$SOURCE_LABEL" ] || SOURCE_LABEL=$(basename "$SPEC_DIR")
  BOARD_LABEL="$SOURCE_LABEL"
  SOURCE_DETAIL="$SPEC"
fi

# ── Spec validation ───────────────────────────────────────────────────────────
# A malformed graph is worth failing on before burning an iteration, not
# halfway through an unattended run.
validate_spec() {
  local count problems body

  count=$(jq '(.issues // []) | length' "$SPEC")
  if [ "$count" -eq 0 ]; then
    printf '\n%s✖%s  %s has no issues to work through.\n' "$RED" "$RESET" "$SPEC" >&2
    printf '   %s/to-spec writes the context; run /to-issues on it to decompose the work.%s\n\n' "$DIM" "$RESET" >&2
    exit 1
  fi

  problems=$(jq -r '
    (.issues // []) as $is
    | ($is | map(.id)) as $ids
    | [
        ($is | group_by(.id)[] | select(length > 1) | "duplicate id \"\(.[0].id)\""),
        ($is[] | select((.id // "") == "") | "an issue has no id"),
        ($is[] | select((.title // "") == "") | "\(.id): no title"),
        ($is[] | . as $i
          | select((["ready","claimed","done"] | index($i.status // "")) == null)
          | "\($i.id): invalid status \"\($i.status // "")\""),
        ($is[] | . as $i
          | select((["haiku","sonnet","opus",""] | index($i.model // "")) == null)
          | "\($i.id): invalid model \"\($i.model)\" (expected haiku, sonnet, or opus)"),
        ($is[] | . as $i
          | select((($i.blocked_by // []) | index($i.id)) != null)
          | "\($i.id): blocks itself"),
        ($is[] | . as $i | ($i.blocked_by // [])[]
          | . as $b | select(($ids | index($b)) == null)
          | "\($i.id): unknown blocker \"\($b)\""),
        ($is[] | select(((.criteria // []) | length) == 0) | "\(.id): no criteria")
      ] | .[]
  ' "$SPEC")

  while IFS= read -r body; do
    [ -n "$body" ] || continue
    [ -f "$SPEC_DIR/$body" ] || problems+=$'\n'"missing body file $SPEC_DIR/$body"
  done < <(jq -r '.issues[] | select(.body != null and .body != "") | .body' "$SPEC")

  if [ -n "${problems//[[:space:]]/}" ]; then
    printf '\n%s✖%s  %s is malformed:\n\n' "$RED" "$RESET" "$SPEC" >&2
    while IFS= read -r problem; do
      [ -n "$problem" ] && printf '   %s·%s %s\n' "$RED" "$RESET" "$problem" >&2
    done <<<"$problems"
    printf '\n' >&2
    exit 1
  fi
}

[ "$MODE" = spec ] && validate_spec

# ── Issues ────────────────────────────────────────────────────────────────────
# Both modes emit the same board shape: [{number, id, title, state, wait}],
# where state is one of done | claimed | blocked | ready.
gh_issues() {
  gh api --paginate "repos/$SLUG/issues/$PARENT/sub_issues" \
    --jq '.[] | {number: (.number|tostring), id: (.number|tostring), title,
                 state: (if .state == "open" then "ready" else "done" end), wait: ""}' \
    2>/dev/null | jq -s '.'
}

# Blocked is derived, never stored: an issue is blocked while any id in its
# blocked_by is not yet done.
spec_issues() {
  jq '
    ((.issues // []) | map(select(.status == "done") | .id)) as $done
    | [ (.issues // []) | to_entries[]
        | .key as $k | .value as $i
        | (($i.blocked_by // []) - $done) as $wait
        | { number: (($k + 1) | tostring | if length < 2 then "0" + . else . end),
            id: $i.id,
            title: $i.title,
            state: (if $i.status == "done" then "done"
                    elif ($wait | length) > 0 then "blocked"
                    elif $i.status == "claimed" then "claimed"
                    else "ready" end),
            wait: ($wait | join(", ")) } ]
  ' "$SPEC"
}

issues() {
  if [ "$MODE" = gh ]; then gh_issues; else spec_issues; fi
}

# The frontier: first issue in array order that is not done and whose blockers
# are all done. Array order is the priority order /to-issues chose.
next_issue() {
  jq -r '
    ((.issues // []) | map(select(.status == "done") | .id)) as $done
    | (.issues // [])
    | map(select(.status != "done"))
    | map(select(all(.blocked_by[]?; . as $b | ($done | index($b)) != null)))
    | first // empty
    | [.id, (.body // ""), (.model // ""), .title] | join("")
  ' "$SPEC"
}

# Status and the ledger belong to the loop. The agent implements and reports;
# it never edits spec.json, so a crashed iteration cannot corrupt the graph.
write_spec() { # $1 jq filter, then jq args
  local filter=$1; shift
  local tmp; tmp=$(mktemp)
  if jq "$@" "$filter" "$SPEC" > "$tmp"; then
    mv "$tmp" "$SPEC"
  else
    rm -f "$tmp"
    die "failed to update $SPEC."
  fi
}

claim_issue() { # $1 id
  write_spec '(.issues[] | select(.id == $id) | .status) = "claimed"' --arg id "$1"
}

finish_issue() { # $1 id, $2 outcome
  write_spec '
    (.issues[] | select(.id == $id) | .status) = "done"
    | .ledger = ((.ledger // []) + [{id: $id, outcome: $outcome, at: $at}])
  ' --arg id "$1" --arg outcome "$2" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

render_board() { # $1 issues json, $2 iteration, $3 status line
  local board=$1 iter=$2 status=$3
  local total done_count open pct

  total=$(jq 'length' <<<"$board")
  done_count=$(jq '[.[] | select(.state == "done")] | length' <<<"$board")
  open=$((total - done_count))
  pct=$((total == 0 ? 0 : done_count * 100 / total))

  printf '\n'
  box_top
  box_line "${BOLD}${CYAN}◆ ${BOARD_LABEL}${RESET}  ${FG}$(trunc "$PARENT_TITLE" $((INNER - ${#BOARD_LABEL} - 4)))${RESET}"
  box_line "${DIM}$(trunc "$SOURCE_DETAIL" "$INNER")${RESET}"
  box_sep
  box_line "$(progress_bar "$done_count" "$total" $((INNER - 14)))  ${BOLD}${GREEN}${pct}%${RESET} ${DIM}${done_count}/${total}${RESET}"
  box_line ""

  local n t s w icon color note
  while IFS=$'\037' read -r n t s w; do
    [ -z "$n" ] && continue
    note=
    case "$s" in
      done)    icon="${GREEN}✔${RESET}"; color="$DIM" ;;
      claimed) icon="${YELLOW}◐${RESET}"; color="$FG" ;;
      blocked) icon="${DIM}○${RESET}"; color="$DIM"; note=" ${DIM}⇠ ${w}${RESET}" ;;
      *)       icon="${DIM}○${RESET}"; color="$FG" ;;
    esac
    box_line "  ${icon} ${DIM}${n}${RESET} ${color}$(trunc "$t" $((INNER - 10 - ${#n} - ${#w})))${RESET}${note}"
    # unit separator, not tab: tab is IFS whitespace, so bash would collapse
    # consecutive empty fields and shift every column left
  done < <(jq -r '.[] | [.number, .title, .state, .wait] | join("")' <<<"$board")

  box_sep
  box_line "${YELLOW}⟳${RESET} ${FG}iteration ${BOLD}${iter}${RESET}${DIM}/${MAX_ITERATIONS}${RESET}   ${MODEL_COLOR}◈ ${MODEL_LABEL}${RESET}   ${status}"
  box_bottom
  printf '\n'
}

# Everything the implementer gets about the effort as a whole. Deliberately
# small: the summary, the rules that constrain every issue, what earlier issues
# already built. The full context/ prose in spec.json is NOT injected.
spec_preamble() {
  jq -r '
    "Effort: \(.title)",
    "",
    .summary,
    (if ((.invariants // []) | length) > 0 then
       "", "Invariants — these hold for every issue in this effort:",
       (.invariants[] | "- " + .) else empty end),
    (if ((.out_of_scope // []) | length) > 0 then
       "", "Out of scope for this effort — do not build these:",
       (.out_of_scope[] | "- " + .) else empty end),
    (if ((.ledger // []) | length) > 0 then
       "", "Already delivered by earlier iterations:",
       (.ledger[] | "- \(.id): \(.outcome)") else empty end)
  ' "$SPEC"
}

issue_block() { # $1 id
  jq -r --arg id "$1" '
    ((.issues // [])[] | select(.id == $id)) as $i
    | "Ticket: \($i.id) — \($i.title)",
      "",
      "Done when:",
      ($i.criteria[] | "- " + .),
      (if (($i.files // []) | length) > 0 then
         "", "Start from: " + ($i.files | join(", ")) else empty end),
      (if ((.verification // []) | length) > 0 then
         "", "Must pass before you finish: " + (.verification | join(" && ")) else empty end)
  ' "$SPEC"
}

build_prompt() { # $1 id, $2 body path (may be empty)
  local id=$1 body=$2 rationale=

  [ -n "$body" ] && [ -f "$SPEC_DIR/$body" ] && rationale=$(cat "$SPEC_DIR/$body")

  cat <<EOF
$(spec_preamble)

────────────────────────────────────────
$(issue_block "$id")
${rationale:+
$rationale
}
────────────────────────────────────────

Rules for this iteration:
1. Implement ONLY this ticket. The effort's other tickets are deliberately not
   shown to you; do not go looking for them, and do not build ahead.
2. Run the verification commands above, plus this repo's type checks, before
   you finish. Report failures rather than working around them.${body:+
3. Append a short note under the "## Comments" heading of $SPEC_DIR/$body: what
   you did, and any decision a later ticket needs to know about.}
$([ -n "$body" ] && echo 4 || echo 3). Commit your work, referencing the ticket id "$id" in the message.
$([ -n "$body" ] && echo 5 || echo 4). Do NOT edit $SPEC. The loop owns issue status and the ledger.

End your final message with exactly one of these, on its own line:
  <promise>DONE:$id — one line naming what now exists, for the ledger</promise>
  <promise>BLOCKED:$id — what stopped you</promise>
EOF
}

banner() {
  printf '\n%s%s  ▄▄  claude loop%s%s  ·  %s  %s·%s %s◈ %s  %s\n' \
    "$BG_DARK" "$BOLD$MAGENTA" "$RESET$BG_DARK" "$TEAL" "$SOURCE_LABEL" "$DIM$BG_DARK" "$RESET$BG_DARK" \
    "$MODEL_COLOR" "$MODEL_LABEL" "$RESET"
}

banner

# --check validates the graph and shows the board without spending an iteration.
if [ -n "${CHECK_ONLY:-}" ]; then
  render_board "$(issues)" "0" "${GREEN}${BOLD}valid${RESET}"
  exit 0
fi

START=$(date +%s)

for ((i = 1; i <= MAX_ITERATIONS; i++)); do
  BOARD=$(issues)
  TOTAL=$(jq 'length' <<<"$BOARD")

  if [ "$TOTAL" -eq 0 ]; then
    die "$BOARD_LABEL has no issues to work through."
  fi

  OPEN=$(jq '[.[] | select(.state != "done")] | length' <<<"$BOARD")

  if [ "$OPEN" -eq 0 ]; then
    render_board "$BOARD" "$((i - 1))" "${GREEN}${BOLD}all issues done${RESET}"
    printf '%s✔%s  %sDone%s in %s%s%s after %s iteration(s).\n\n' \
      "$GREEN" "$RESET" "$BOLD" "$RESET" "$TEAL" "$(hms $(($(date +%s) - START)))" "$RESET" "$((i - 1))"
    exit 0
  fi

  # Picked before the board is drawn so the board's model chip names the model
  # this iteration will actually run on.
  ISSUE_ID=
  if [ "$MODE" = spec ]; then
    # The script picks, so the model spends no context deciding and the choice
    # is reproducible from the graph.
    # `|| true`: an empty frontier makes read fail, and set -e would kill the
    # run before the diagnostic below explains why
    IFS=$'\037' read -r ISSUE_ID ISSUE_BODY ISSUE_MODEL ISSUE_TITLE < <(next_issue) || true
    use_model "${ISSUE_MODEL:-$MODEL}"
  fi

  render_board "$BOARD" "$i" "${DIM}${OPEN} open${RESET}"

  if [ "$MODE" = gh ]; then
    SUB_LIST=$(jq -r '.[] | select(.state != "done") | "  - #\(.number): \(.title)"' <<<"$BOARD")
    PROMPT="Parent issue: $SOURCE_DETAIL ($SLUG#$PARENT — $PARENT_TITLE)
Open sub-issues:
$SUB_LIST
1. Run \`gh issue view <n> --repo $SLUG\` on the open sub-issues and pick the highest-priority one that is unblocked.
2. Implement it.
3. Run your tests and type checks.
4. Comment on that sub-issue with what was done, then close it with \`gh issue close <n> --repo $SLUG\`.
5. Commit your changes, referencing the sub-issue number in the commit message.
ONLY WORK ON A SINGLE SUB-ISSUE.
If every sub-issue of $SLUG#$PARENT is complete and closed, output <promise>COMPLETE</promise>."
  else
    if [ -z "$ISSUE_ID" ]; then
      printf '\n%s✖%s  %s issue(s) remain but none are workable — every one is blocked.\n\n' \
        "$RED" "$RESET" "$OPEN" >&2
      jq -r '.[] | select(.state == "blocked") | "   · \(.id) waits on \(.wait)"' <<<"$BOARD" >&2
      printf '\n   %sThat is a dependency cycle or a blocker id that never completes.%s\n\n' "$DIM" "$RESET" >&2
      exit 1
    fi

    printf '%s ◆%s %s%s%s  %s%s%s\n' "$CYAN" "$RESET" "$BOLD" "$ISSUE_ID" "$RESET" "$DIM" "$ISSUE_TITLE" "$RESET"
    claim_issue "$ISSUE_ID"
    PROMPT=$(build_prompt "$ISSUE_ID" "$ISSUE_BODY")
  fi

  # Transient API failures shouldn't kill an unattended run — retry the same
  # iteration with backoff. The spec holds the state, so a retry is safe.
  RESULT=
  ATTEMPT=1
  while :; do
    ITER_START=$(date +%s)
    OUT=$(mktemp)

    if [ "$ATTEMPT" -eq 1 ]; then
      printf '%s ╭─ %sclaude%s %s(%s)%s%s working…%s\n' "$DIM" "$BLUE" "$RESET" "$MODEL_COLOR" "$MODEL_LABEL" "$RESET" "$DIM" "$RESET"
    else
      printf '%s ╭─ %sclaude%s %s(%s)%s%s retry %s/%s…%s\n' "$DIM" "$BLUE" "$RESET" "$MODEL_COLOR" "$MODEL_LABEL" "$RESET" "$YELLOW" "$((ATTEMPT - 1))" "$RETRIES" "$RESET"
    fi

    set +e
    # `auto`, not `acceptEdits`: the loop needs gh/git/test commands, and in
    # non-interactive -p mode an unapprovable prompt is an automatic denial.
    $CLAUDE_CMD "${MODEL_ARGS[@]}" --permission-mode "$PERMISSION_MODE" \
      --output-format stream-json --verbose -p "$PROMPT" 2>&1 | tee "$OUT" | stream_render
    STATUS=${PIPESTATUS[0]}
    set -e

    RAW=$(cat "$OUT"); rm -f "$OUT"
    # the final assistant text lives in the terminating result event
    RESULT=$(jq -Rr 'fromjson? | select(.type == "result") | (.result // "")' <<<"$RAW" 2>/dev/null || true)
    [ -z "$RESULT" ] && RESULT="$RAW"
    IS_ERROR=$(jq -Rr 'fromjson? | select(.type == "result") | (.is_error // false)' <<<"$RAW" 2>/dev/null | tail -1)

    printf '%s ╰─ %s%s%s\n' "$DIM" "$ORANGE" "$(hms $(($(date +%s) - ITER_START)))" "$RESET"

    # claude sometimes prints an API error and still exits 0
    if [ "$STATUS" -eq 0 ] && [ "$IS_ERROR" != "true" ] && [[ "$RAW" != *"API Error"* ]]; then
      break
    fi

    REASON="exit status $STATUS"
    [ "$STATUS" -eq 0 ] && REASON="API error mid-response"

    if [ "$ATTEMPT" -gt "$RETRIES" ]; then
      printf '\n%s✖%s  claude failed (%s) on iteration %s after %s retries.\n' "$RED" "$RESET" "$REASON" "$i" "$RETRIES" >&2
      printf '   %sNothing was committed by the failed attempt; rerun to resume.%s\n\n' "$DIM" "$RESET" >&2
      exit 1
    fi

    BACKOFF=$((RETRY_DELAY * ATTEMPT))
    printf '%s ⚠%s  %s — retrying in %ss (%s/%s)\n' "$YELLOW" "$RESET" "$REASON" "$BACKOFF" "$ATTEMPT" "$RETRIES"
    sleep "$BACKOFF"
    ATTEMPT=$((ATTEMPT + 1))
  done

  if [ "$MODE" = gh ]; then
    if [[ "$RESULT" == *"<promise>COMPLETE</promise>"* ]]; then
      render_board "$(issues)" "$i" "${GREEN}${BOLD}COMPLETE${RESET}"
      printf '%s✔%s  %s %scomplete%s in %s%s%s after %s iteration(s).\n\n' \
        "$GREEN" "$RESET" "$BOARD_LABEL" "$BOLD" "$RESET" "$TEAL" "$(hms $(($(date +%s) - START)))" "$RESET" "$i"
      exit 0
    fi
  else
    # An explicit BLOCKED is the agent telling us the graph is wrong or the
    # ticket is unbuildable. Retrying that burns the cap for nothing.
    if [[ "$RESULT" =~ \<promise\>BLOCKED:[[:space:]]*([A-Za-z0-9_-]+)[^\<]*\</promise\> ]]; then
      printf '\n%s✖%s  %s reported blocked on %s%s%s:\n\n' \
        "$RED" "$RESET" "claude" "$BOLD" "$ISSUE_ID" "$RESET" >&2
      print_message "$RESULT" >&2
      printf '\n   %sspec.json is unchanged apart from status=claimed on %s.%s\n\n' "$DIM" "$ISSUE_ID" "$RESET" >&2
      exit 1
    fi

    if [[ "$RESULT" =~ \<promise\>DONE:[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*[^A-Za-z0-9\<]*([^\<]*)\</promise\> ]]; then
      DONE_ID="${BASH_REMATCH[1]}"
      OUTCOME=$(printf '%s' "${BASH_REMATCH[2]}" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      [ -n "$OUTCOME" ] || OUTCOME="completed"

      if [ "$DONE_ID" != "$ISSUE_ID" ]; then
        printf '%s ⚠%s  promise names %q but the assigned ticket was %q — not recording it.\n' \
          "$YELLOW" "$RESET" "$DONE_ID" "$ISSUE_ID"
      else
        finish_issue "$ISSUE_ID" "$OUTCOME"
        printf '%s ✔%s %s%s%s  %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$ISSUE_ID" "$RESET" "$DIM" "$OUTCOME" "$RESET"
      fi
    fi
  fi

  # An iteration that finishes nothing means claude is stuck (blocked on
  # permissions, missing context, …). Repeating it just burns the cap, so
  # surface what it said and stop.
  OPEN_AFTER=$(jq '[.[] | select(.state != "done")] | length' <<<"$(issues)")
  if [ "$OPEN_AFTER" -ge "$OPEN" ]; then
    NO_PROGRESS=$((NO_PROGRESS + 1))
    printf '%s ⚠%s  nothing was completed this iteration (%s/%s)\n' "$YELLOW" "$RESET" "$NO_PROGRESS" "$STALL_LIMIT"
    if [ "$NO_PROGRESS" -ge "$STALL_LIMIT" ]; then
      printf '\n%s✖%s  Stalled: %s iteration(s) completed nothing. claude'"'"'s last message:\n\n' \
        "$RED" "$RESET" "$NO_PROGRESS" >&2
      print_message "$RESULT" >&2
      printf '\n' >&2
      exit 1
    fi
  else
    NO_PROGRESS=0
  fi
done

FINAL=$(issues)
FINAL_OPEN=$(jq '[.[] | select(.state != "done")] | length' <<<"$FINAL")

if [ "$FINAL_OPEN" -eq 0 ]; then
  render_board "$FINAL" "$MAX_ITERATIONS" "${GREEN}${BOLD}all issues done${RESET}"
  printf '%s✔%s  %sDone%s in %s%s%s after %s iteration(s).\n\n' \
    "$GREEN" "$RESET" "$BOLD" "$RESET" "$TEAL" "$(hms $(($(date +%s) - START)))" "$RESET" "$MAX_ITERATIONS"
  exit 0
fi

# Hitting a cap the user asked for is a normal stop, not a failure; hitting the
# default runaway guard is worth an error.
if [ -n "$ITERATIONS" ]; then
  render_board "$FINAL" "$MAX_ITERATIONS" "${YELLOW}${BOLD}${MAX_ITERATIONS} iteration(s) done${RESET}"
  printf '%s◆%s  Ran the requested %s iteration(s) in %s%s%s; %s issue(s) still open.\n\n' \
    "$CYAN" "$RESET" "$MAX_ITERATIONS" "$TEAL" "$(hms $(($(date +%s) - START)))" "$RESET" "$FINAL_OPEN"
  exit 0
fi

render_board "$FINAL" "$MAX_ITERATIONS" "${RED}${BOLD}iteration cap reached${RESET}"
printf '%s✖%s  Stopped after %s iterations; %s issue(s) still open.\n\n' \
  "$RED" "$RESET" "$MAX_ITERATIONS" "$FINAL_OPEN" >&2
exit 1
