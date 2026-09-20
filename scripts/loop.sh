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
Usage: $0 <spec-dir|spec.json> [max-iterations] [--model <model>] [--check]

Works through a spec one issue per iteration until every issue is done.

  $0 specs/lab-modeling-v2
  $0 specs/lab-modeling-v2/spec.json 10
  $0 specs/lab-modeling-v2 --check     # validate + show the board, run nothing
  $0 specs/lab-modeling-v2 --model opus

Reads a spec.json written by /to-spec and /to-issues. The script — not the
model — picks the next issue (first in array order whose blockers are all
done), injects only that issue plus the spec's summary/invariants/ledger, and
records the result. The agent never edits spec.json — the loop snapshots the
file before each iteration and reverts (and fails) any iteration that does.

An issue is recorded done only when the agent promises DONE, every command in
the spec's "verification" array (plus the issue's own "verification" commands,
when present) exits 0, AND a clean-context review (a second,
independent claude call that never saw the implementation) confirms the diff
meets the ticket's criteria. A promise alone is not enough: the loop runs the
checks itself. A failed iteration is recorded on the issue and replayed into
the next attempt's prompt, so a fresh context window does not repeat an
approach that already failed.

An issue may carry a "model" field ("haiku" | "sonnet" | "opus" | "fable", or
empty for the default) to override --model/CLAUDE_MODEL for that iteration only.

--model also accepts a model id served by Aperture, the internal AI gateway
(e.g. "claude-opus-4-8", "claude-fable-5"). Anything that is not one of the
four aliases is validated against the gateway's live provider list, and the
whole run — including the judge — is routed through the gateway by exporting
ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN. Only models the gateway serves on the
Anthropic Messages API qualify (claude speaks nothing else); its GPT, Gemini,
and open-weights models live on other wire protocols and are rejected with a
pointer. Per-issue "model" fields stay alias-only.

Env:
  MAX_ITERATIONS   default iteration cap (default: 50)
  MAX_COST         stop before starting an iteration once this many dollars
                   have been spent (default: no limit)
  CLAUDE_MODEL     default model, overridable per issue (default: whatever
                   claude is configured with)
  CLAUDE_CMD       command used to run claude (default: "claude")
  RETRIES          retries per iteration on API errors (default: 3)
  RETRY_DELAY      base backoff seconds, multiplied per attempt (default: 20)
  STALL_LIMIT      stop after N iterations that finish nothing (default: 2)
  ISSUE_ATTEMPT_LIMIT
                   stop once one issue has failed this many times (default: 3)
  JUDGE_MODEL      model used for the clean-context criteria review after
                   verification passes (default: sonnet; empty disables it)
  ESCALATE         set to 1 to bump the model a tier (haiku→sonnet→opus) when
                   retrying an issue that already failed (default: off)
  PERMISSION_MODE  claude --permission-mode (default: auto; the loop needs
                   git/test commands, which acceptEdits does not cover)
  APERTURE_URL     the Aperture gateway used for non-alias models
                   (default: http://ai.civet-hops.ts.net)
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
  local t=$1 m=$2
  # a caller's budget can go negative when other columns overrun the line;
  # a negative substring length is a bash error, not a short string
  [ "$m" -lt 1 ] && m=1
  if [ "${#t}" -gt "$m" ]; then printf '%s…' "${t:0:$((m - 1))}"; else printf '%s' "$t"; fi
}

box_top()    { printf '%s╭%s╮%s\n' "$MAGENTA" "$(repeat '─' $((WIDTH - 2)))" "$RESET"; }
box_bottom() { printf '%s╰%s╯%s\n' "$MAGENTA" "$(repeat '─' $((WIDTH - 2)))" "$RESET"; }
box_sep()    { printf '%s├%s┤%s\n' "$MAGENTA" "$(repeat '─' $((WIDTH - 2)))" "$RESET"; }
box_line() { # $1 already-colored content
  local pad=$((INNER - $(vlen "$1")))
  [ "$pad" -lt 0 ] && pad=0
  printf '%s│%s %s%s %s│%s\n' "$MAGENTA" "$RESET" "$1" "$(repeat ' ' "$pad")" "$MAGENTA" "$RESET"
}

# One iteration per screen. Without this the previous board and its stream rail
# sit directly above the new ones, so a single window shows two progress boxes
# and two rails. A window's worth of blank lines scrolls the old frame out of
# view while leaving it in scrollback.
new_screen() {
  [ "$STREAM_TTY" -eq 1 ] || return 0
  repeat $'\n' "$(tput lines 2>/dev/null || echo 50)"
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
      [ -z "$2" ] && die "--model requires a value (haiku|sonnet|opus|fable, or an Aperture model id)."
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

# Which agent CLI runs the iterations. Aliases run claude as configured.
# Anything else is resolved in order:
#   1. an opencode provider/model ref (e.g. crusoe/zai/GLM-5.2) — this is how
#      non-Claude models are reached, since claude speaks only the Anthropic
#      Messages API and the gateways do not translate wire protocols;
#   2. a Claude model id served on the Messages API by Aperture, the internal
#      AI gateway — routed there by env for the whole run, judge included.
# The judge stays on claude in opencode mode (no env is exported), so criteria
# review keeps running on the subscription regardless of who implements.
APERTURE_URL="${APERTURE_URL:-http://ai.civet-hops.ts.net}"
OPENCODE_CMD="${OPENCODE_CMD:-opencode}"
HARNESS=claude

case "$MODEL" in
  haiku|sonnet|opus|fable|"") ;;
  *)
    OPENCODE_MODELS=$(command -v "$OPENCODE_CMD" >/dev/null 2>&1 \
      && "$OPENCODE_CMD" models 2>/dev/null || true)
    if grep -qxF "$MODEL" <<<"$OPENCODE_MODELS"; then
      HARNESS=opencode
    else
      # the first hit on the tailnet host can time out cold, hence the retries
      APERTURE_PROVIDERS=$(curl -fsS --retry 2 --retry-connrefused --retry-all-errors \
          --connect-timeout 5 --max-time 15 "$APERTURE_URL/api/providers" 2>/dev/null || true)
      jq -e . >/dev/null 2>&1 <<<"$APERTURE_PROVIDERS" || \
        die "unknown model $MODEL — not an alias, not an opencode ref (see: opencode models), and $APERTURE_URL is unreachable to check the gateway's model list."

      APERTURE_OK=$(jq -r '.[] | select(.compatibility.anthropic_messages) | .models[]' <<<"$APERTURE_PROVIDERS")
      if grep -qxF "$MODEL" <<<"$APERTURE_OK"; then
        export ANTHROPIC_BASE_URL="$APERTURE_URL"
        export ANTHROPIC_AUTH_TOKEN="-"
      else
        printf '\n%s✖%s  %s is not an alias, an opencode ref, or a Claude model on Aperture.\n' \
          "$RED" "$RESET" "$MODEL" >&2
        # a bare gateway id like zai/GLM-5.2 usually means the opencode ref
        # (crusoe/zai/GLM-5.2) was intended — suggest the matches
        HINTS=$(grep -F "/$MODEL" <<<"$OPENCODE_MODELS" || true)
        if [ -n "$HINTS" ]; then
          printf '\n   Did you mean one of these opencode refs?\n' >&2
          printf '%s\n' "$HINTS" | sed 's/^/   · /' >&2
        fi
        printf '\n   %sRun `opencode models` for non-Claude models; Claude models on\n' "$DIM" >&2
        printf '   Aperture: %s%s\n\n' "$(paste -sd' ' - <<<"$APERTURE_OK")" "$RESET" >&2
        exit 1
      fi
    fi
    ;;
esac

MAX_ITERATIONS="${ITERATIONS:-${MAX_ITERATIONS:-50}}"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
RETRIES="${RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-20}"
STALL_LIMIT="${STALL_LIMIT:-2}"
ISSUE_ATTEMPT_LIMIT="${ISSUE_ATTEMPT_LIMIT:-3}"
JUDGE_MODEL="${JUDGE_MODEL-sonnet}"
ESCALATE="${ESCALATE:-0}"
PERMISSION_MODE="${PERMISSION_MODE:-auto}"

# The derived tool allowlist (regenerated by hooks/refresh-tools.sh) scopes
# what an unattended iteration can do without a permission prompt — auto mode
# alone would otherwise be the only guard on the whole run. Missing file just
# means no allowlist, matching loop-once.sh and the cc alias.
ALLOWED_TOOLS_ARGS=()
if [ -f ~/.claude-allowed-tools.txt ]; then
  ALLOWED_TOOLS=$(grep -v '^#' ~/.claude-allowed-tools.txt | grep -v '^$' | paste -s -d ',' -)
  [ -n "$ALLOWED_TOOLS" ] && ALLOWED_TOOLS_ARGS=(--allowedTools "$ALLOWED_TOOLS")
fi
NO_PROGRESS=0
SPENT=0

# Iterations are traceable only inside a repo, but the loop still runs outside
# one — every git call is guarded by this.
IS_GIT=0
git rev-parse --git-dir >/dev/null 2>&1 && IS_GIT=1

head_sha() { [ "$IS_GIT" -eq 1 ] && git rev-parse HEAD 2>/dev/null || true; }

# Paths dirty in the working tree, sorted for comm(1).
dirty_paths() {
  [ "$IS_GIT" -eq 1 ] || return 0
  git status --porcelain 2>/dev/null | cut -c4- | sort
}

# Paths dirty now that were not dirty when the iteration started. Verification
# runs against the working tree while the ledger records a commit; anything
# here means those two states differ — classically a new file the agent
# created but never git-added, which lets the checks pass on a tree the
# commit doesn't reproduce. Compared by path, so a file that was already
# dirty before the iteration never triggers this.
new_dirt() {
  [ "$IS_GIT" -eq 1 ] || return 0
  comm -13 <(printf '%s\n' "$DIRTY_BEFORE") <(dirty_paths)
}

# What an iteration actually left behind. The old message asserted "nothing was
# committed" without checking, which is false whenever an agent commits and then
# dies on the next tool call.
report_commits() { # $1 sha before the iteration
  local before=$1 after n
  [ "$IS_GIT" -eq 1 ] && [ -n "$before" ] || return 0
  after=$(head_sha)

  if [ "$after" = "$before" ]; then
    printf '   %sNothing was committed; the working tree may still hold partial work.%s\n' "$DIM" "$RESET"
    return 0
  fi

  n=$(git rev-list --count "$before..$after" 2>/dev/null || echo "?")
  printf '   %s%s commit(s) landed: %s..%s%s\n' "$DIM" "$n" "${before:0:7}" "${after:0:7}" "$RESET"
  printf '   %sTo discard them:  git reset --hard %s%s\n' "$DIM" "${before:0:7}" "$RESET"
}

# bash has no floats; jq is already a hard dependency, so the money lives there.
add_cost() { # $1 addend
  SPENT=$(jq -n --arg a "$SPENT" --arg b "${1:-0}" \
    '(($a | tonumber) + ($b | tonumber)) * 10000 | round / 10000')
}

over_budget() {
  [ -n "${MAX_COST:-}" ] || return 1
  [ "$(jq -n --arg s "$SPENT" --arg m "$MAX_COST" \
        '(($s | tonumber) >= ($m | tonumber))')" = "true" ]
}

cost_chip() {
  [ "$(jq -n --arg s "$SPENT" '($s | tonumber) > 0')" = "true" ] || return 0
  printf '   %s$%s%s%s' "$DIM" "$SPENT" "${MAX_COST:+/$MAX_COST}" "$RESET"
}

spend_note() {
  [ "$(jq -n --arg s "$SPENT" '($s | tonumber) > 0')" = "true" ] || return 0
  printf ' %s($%s spent)%s' "$DIM" "$SPENT" "$RESET"
}

if [ -n "$ITERATIONS" ] && ! [[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
  die "max-iterations must be a positive integer, got $ITERATIONS."
fi

if [ -n "${MAX_COST:-}" ] && ! [[ "$MAX_COST" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  die "MAX_COST must be a number of dollars, got $MAX_COST."
fi

if ! [[ "$ISSUE_ATTEMPT_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  die "ISSUE_ATTEMPT_LIMIT must be a positive integer, got $ISSUE_ATTEMPT_LIMIT."
fi

# The model in force for the next iteration. An issue's "model" field beats
# this default for its iteration only, so one run can put cheap tickets on
# haiku without splitting into several runs. Per-issue values are alias-only,
# so they always run claude — only the run default can be the opencode harness.
use_model() { # $1 model name, "" = whatever claude is configured with
  MODEL_ARGS=()
  ITER_HARNESS=claude
  [ -n "$1" ] && MODEL_ARGS=(--model "$1")
  [ -n "$1" ] && [ "$1" = "$MODEL" ] && ITER_HARNESS="$HARNESS"
  MODEL_LABEL="${1:-default}"
  case "$1" in
    opus)   MODEL_COLOR="$MAGENTA" ;;
    sonnet) MODEL_COLOR="$BLUE" ;;
    haiku)  MODEL_COLOR="$TEAL" ;;
    fable)  MODEL_COLOR="$ORANGE" ;;
    "")     MODEL_COLOR="$DIM" ;;
    *)      MODEL_COLOR="$GREEN" ;;  # Aperture gateway model
  esac
}

use_model "$MODEL"

[ -n "$TARGET" ] || { usage >&2; die "no spec path given."; }

# ── Parent: spec.json ─────────────────────────────────────────────────────────
# Written by /to-spec (context only) and /to-issues (the issues array). See
# ~/.claude/skills/to-spec/resources/spec.schema.json.
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
          | select((["haiku","sonnet","opus","fable",""] | index($i.model // "")) == null)
          | "\($i.id): invalid model \"\($i.model)\" (expected haiku, sonnet, opus, or fable)"),
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

  # Cycles are checked separately, and only once the above is clean: an unknown
  # blocker also makes its dependents unsettleable, which would report a cycle
  # that isn't there. Kahn's algorithm — peel off issues whose blockers are all
  # settled until nothing more can be; whatever remains is a cycle or downstream
  # of one. Status is ignored: a cyclic graph is malformed even when part of it
  # has already been built.
  local cyclic
  cyclic=$(jq -r '
    { rest: [ (.issues // [])[] | {id: .id, b: (.blocked_by // [])} ], settled: [] }
    | until(
        . as $s
        | ($s.rest
           | map(select(all(.b[]; . as $x | ($s.settled | index($x)) != null)))
           | length) == 0;
        . as $s
        | ($s.rest
           | map(select(all(.b[]; . as $x | ($s.settled | index($x)) != null)))
           | map(.id)) as $ready
        | { rest:    ($s.rest | map(. as $i | select(($ready | index($i.id)) == null))),
            settled: ($s.settled + $ready) })
    | .rest | map(.id) | join(", ")
  ' "$SPEC")

  if [ -n "$cyclic" ]; then
    printf '\n%s✖%s  %s has a dependency cycle.\n\n' "$RED" "$RESET" "$SPEC" >&2
    printf '   %sUnreachable: %s%s\n' "$RED" "$cyclic" "$RESET" >&2
    printf '\n   %sThose issues can never all become workable. Break the cycle by\n' "$DIM" >&2
    printf '   removing a blocked_by edge that encodes preference, not necessity.%s\n\n' "$RESET" >&2
    exit 1
  fi
}

validate_spec

# ── Issues ────────────────────────────────────────────────────────────────────
# The board shape is [{number, id, title, state, wait}], where state is one of
# done | claimed | blocked | ready.
#
# Blocked is derived, never stored: an issue is blocked while any id in its
# blocked_by is not yet done.
issues() {
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

# claim_sha is the HEAD the issue's work started from, and it survives a
# restart. Without it, a run killed between commit and ledger update loses the
# only record that the work landed: the next pass finds the ticket already
# implemented, correctly commits nothing, and the no-commit gate rejects it
# forever. Set once per claim — a re-attempt on a still-claimed issue keeps the
# original baseline so the whole of its work stays in view.
claim_issue() { # $1 id
  write_spec '
    (.issues[] | select(.id == $id)) |= (
      .status = "claimed"
      | (if (.claim_sha // "") == "" then .claim_sha = $sha else . end))
  ' --arg id "$1" --arg sha "$(head_sha)"
}

claim_sha() { # $1 id
  jq -r --arg id "$1" '(.issues // [])[] | select(.id == $id) | .claim_sha // ""' "$SPEC"
}

finish_issue() { # $1 id, $2 outcome, $3 commit sha (may be empty)
  write_spec '
    (.issues[] | select(.id == $id)) |= (.status = "done" | del(.claim_sha))
    | .ledger = ((.ledger // []) + [
        {id: $id, outcome: $outcome, at: $at}
        + (if $commit == "" then {} else {commit: $commit} end)])
  ' --arg id "$1" --arg outcome "$2" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg commit "$3"
}

# A fresh context window is the point, but it also means the next attempt on a
# failed ticket knows nothing about the last one and will happily repeat it.
# Recording the failure here is what issue_block replays back into the prompt.
record_attempt() { # $1 id, $2 reason, $3 detail
  local detail
  detail=$(printf '%s' "$3" | tr '\n\t' '  ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//')
  [ "${#detail}" -gt 400 ] && detail="${detail:0:399}…"
  write_spec '
    (.issues[] | select(.id == $id) | .attempts) =
      (((.issues[] | select(.id == $id) | .attempts) // [])
       + [{reason: $reason, detail: $detail, at: $at}])
  ' --arg id "$1" --arg reason "$2" --arg detail "$detail" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

attempt_count() { # $1 id
  jq --arg id "$1" '[(.issues // [])[] | select(.id == $id) | (.attempts // [])[]] | length' "$SPEC"
}

# The gate. A DONE promise is a claim; this is the check. Runs in the loop's cwd,
# which is the same cwd claude just worked in. Effort-level commands first, then
# the issue's own — a criterion backed by a per-issue command is checked here
# deterministically rather than left to the diff review alone.
VERIFY_FAILURE=
run_verification() { # $1 issue id (may be empty)
  local cmd out status
  VERIFY_FAILURE=

  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    printf '%s ⋯%s %s%s%s\n' "$DIM" "$RESET" "$DIM" "$(trunc "$cmd" $((WIDTH - 8)))" "$RESET"

    set +e
    out=$(bash -c "$cmd" 2>&1)
    status=$?
    set -e

    # One immediate retry before a failure counts: a flaky test would otherwise
    # be recorded as this issue's failed attempt, and the replay would then
    # warn the next fresh context off an approach that was actually fine.
    if [ "$status" -ne 0 ]; then
      printf '%s ⚠%s %s%s exited %s — retrying once in case it is flaky%s\n' \
        "$YELLOW" "$RESET" "$DIM" "$(trunc "$cmd" $((WIDTH - 40)))" "$status" "$RESET"
      set +e
      out=$(bash -c "$cmd" 2>&1)
      status=$?
      set -e
      [ "$status" -eq 0 ] && printf '%s ⚠%s %spassed on retry — that command is flaky%s\n' \
        "$YELLOW" "$RESET" "$DIM" "$RESET"
    fi

    if [ "$status" -ne 0 ]; then
      printf '%s ✖%s %s%s%s %s(exit %s)%s\n' "$RED" "$RESET" "$FG" "$cmd" "$RESET" "$DIM" "$status" "$RESET"
      printf '%s' "$out" | tail -15 | while IFS= read -r l; do
        printf '   %s%s%s\n' "$DIM" "$(trunc "$l" $((WIDTH - 6)))" "$RESET"
      done
      VERIFY_FAILURE="$cmd (exit $status, failed twice)"
      local tail_out
      tail_out=$(printf '%s' "$out" | tail -3 | tr '\n' ' ')
      [ -n "${tail_out//[[:space:]]/}" ] && VERIFY_FAILURE="$VERIFY_FAILURE — $tail_out"

      # The prompt only ever sees a 3-line tail; the full output is what a
      # retry actually needs to diagnose a failure it didn't cause.
      if [ -n "$ISSUE_ID" ]; then
        local log_name
        log_name="$ISSUE_ID-$(($(attempt_count "$ISSUE_ID") + 1)).log"
        mkdir -p "$SPEC_DIR/attempts"
        printf '%s' "$out" > "$SPEC_DIR/attempts/$log_name"
        VERIFY_FAILURE="$VERIFY_FAILURE — full output: attempts/$log_name"
      fi

      return 1
    fi
  done < <(jq -r --arg id "${1:-}" '
    (.verification // [])[],
    ((.issues // [])[] | select(.id == $id) | (.verification // [])[])
  ' "$SPEC")

  return 0
}

# A second, independent claude call that reviews the diff against the ticket's
# criteria with no memory of writing it. Verification only proves the commands
# in "verification" exit 0; it says nothing about whether the diff actually did
# what the ticket asked for. Guarded so a judge outage degrades to "trust
# verification" rather than blocking every iteration.
JUDGE_REASON=
# A heredoc apostrophe inside `x=$(cat <<EOF ...)` confuses bash's parser (it
# tries to balance quotes across the substitution); a separate function whose
# own stdout is captured sidesteps that.
judge_prompt() { # $1 criteria bullets, $2 invariants bullets (may be empty), $3 diff, $4 truncation note (may be empty)
  cat <<EOF
You are reviewing a diff against a ticket's acceptance criteria. You did not
write this code. Judge only what the diff shows — do not assume unstated work
exists.

Criteria:
$1
EOF

  [ -n "$2" ] && cat <<EOF

Effort-wide invariants — a diff that violates any of these FAILS even when
every criterion is met:
$2
EOF

  [ -n "$4" ] && printf '\n%s\n' "$4"

  cat <<EOF

A diff that deletes, skips, or weakens existing tests to satisfy the criteria
FAILS, unless a criterion explicitly calls for that change.

Diff:
$3

End with exactly one line: VERDICT: PASS  or  VERDICT: FAIL — <which criterion or invariant, why>
EOF
}

judge_criteria() { # $1 issue id, $2 sha before this iteration
  local id=$1 before=$2 diff stat criteria invariants prompt out verdict trunc_note=
  JUDGE_REASON=

  [ -n "$JUDGE_MODEL" ] || return 0
  [ "$IS_GIT" -eq 1 ] || return 0
  [ -n "$before" ] || return 0

  # Read one byte past the cap: its presence proves truncation without ever
  # holding the full diff in memory.
  diff=$(git diff "$before"..HEAD 2>/dev/null | head -c 60001)
  [ -n "$diff" ] || return 0
  if [ "$(printf '%s' "$diff" | wc -c)" -gt 60000 ]; then
    diff="${diff:0:60000}"
    # The file list restores what truncation hides: a touched test or config
    # file whose hunks fell past the cutoff should draw suspicion, not a pass.
    stat=$(git diff --stat "$before"..HEAD 2>/dev/null | head -c 4000)
    trunc_note="NOTE: the diff below is TRUNCATED at 60,000 characters — it is not the whole
change. Every file it touches:

$stat

Judge what is shown; if a criterion's evidence could plausibly lie beyond the
cutoff, say so in your verdict rather than failing it outright. But treat a
test or config file listed above whose changes are not visible below as
grounds for suspicion, not a pass."
  fi

  criteria=$(jq -r --arg id "$id" '
    (.issues // [])[] | select(.id == $id) | (.criteria // [])[] | "- " + .
  ' "$SPEC")
  invariants=$(jq -r '(.invariants // [])[] | "- " + .' "$SPEC")

  printf '%s ⋯%s %sreviewing diff against criteria (%s)%s\n' "$DIM" "$RESET" "$DIM" "$JUDGE_MODEL" "$RESET"

  prompt=$(judge_prompt "$criteria" "$invariants" "$diff" "$trunc_note")

  set +e
  out=$($CLAUDE_CMD --model "$JUDGE_MODEL" --output-format json -p "$prompt" 2>&1)
  set -e

  verdict=$(jq -r '.result // ""' <<<"$out" 2>/dev/null || true)
  [ -n "$verdict" ] || verdict="$out"
  add_cost "$(jq -r '.total_cost_usd // empty' <<<"$out" 2>/dev/null || true)"

  [[ "$verdict" == *"VERDICT: PASS"* ]] && return 0

  JUDGE_REASON=$(grep -o 'VERDICT: FAIL.*' <<<"$verdict" | head -1)
  if [ -z "$JUDGE_REASON" ]; then
    # No verdict either way means the judge call itself failed (API error,
    # refusal), not that the diff failed review. Trust verification rather
    # than burning an attempt toward the circuit breaker on an infra blip.
    printf '%s ⚠%s  %sjudge returned no verdict — trusting verification%s\n' "$YELLOW" "$RESET" "$DIM" "$RESET"
    return 0
  fi
  return 1
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

  local n t s w icon color note wt tmax nmax
  while IFS=$'\037' read -r n t s w; do
    [ -z "$n" ] && continue
    note= wt=
    case "$s" in
      done)    icon="${GREEN}✔${RESET}"; color="$DIM" ;;
      claimed) icon="${YELLOW}◐${RESET}"; color="$FG" ;;
      blocked)
        icon="${DIM}○${RESET}"; color="$DIM"
        # a fan-in issue can wait on every slug before it; cap the dep list at
        # half the line so the title always keeps a readable share
        nmax=$((INNER - 13 - ${#n} - 8))
        [ "$nmax" -gt $((INNER / 2)) ] && nmax=$((INNER / 2))
        wt=$(trunc "$w" "$nmax")
        note=" ${DIM}⇠ ${wt}${RESET}"
        ;;
      *)       icon="${DIM}○${RESET}"; color="$FG" ;;
    esac
    tmax=$((INNER - 10 - ${#n} - ${#wt}))
    [ -n "$wt" ] && tmax=$((tmax - 3))
    box_line "  ${icon} ${DIM}${n}${RESET} ${color}$(trunc "$t" "$tmax")${RESET}${note}"
    # unit separator, not tab: tab is IFS whitespace, so bash would collapse
    # consecutive empty fields and shift every column left
  done < <(jq -r '.[] | [.number, .title, .state, .wait] | join("")' <<<"$board")

  box_sep
  box_line "${YELLOW}⟳${RESET} ${FG}iteration ${BOLD}${iter}${RESET}${DIM}/${MAX_ITERATIONS}${RESET}   ${MODEL_COLOR}◈ ${MODEL_LABEL}${RESET}$(cost_chip)   ${status}"
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
       (.ledger[] | "- \(.id): \(.outcome)\(if (.commit // "") == "" then "" else " (commit \(.commit[0:7]))" end)")
     else empty end)
  ' "$SPEC"

  # Repo-level scratchpad the agent writes to itself (see the NOTES.md rule in
  # build_prompt) — not part of spec.json, so it's read from disk here instead
  # of via jq.
  if [ -s "$SPEC_DIR/NOTES.md" ]; then
    printf '\nRepo-level notes left by earlier iterations:\n%s\n' "$(tail_notes "$SPEC_DIR/NOTES.md" "$NOTES_CAP")"
  fi
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
      (((.verification // []) + ($i.verification // [])) as $checks
       | if ($checks | length) > 0 then
         "", "Must pass before you finish: " + ($checks | join(" && ")),
         "The loop runs these itself after you report done; promising DONE while",
         "they fail does not complete the ticket." else empty end),
      (if ((($i.attempts // []) | length) > 0) then
         "",
         "This ticket has been attempted before and did not complete:",
         (($i.attempts // []) | .[-2:][]
          | "- \(.reason)\(if (.detail // "") == "" then "" else ": " + .detail end)"),
         "Do not repeat those approaches. If the ticket cannot be built as written,",
         "say so in a BLOCKED promise rather than trying again the same way."
       else empty end)
  ' "$SPEC"
}

BLOCKER_NOTES_CAP=1500
NOTES_CAP=2000

# Last $2 characters of $1, but never starting mid-line: the byte cut from
# `tail -c` can land inside a line, so the partial first line is dropped once
# the file is actually larger than the cap.
tail_notes() { # $1 path, $2 cap
  local path=$1 cap=$2 size
  size=$(wc -c <"$path" 2>/dev/null | tr -d ' ')
  if [ -n "$size" ] && [ "$size" -gt "$cap" ]; then
    tail -c "$cap" "$path" | tail -n +2
  else
    cat "$path"
  fi
}

# The agent is asked to leave notes under "## Comments" for whoever builds on its
# work. This is who reads them: the direct blockers only. The ledger already
# carries a one-liner for every finished issue, so walking the full transitive
# closure would buy repetition at a cost that grows with graph depth.
blocker_notes() { # $1 id
  local blocker body path notes out= total=0

  while IFS= read -r blocker; do
    [ -n "$blocker" ] || continue

    body=$(jq -r --arg b "$blocker" '
      (.issues // [])[] | select(.id == $b and .status == "done") | (.body // "")
    ' "$SPEC")
    [ -n "$body" ] || continue

    path="$SPEC_DIR/$body"
    [ -f "$path" ] || continue

    # everything after the "## Comments" heading, with leading and trailing blank
    # lines dropped and interior ones kept
    notes=$(awk '
      /^## Comments[[:space:]]*$/ { f = 1; next }
      !f                          { next }
      /^[[:space:]]*$/            { if (n) blank++; next }
                                  { while (blank-- > 0) line[n++] = ""; blank = 0
                                    line[n++] = $0 }
      END                         { for (i = 0; i < n; i++) print line[i] }
    ' "$path")
    [ -n "${notes//[[:space:]]/}" ] || continue

    if [ "$((total + ${#notes}))" -gt "$BLOCKER_NOTES_CAP" ]; then
      notes="${notes:0:$((BLOCKER_NOTES_CAP - total))}
… (truncated; full notes in $path)"
    fi

    out="$out[$blocker]
$notes

"
    total=$((total + ${#notes}))
    [ "$total" -ge "$BLOCKER_NOTES_CAP" ] && break
  done < <(jq -r --arg id "$1" '(.issues // [])[] | select(.id == $id) | (.blocked_by // [])[]' "$SPEC")

  [ -n "$out" ] || return 0
  printf 'Notes left by the tickets this one depends on:\n\n%s' "$out"
}

build_prompt() { # $1 id, $2 body path (may be empty)
  local id=$1 body=$2 rationale= notes= attempts_note= dirty_note= context_note=
  local has_attempts=0

  [ -n "$body" ] && [ -f "$SPEC_DIR/$body" ] && rationale=$(cat "$SPEC_DIR/$body")
  notes=$(blocker_notes "$id")
  [ "$(attempt_count "$id")" -gt 0 ] && has_attempts=1

  # A prior attempt's full verification output only exists on disk once
  # run_verification has written one; point at it instead of duplicating it here.
  if [ "$has_attempts" -eq 1 ] && [ -d "$SPEC_DIR/attempts" ]; then
    attempts_note="Full logs for earlier attempts live under $SPEC_DIR/attempts/ — read
them before choosing an approach."
  fi

  # An agent that crashed mid-edit, or a previous failed attempt, can leave the
  # tree dirty. Silence here reads as "this is fine to build on," which is only
  # true half the time.
  if [ "$IS_GIT" -eq 1 ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    if [ "$has_attempts" -eq 1 ]; then
      dirty_note="The working tree already has uncommitted changes, likely a prior failed
attempt at this same ticket. Review them with git status/git diff, keep what
is useful, revert what is not — do not assume they are correct."
    else
      dirty_note="The working tree has uncommitted changes unrelated to this ticket. Leave
them alone; do not commit them as part of this ticket's work."
    fi
  fi

  [ -f "$SPEC_DIR/context.md" ] && context_note="Background for the whole effort (research, provenance, rejected alternatives)
is at $SPEC_DIR/context.md — read it only if this ticket's rationale seems to
conflict with the invariants or you need provenance."

  local -a rules=(
    "Implement ONLY this ticket. The effort's other tickets are deliberately not
   shown to you; do not go looking for them, and do not build ahead."
    "Run the verification commands above, plus this repo's type checks, before
   you finish. Report failures rather than working around them."
    "Never weaken, skip, or delete an existing test to get to green. When this
   ticket legitimately changes behavior a test asserts, update the test and say
   why in the commit message; otherwise a failing test is a failure to report,
   not an obstacle to remove."
  )
  [ "$IS_GIT" -eq 1 ] && rules+=("Before implementing, skim \`git log --oneline -15\` to see what recent
   iterations changed.")
  [ -n "$body" ] && rules+=("Append a short note under the \"## Comments\" heading of $SPEC_DIR/$body:
   what you did, and any decision a later ticket needs to know about.")
  rules+=("Append any repo-level discovery a later ticket would need (build quirks,
   required env vars, patterns to follow) as one-line bullets to
   $SPEC_DIR/NOTES.md. Seam-level notes about this ticket go under its
   \"## Comments\" heading instead.")
  rules+=("Commit your work, referencing the ticket id \"$id\" in the message.")
  rules+=("Do NOT edit $SPEC. The loop owns issue status and the ledger, snapshots
   the file before you start, and reverts any change you make to it — an edited
   spec fails the attempt outright.")

  local rules_text= n=1 rule
  for rule in "${rules[@]}"; do
    rules_text="${rules_text}${n}. ${rule}
"
    n=$((n + 1))
  done

  cat <<EOF
$(spec_preamble)
${notes:+
$notes}
────────────────────────────────────────
$(issue_block "$id")${attempts_note:+
$attempts_note}
${rationale:+
$rationale
}${dirty_note:+
$dirty_note
}${context_note:+
$context_note
}────────────────────────────────────────

Rules for this iteration:
$rules_text
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
  # Set once actionable failure feedback is recorded on the issue (verification
  # or criteria review), so the stall guard below can tell that apart from an
  # iteration that produced nothing at all.
  FEEDBACK=0
  BOARD=$(issues)
  TOTAL=$(jq 'length' <<<"$BOARD")

  if [ "$TOTAL" -eq 0 ]; then
    die "$BOARD_LABEL has no issues to work through."
  fi

  OPEN=$(jq '[.[] | select(.state != "done")] | length' <<<"$BOARD")

  if [ "$OPEN" -eq 0 ]; then
    render_board "$BOARD" "$((i - 1))" "${GREEN}${BOLD}all issues done${RESET}"
    printf '%s✔%s  %sDone%s in %s%s%s after %s iteration(s).%s\n\n' \
      "$GREEN" "$RESET" "$BOLD" "$RESET" "$TEAL" "$(hms $(($(date +%s) - START)))" "$RESET" "$((i - 1))" "$(spend_note)"
    exit 0
  fi

  if over_budget; then
    render_board "$BOARD" "$((i - 1))" "${YELLOW}${BOLD}cost ceiling reached${RESET}"
    printf '%s◆%s  Stopped at %s$%s%s of the %s$%s%s ceiling; %s issue(s) still open.\n\n' \
      "$CYAN" "$RESET" "$TEAL" "$SPENT" "$RESET" "$TEAL" "$MAX_COST" "$RESET" "$OPEN"
    exit 0
  fi

  # Picked before the board is drawn so the board's model chip names the model
  # this iteration will actually run on.
  # The script picks, so the model spends no context deciding and the choice
  # is reproducible from the graph.
  # `|| true`: an empty frontier makes read fail, and set -e would kill the
  # run before the diagnostic below explains why
  ISSUE_ID=
  IFS=$'\037' read -r ISSUE_ID ISSUE_BODY ISSUE_MODEL ISSUE_TITLE < <(next_issue) || true

  # Per-issue circuit breaker. The global stall guard can't tell "two issues
  # each stumbled once" from "one issue has failed three times"; this can, and
  # the second case is never fixed by trying again.
  TRIES=0
  if [ -n "$ISSUE_ID" ]; then
    TRIES=$(attempt_count "$ISSUE_ID")
    if [ "$TRIES" -ge "$ISSUE_ATTEMPT_LIMIT" ]; then
      printf '\n%s✖%s  %s%s%s has failed %s time(s) — at the limit of %s.\n\n' \
        "$RED" "$RESET" "$BOLD" "$ISSUE_ID" "$RESET" "$TRIES" "$ISSUE_ATTEMPT_LIMIT" >&2
      jq -r --arg id "$ISSUE_ID" '
        (.issues // [])[] | select(.id == $id) | (.attempts // [])[]
        | "   · \(.reason)\(if (.detail // "") == "" then "" else ": " + .detail end)"
      ' "$SPEC" >&2
      printf '\n   %sThe ticket is probably wrong, not the attempts. In Claude Code, run\n' "$DIM" >&2
      printf '   /to-issues %s --replan %s to rewrite or split it from the attempt\n' "$SPEC_DIR" "$ISSUE_ID" >&2
      printf '   record (it clears attempts on what it rewrites), then rerun the loop.\n' >&2
      printf '   Hand-editing criteria and clearing "attempts" yourself also works.%s\n\n' "$RESET" >&2
      exit 1
    fi
  fi

  use_model "${ISSUE_MODEL:-$MODEL}"

  # Opt-in: a ticket that already failed gets a stronger model next time round.
  # Only from a named tier — there is nothing to escalate an unnamed default from.
  if [ "$ESCALATE" = 1 ] && [ "${TRIES:-0}" -gt 0 ]; then
    case "$MODEL_LABEL" in
      haiku)  use_model sonnet ;;
      sonnet) use_model opus ;;
    esac
  fi

  # Not on the first iteration — the banner is the only thing above it.
  if [ "$i" -gt 1 ]; then new_screen; fi

  render_board "$BOARD" "$i" "${DIM}${OPEN} open${RESET}"

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

  # Transient API failures shouldn't kill an unattended run — retry the same
  # iteration with backoff. The spec holds the state, so a retry is safe.
  RESULT=
  ATTEMPT=1
  HEAD_BEFORE=$(head_sha)
  DIRTY_BEFORE=$(dirty_paths)
  # "Do NOT edit $SPEC" is enforced, not trusted: criteria, verification, and
  # status all live in spec.json, and /specs/* is usually gitignored, so an
  # agent edit (weakened criteria, dropped checks) would otherwise be invisible.
  SPEC_SNAPSHOT=$(mktemp)
  cp "$SPEC" "$SPEC_SNAPSHOT"
  while :; do
    ITER_START=$(date +%s)
    OUT=$(mktemp)

    if [ "$ATTEMPT" -eq 1 ]; then
      printf '%s ╭─ %s%s%s %s(%s)%s%s working…%s\n' "$DIM" "$BLUE" "$ITER_HARNESS" "$RESET" "$MODEL_COLOR" "$MODEL_LABEL" "$RESET" "$DIM" "$RESET"
    else
      printf '%s ╭─ %s%s%s %s(%s)%s%s retry %s/%s…%s\n' "$DIM" "$BLUE" "$ITER_HARNESS" "$RESET" "$MODEL_COLOR" "$MODEL_LABEL" "$RESET" "$YELLOW" "$((ATTEMPT - 1))" "$RETRIES" "$RESET"
    fi

    set +e
    if [ "$ITER_HARNESS" = opencode ]; then
      # --auto is opencode's non-interactive permission approval, the moral
      # equivalent of claude's --permission-mode auto below.
      $OPENCODE_CMD run --format json --auto -m "$MODEL_LABEL" "$PROMPT" 2>&1 | tee "$OUT" | stream_render
    else
      # `auto`, not `acceptEdits`: the loop needs git/test commands, and in
      # non-interactive -p mode an unapprovable prompt is an automatic denial.
      $CLAUDE_CMD "${MODEL_ARGS[@]}" --permission-mode "$PERMISSION_MODE" \
        "${ALLOWED_TOOLS_ARGS[@]}" \
        --output-format stream-json --verbose -p "$PROMPT" 2>&1 | tee "$OUT" | stream_render
    fi
    STATUS=${PIPESTATUS[0]}
    set -e

    RAW=$(cat "$OUT"); rm -f "$OUT"
    if [ "$ITER_HARNESS" = opencode ]; then
      # opencode emits one event per completed part; the promise lives in the
      # text parts. It exits 0 even when the provider errored, so error
      # detection is the presence of an error event, not the exit status.
      RESULT=$(jq -Rrn '[inputs | fromjson? | select(.type == "text") | (.part.text // "")] | join("\n")' \
        <<<"$RAW" 2>/dev/null || true)
      IS_ERROR=$(jq -Rrn '[inputs | fromjson? | select(.type == "error")] | length > 0' \
        <<<"$RAW" 2>/dev/null || echo true)
      add_cost "$(jq -Rrn '[inputs | fromjson? | select(.type == "step_finish") | (.part.cost // 0)] | add // 0' \
                   <<<"$RAW" 2>/dev/null || true)"
    else
      # the final assistant text lives in the terminating result event
      RESULT=$(jq -Rr 'fromjson? | select(.type == "result") | (.result // "")' <<<"$RAW" 2>/dev/null || true)
      IS_ERROR=$(jq -Rr 'fromjson? | select(.type == "result") | (.is_error // false)' <<<"$RAW" 2>/dev/null | tail -1)

      # Retries cost money too, so this accumulates per attempt, not per iteration.
      # `// empty` so a transcript without the field degrades to zero rather than
      # taking the loop down.
      add_cost "$(jq -Rr 'fromjson? | select(.type == "result") | (.total_cost_usd // empty)' \
                   <<<"$RAW" 2>/dev/null | tail -1)"
    fi
    [ -z "$RESULT" ] && RESULT="$RAW"

    printf '%s ╰─ %s%s%s%s\n' "$DIM" "$ORANGE" "$(hms $(($(date +%s) - ITER_START)))" "$RESET" "$(cost_chip)"

    # claude sometimes prints an API error and still exits 0
    if [ "$STATUS" -eq 0 ] && [ "$IS_ERROR" != "true" ] && [[ "$RAW" != *"API Error"* ]]; then
      break
    fi

    REASON="exit status $STATUS"
    [ "$STATUS" -eq 0 ] && REASON="API error mid-response"

    if [ "$ATTEMPT" -gt "$RETRIES" ]; then
      printf '\n%s✖%s  claude failed (%s) on iteration %s after %s retries.\n' "$RED" "$RESET" "$REASON" "$i" "$RETRIES" >&2
      [ -n "$ISSUE_ID" ] && record_attempt "$ISSUE_ID" "run failed" "$REASON"
      report_commits "$HEAD_BEFORE" >&2
      printf '   %sRerun to resume; %s is still claimed and will be re-picked.%s\n\n' \
        "$DIM" "${ISSUE_ID:-the open issue}" "$RESET" >&2
      exit 1
    fi

    BACKOFF=$((RETRY_DELAY * ATTEMPT))
    printf '%s ⚠%s  %s — retrying in %ss (%s/%s)\n' "$YELLOW" "$RESET" "$REASON" "$BACKOFF" "$ATTEMPT" "$RETRIES"
    sleep "$BACKOFF"
    ATTEMPT=$((ATTEMPT + 1))
  done

  # A rewritten spec.json invalidates every gate below it — the criteria the
  # judge reads and the commands run_verification runs both live there.
  # Revert it and fail the attempt; the promise is not worth parsing.
  if ! cmp -s "$SPEC_SNAPSHOT" "$SPEC"; then
    cp "$SPEC_SNAPSHOT" "$SPEC"
    printf '%s ✖%s %s%s%s  %sedited spec.json — reverted, promise discarded%s\n' \
      "$RED" "$RESET" "$BOLD" "$ISSUE_ID" "$RESET" "$DIM" "$RESET"
    record_attempt "$ISSUE_ID" "edited the spec" \
      "the iteration modified spec.json, which the loop owns; it was reverted and the promise discarded"
    FEEDBACK=1
  # An explicit BLOCKED is the agent telling us the graph is wrong or the
  # ticket is unbuildable. Retrying that burns the cap for nothing.
  elif [[ "$RESULT" =~ \<promise\>BLOCKED:[[:space:]]*([A-Za-z0-9_-]+)[^\<]*\</promise\> ]]; then
    printf '\n%s✖%s  %s reported blocked on %s%s%s:\n\n' \
      "$RED" "$RESET" "claude" "$BOLD" "$ISSUE_ID" "$RESET" >&2
    print_message "$RESULT" >&2
    printf '\n' >&2
    record_attempt "$ISSUE_ID" "reported blocked" "$RESULT"
    report_commits "$HEAD_BEFORE" >&2
    printf '   %s%s stays claimed; nothing was added to the ledger.%s\n\n' "$DIM" "$ISSUE_ID" "$RESET" >&2
    exit 1
  elif [[ "$RESULT" =~ \<promise\>DONE:[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*[^A-Za-z0-9\<]*([^\<]*)\</promise\> ]]; then
    DONE_ID="${BASH_REMATCH[1]}"
    OUTCOME=$(printf '%s' "${BASH_REMATCH[2]}" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -n "$OUTCOME" ] || OUTCOME="completed"

    # Baseline for "did this ticket produce a commit" and for the judge's diff.
    # This iteration's HEAD when it committed something; otherwise the claim,
    # so an earlier attempt's commit is judged rather than treated as absent.
    JUDGE_BASE="$HEAD_BEFORE"
    if [ "$IS_GIT" -eq 1 ] && [ "$(head_sha)" = "$HEAD_BEFORE" ]; then
      CLAIM_SHA=$(claim_sha "$ISSUE_ID")
      if [ -n "$CLAIM_SHA" ] && git cat-file -e "$CLAIM_SHA^{commit}" 2>/dev/null; then
        JUDGE_BASE="$CLAIM_SHA"
      fi
    fi

    if [ "$DONE_ID" != "$ISSUE_ID" ]; then
      printf '%s ⚠%s  promise names %q but the assigned ticket was %q — not recording it.\n' \
        "$YELLOW" "$RESET" "$DONE_ID" "$ISSUE_ID"
    # Fresh uncommitted changes mean the tree the checks would test is not
    # the commit the ledger would record — fail before spending time on
    # verification that could only certify the wrong state.
    elif NEW_DIRT=$(new_dirt) && [ -n "$NEW_DIRT" ]; then
      printf '%s ✖%s %s%s%s  %spromised done, but left new uncommitted changes — not recording it%s\n' \
        "$RED" "$RESET" "$BOLD" "$ISSUE_ID" "$RESET" "$DIM" "$RESET"
      printf '%s\n' "$NEW_DIRT" | head -10 | while IFS= read -r l; do
        printf '   %s%s%s\n' "$DIM" "$l" "$RESET"
      done
      record_attempt "$ISSUE_ID" "left uncommitted changes" \
        "the working tree gained uncommitted changes the commit lacks ($(printf '%s' "$NEW_DIRT" | tr '\n' ' ')); commit everything the ticket produced"
      FEEDBACK=1
    # The promise is a claim; the spec's verification commands are the check.
    # Failing here leaves the issue claimed, so the next pass re-picks it with
    # the failure replayed into its prompt.
    elif ! run_verification "$ISSUE_ID"; then
      printf '%s ✖%s %s%s%s  %spromised done, but verification failed — not recording it%s\n' \
        "$RED" "$RESET" "$BOLD" "$ISSUE_ID" "$RESET" "$DIM" "$RESET"
      record_attempt "$ISSUE_ID" "verification failed" "$VERIFY_FAILURE"
      FEEDBACK=1
    # No commit means no diff for the judge and nothing traceable in the
    # ledger — and verification may only be passing off uncommitted work.
    # That's a failed attempt, not a warning. Measured from the claim, not from
    # this iteration: work committed by an earlier attempt that died before the
    # ledger was written is still this issue's commit, and the agent is right
    # to add nothing on top of it.
    elif [ "$IS_GIT" -eq 1 ] && [ -n "$JUDGE_BASE" ] && [ "$(head_sha)" = "$JUDGE_BASE" ]; then
      printf '%s ✖%s %s%s%s  %spromised done, but committed nothing — not recording it%s\n' \
        "$RED" "$RESET" "$BOLD" "$ISSUE_ID" "$RESET" "$DIM" "$RESET"
      record_attempt "$ISSUE_ID" "committed nothing" \
        "the DONE promise requires a commit; any work is only in the working tree"
      FEEDBACK=1
    # Verification proves the checks pass; it says nothing about whether the
    # diff did what the ticket asked. A fresh context with no stake in its own
    # work is the closest a single model gets to reviewing that honestly.
    elif ! judge_criteria "$ISSUE_ID" "$JUDGE_BASE"; then
      printf '%s ✖%s %s%s%s  %sdiff failed criteria review — not recording it%s\n' \
        "$RED" "$RESET" "$BOLD" "$ISSUE_ID" "$RESET" "$DIM" "$RESET"
      record_attempt "$ISSUE_ID" "criteria review failed" "$JUDGE_REASON"
      FEEDBACK=1
    else
      HEAD_AFTER=$(head_sha)
      finish_issue "$ISSUE_ID" "$OUTCOME" "$HEAD_AFTER"
      printf '%s ✔%s %s%s%s  %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$ISSUE_ID" "$RESET" "$DIM" "$OUTCOME" "$RESET"
    fi
  else
    record_attempt "$ISSUE_ID" "no completion promise" "$(printf '%s' "$RESULT" | tail -c 300)"
  fi

  rm -f "$SPEC_SNAPSHOT"

  # An iteration that finishes nothing usually means claude is stuck (blocked
  # on permissions, missing context, …), and repeating it just burns the cap.
  # But a recorded verification/review failure is not that — it's the per-issue
  # circuit breaker's job to decide when that issue has failed too many times,
  # with a diagnostic ("the ticket is probably wrong") this guard can't give.
  OPEN_AFTER=$(jq '[.[] | select(.state != "done")] | length' <<<"$(issues)")
  if [ "$OPEN_AFTER" -ge "$OPEN" ]; then
    if [ "$FEEDBACK" -eq 1 ]; then
      printf '%s ⋯%s the failure was recorded on the issue; the per-issue attempt limit governs retries%s\n' "$DIM" "$RESET" "$RESET"
    else
      NO_PROGRESS=$((NO_PROGRESS + 1))
      printf '%s ⚠%s  nothing was completed this iteration (%s/%s)\n' "$YELLOW" "$RESET" "$NO_PROGRESS" "$STALL_LIMIT"
      if [ "$NO_PROGRESS" -ge "$STALL_LIMIT" ]; then
        printf '\n%s✖%s  Stalled: %s iteration(s) completed nothing. claude'"'"'s last message:\n\n' \
          "$RED" "$RESET" "$NO_PROGRESS" >&2
        print_message "$RESULT" >&2
        printf '\n' >&2
        exit 1
      fi
    fi
  else
    NO_PROGRESS=0
  fi
done

FINAL=$(issues)
FINAL_OPEN=$(jq '[.[] | select(.state != "done")] | length' <<<"$FINAL")

if [ "$FINAL_OPEN" -eq 0 ]; then
  render_board "$FINAL" "$MAX_ITERATIONS" "${GREEN}${BOLD}all issues done${RESET}"
  printf '%s✔%s  %sDone%s in %s%s%s after %s iteration(s).%s\n\n' \
    "$GREEN" "$RESET" "$BOLD" "$RESET" "$TEAL" "$(hms $(($(date +%s) - START)))" "$RESET" "$MAX_ITERATIONS" "$(spend_note)"
  exit 0
fi

# Hitting a cap the user asked for is a normal stop, not a failure; hitting the
# default runaway guard is worth an error.
if [ -n "$ITERATIONS" ]; then
  render_board "$FINAL" "$MAX_ITERATIONS" "${YELLOW}${BOLD}${MAX_ITERATIONS} iteration(s) done${RESET}"
  printf '%s◆%s  Ran the requested %s iteration(s) in %s%s%s; %s issue(s) still open.%s\n\n' \
    "$CYAN" "$RESET" "$MAX_ITERATIONS" "$TEAL" "$(hms $(($(date +%s) - START)))" "$RESET" "$FINAL_OPEN" "$(spend_note)"
  exit 0
fi

render_board "$FINAL" "$MAX_ITERATIONS" "${RED}${BOLD}iteration cap reached${RESET}"
printf '%s✖%s  Stopped after %s iterations; %s issue(s) still open.%s\n\n' \
  "$RED" "$RESET" "$MAX_ITERATIONS" "$FINAL_OPEN" "$(spend_note)" >&2
exit 1
