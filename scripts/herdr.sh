# What a host's herdr has open, for fwd's VS Code menu. Read-only.
#
# fwd sends this whole file to the remote and parses what it prints in
# Herdr.read (Sources/FwdCore/Herdr.swift). Herdr.script must stay identical
# to this file; a test checks. Each part of the output follows a `#fwd:`
# marker line. herdr's exit status is printed instead of returned, so its
# errors come back as output rather than as an ssh failure. Every command that
# could read stdin gets /dev/null, because sh is reading this script from it.

echo "#fwd:home $HOME"

# A non-interactive ssh command often lacks the login PATH, so look in the
# usual install folders too.
h=$(command -v herdr 2>/dev/null)
for p in "$HOME/.local/bin/herdr" "$HOME/.cargo/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do
    [ -n "$h" ] && break
    [ -x "$p" ] && h="$p"
done
if [ -z "$h" ]; then
    echo "#fwd:noherdr"
    exit 0
fi
echo "#fwd:herdr $h"
echo "#fwd:version $("$h" --version </dev/null 2>/dev/null | head -n 1)"

# Pulls one string field's values out of JSON on stdin, without jq.
field() {
    grep -o "\"$1\": *\"[^\"]*\"" | sed "s/.*: *\"//; s/\"\$//"
}

# herdr runs one server per named session, and a snapshot covers only one.
sessions=$("$h" session list --json </dev/null 2>/dev/null | field name)
[ -z "$sessions" ] && sessions=default

# Each session's snapshot, then the processes in each of its panes: an agent
# that moves into a worktree doesn't move its pane, so fwd finds the Claude
# Code in each pane to learn where it went.
folders=""
for session in $sessions; do
    echo "#fwd:session $session"
    snapshot=$("$h" --session "$session" api snapshot </dev/null)
    code=$?
    printf "%s\n" "$snapshot"
    echo "#fwd:exit $code"
    folders=$(printf "%s\n%s" "$folders" "$(printf "%s" "$snapshot" | field foreground_cwd)")
    for pane in $(printf "%s" "$snapshot" | field pane_id | sort -u); do
        echo "#fwd:process $session $pane"
        "$h" --session "$session" pane process-info --pane "$pane" </dev/null 2>&1
        echo
        echo "#fwd:end"
    done
done

# Claude Code writes ~/.claude/sessions/<pid>.json for each running process.
# Its transcript records the folder it's working in as it goes; the last one
# is where it is now.
for file in "$HOME"/.claude/sessions/*.json; do
    [ -f "$file" ] || continue
    echo "#fwd:claude"
    cat "$file"
    echo
    id=$(field sessionId < "$file")
    transcript=$(ls "$HOME"/.claude/projects/*/"$id".jsonl 2>/dev/null | head -n 1)
    if [ -n "$id" ] && [ -n "$transcript" ]; then
        last=$(tail -n 200 "$transcript" | field cwd | tail -n 1)
        [ -n "$last" ] && echo "#fwd:lastcwd $last"
    fi
    echo "#fwd:end"
done

# The git worktrees of each folder a pane is in.
printf "%s\n" "$folders" | sort -u | while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    echo "#fwd:worktrees $folder"
    "$h" worktree list --cwd "$folder" </dev/null 2>&1
    echo
    echo "#fwd:end"
done
