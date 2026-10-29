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

# $1 made safe inside a JSON string, on one line, without control characters.
esc() {
    printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\037\177' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Scratch files: the loops below run in subshells, so they pass lists on
# through files rather than variables.
err=$(mktemp)
folders=$(mktemp)
ids=$(mktemp)
trap 'rm -f "$err" "$folders" "$ids"' EXIT

# Runs herdr with these arguments and prints its reply, which is one line of
# JSON. Some errors come as JSON on stderr instead. Anything else is reported
# as a failure, as JSON. The reply is also left in $out.
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

# The folder Claude Code session $1 last worked in, from its transcript.
last_cwd() {
    transcript=$(ls "$HOME"/.claude/projects/*/"$1".jsonl 2>/dev/null | head -n 1)
    [ -n "$transcript" ] || return 0
    last=$(tail -n 200 "$transcript" | field cwd | tail -n 1)
    [ -n "$last" ] && printf '{"sessionId":"%s","lastCwd":"%s"}\n' "$(esc "$1")" "$(esc "$last")"
}

printf '{"home":"%s"}\n' "$(esc "$HOME")"

# A non-interactive ssh command often lacks the login PATH, so look in the
# usual install folders too.
h=$(command -v herdr 2>/dev/null)
for p in "$HOME/.local/bin/herdr" "$HOME/.cargo/bin/herdr" "$HOME/.nix-profile/bin/herdr" \
    /opt/homebrew/bin/herdr /usr/local/bin/herdr /home/linuxbrew/.linuxbrew/bin/herdr /snap/bin/herdr; do
    [ -n "$h" ] && break
    [ -x "$p" ] && h="$p"
done
if [ -z "$h" ]; then
    echo '{"noherdr":true}'
    exit 0
fi
printf '{"herdr":"%s","version":"%s"}\n' "$(esc "$h")" "$(esc "$("$h" --version </dev/null 2>/dev/null | head -n 1)")"

# herdr runs one server per named session, and a snapshot covers only one.
# Only running sessions are asked; with no session list (an older herdr), the
# default one is. Each session object in the list is flat, so splitting on }
# gives one per line.
list=$("$h" session list --json </dev/null 2>/dev/null)
sessions=$(printf '%s' "$list" | tr '}' '\n' | grep '"running": *true' | field name)
[ -n "$list" ] || sessions=default

printf '%s\n' "$sessions" | while IFS= read -r session; do
    [ -n "$session" ] || continue
    printf '{"session":"%s"}\n' "$(esc "$session")"
    run --session "$session" api snapshot
    snapshot=$out
    printf '%s' "$snapshot" | field foreground_cwd >> "$folders"
    printf '%s' "$snapshot" | field cwd >> "$folders"
    case "$snapshot" in
        *'"agent_session"'*)
            # herdr names each pane's Claude Code session.
            printf '%s' "$snapshot" | grep -o '"agent_session":{[^}]*}' | field value >> "$ids"
            ;;
        *)
            # An older herdr doesn't, so find the Claude Code in each pane;
            # its session file, below, names the session.
            for pane in $(printf '%s' "$snapshot" | field pane_id | sort -u); do
                run --session "$session" pane process-info --pane "$pane"
            done
            for file in "$HOME"/.claude/sessions/*.json; do
                [ -f "$file" ] || continue
                printf '%s\n' "$(cat "$file")"
                field sessionId < "$file" >> "$ids"
            done
            ;;
    esac
done

# Where each Claude Code session is working now: an agent that moves into a
# worktree doesn't move its pane, but its transcript records the folder.
sort -u "$ids" | while IFS= read -r id; do
    [ -n "$id" ] && last_cwd "$id"
done

# The git worktrees of each folder a pane is in.
sort -u "$folders" | while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    printf '{"worktreesOf":"%s"}\n' "$(esc "$folder")"
    run worktree list --cwd "$folder"
done
