# What a host's herdr has open, for fwd's VS Code menu. Read-only.
#
# Prints JSON Lines: herdr's replies and Claude Code's session files as they
# are (each is one line of JSON), plus a few one-line objects saying what
# comes next. A herdr command that prints something else (a crash, a usage
# message) is reported as {"failed": ..., "exit": ..., "output": ...}.
# Herdr.read in Sources/FwdCore/Herdr.swift decodes them line by line; a
# login banner or rc chatter before them is skipped.
# The app carries this file in Contents/Resources (scripts/bundle.sh copies
# it there).
#
# Every command that could read stdin gets /dev/null, because sh is reading
# this script from it.

# $1 made safe inside a JSON string, on one line.
esc() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   '
}

# Runs herdr with these arguments and prints its reply, which is one line of
# JSON. Some errors come as JSON on stderr instead. Anything else is reported
# as a failure, as JSON. The reply is also left in $out.
err=$(mktemp)
trap 'rm -f "$err"' EXIT
run() {
    out=$("$h" "$@" </dev/null 2>"$err")
    code=$?
    [ -z "$out" ] && out=$(cat "$err")
    case "$out" in
        "{"*) printf '%s\n' "$out" ;;
        *) printf '{"failed":"herdr %s","exit":%s,"output":"%s"}\n' "$(esc "$*")" "$code" "$(esc "$out")" ;;
    esac
}

# One string field's values from the JSON on stdin.
field() {
    grep -o "\"$1\": *\"[^\"]*\"" | sed 's/.*: *"//; s/"$//'
}

printf '{"home":"%s"}\n' "$HOME"

# A non-interactive ssh command often lacks the login PATH, so look in the
# usual install folders too.
h=$(command -v herdr 2>/dev/null)
for p in "$HOME/.local/bin/herdr" "$HOME/.cargo/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do
    [ -n "$h" ] && break
    [ -x "$p" ] && h="$p"
done
if [ -z "$h" ]; then
    echo '{"noherdr":true}'
    exit 0
fi
printf '{"herdr":"%s","version":"%s"}\n' "$h" "$("$h" --version </dev/null 2>/dev/null | head -n 1)"

# herdr runs one server per named session, and a snapshot covers only one.
# Each session's snapshot, then the processes in each of its panes: an agent
# that moves into a worktree doesn't move its pane, so fwd finds the Claude
# Code in each pane to learn where it went.
sessions=$("$h" session list --json </dev/null 2>/dev/null | field name)
[ -z "$sessions" ] && sessions=default
folders=""
for session in $sessions; do
    printf '{"session":"%s"}\n' "$session"
    run --session "$session" api snapshot
    snapshot=$out
    folders=$(printf '%s\n%s' "$folders" "$(printf '%s' "$snapshot" | field foreground_cwd)")
    for pane in $(printf '%s' "$snapshot" | field pane_id | sort -u); do
        run --session "$session" pane process-info --pane "$pane"
    done
done

# Claude Code writes ~/.claude/sessions/<pid>.json for each running process.
# Its transcript records the folder it's working in as it goes; the last one
# is where it is now.
for file in "$HOME"/.claude/sessions/*.json; do
    [ -f "$file" ] || continue
    printf '%s\n' "$(cat "$file")"
    id=$(field sessionId < "$file")
    transcript=$(ls "$HOME"/.claude/projects/*/"$id".jsonl 2>/dev/null | head -n 1)
    [ -n "$id" ] && [ -n "$transcript" ] || continue
    last=$(tail -n 200 "$transcript" | field cwd | tail -n 1)
    [ -n "$last" ] && printf '{"sessionId":"%s","lastCwd":"%s"}\n' "$id" "$last"
done

# The git worktrees of each folder a pane is in.
printf '%s\n' "$folders" | sort -u | while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    printf '{"worktreesOf":"%s"}\n' "$folder"
    run worktree list --cwd "$folder"
done
