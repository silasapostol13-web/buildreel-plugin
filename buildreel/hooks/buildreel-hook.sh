#!/bin/bash
# Buildreel for Claude Code: when Claude finishes a turn that changed a project set up for
# Buildreel, ask it (once per set of changes) to send an update if a person could see the change,
# and to offer a post if it's a good moment and it hasn't offered one in this chat.
#
#   buildreel-hook.sh start   SessionStart: remember how the project looks now.
#   buildreel-hook.sh stop    Stop: if it changed since, ask Claude to send an update.
#
# Only acts in git repos whose CLAUDE.md or AGENTS.md has a "## Buildreel" section (added by the
# connector's setup_project). Only asks about changes the session made itself, never twice for
# the same changes, so it can't loop.
input=$(cat)
mode=$1

field() { printf '%s' "$input" | tr '\n' ' ' | sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" | head -n 1; }

case "$input" in *'"stop_hook_active":true'* | *'"stop_hook_active": true'*) exit 0 ;; esac

cwd=$(field cwd)
session=$(field session_id | tr -cd 'A-Za-z0-9_-')
transcript=$(field transcript_path)
[ -n "$cwd" ] && [ -n "$session" ] || exit 0
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
grep -qs '^## Buildreel' "$root/CLAUDE.md" "$root/AGENTS.md" || exit 0

# One tiny file per session holding a fingerprint of the project.
state=${BUILDREEL_HOOK_STATE:-"$HOME/.claude/buildreel-hook"}
mkdir -p "$state" 2>/dev/null || exit 0
file="$state/$session"

# How the project looks: last commit, changed and new files, and the changes themselves.
now=$({ git -C "$root" rev-parse HEAD 2>/dev/null; git -C "$root" status --porcelain 2>/dev/null; git -C "$root" diff 2>/dev/null; } | shasum | cut -c1-40)

# How many changes this session made itself so far: its own edits to files in the project and its
# shell commands that write (commits, redirects, sed -i, …), its subagents' included, each tool
# call counted once. Other sessions working in the same folder change the project too, and those
# are theirs to report, so only a turn where this count went up is asked about.
logs() { cat "$transcript" "${transcript%.jsonl}"/subagents/*.jsonl 2>/dev/null; }
use='"type":"tool_use","id":"[^"]*","name":'
# How many updates Claude has sent in this session so far (the project's own rule often gets it there
# first). Real calls only: the chat's list of available tools names post_update too.
sent=$(logs | grep -oE "$use\"[^\"]*__post_update\"" | sort -u | wc -l | tr -d ' ')
writes='(^|[^a-z])git( +-[cC] +[^ ]+)* +(commit|apply|am|cherry-pick|revert|merge|mv|rm|restore|checkout|reset|stash)|sed +-[a-z]*i|perl +-[a-z]*i|(^|[^a-z-])(tee|mv|cp|rm|touch|mkdir|ln|patch|trash|rsync|ditto|unzip|xcodegen)( |\\n|$)|--fix|--write|>'
mine=$({
  logs | grep -oE "$use\"(Edit|Write|MultiEdit|NotebookEdit)\",\"input\":\\{\"(file_path|notebook_path)\":\"[^\"]*" | grep -F "\":\"$root/"
  # Before looking for ">", drop the ones that write nothing: 2>/dev/null, >&2, ->, =>, >=.
  logs | grep -oE "$use\"Bash\",\"input\":\\{\"command\":\"([^\"\\\\]|\\\\.)*\"" \
    | sed -E 's#[0-9&]*>>? *"?/dev/null"?##g; s#[0-9]*>&[0-9-]##g; s#[-=]>|>=##g' | grep -E "$writes"
} | sed 's/.*"id":"\([^"]*\)".*/\1/' | sort -u | wc -l | tr -d ' ')

if [ "$mode" = start ] || [ ! -f "$file" ]; then
  printf '%s %s %s' "$now" "$sent" "$mine" > "$file"
  exit 0
fi
read -r was sent_before mine_before < "$file"
printf '%s %s %s' "$now" "$sent" "$mine" > "$file"
[ "$now" = "$was" ] && exit 0
[ "$mine" -gt "${mine_before:-0}" ] 2>/dev/null || exit 0 # the changes were another session's

# The post offer is asked for here, not only in the project's "## Buildreel" text: projects set up
# before offer_post existed (2026-11-03) never mention it. At most one offer per chat.
offered=$(logs | grep -oE "$use\"[^\"]*__offer_post\"" | sort -u | wc -l | tr -d ' ')
post="If this turn also reached a good moment for a post (a feature done start to finish, a screen that looks very different, ready for testers, launch, first dollar: offer_post lists the kinds), call offer_post on your own with a short line of your own on what's new, then end your turn and wait for their answer; never make a post before their yes."
[ "$offered" -gt 0 ] 2>/dev/null && post=""

project=$(basename "$root" | sed 's/[\\"]//g')
# The wording comes from Buildreel's server each time (hookReply in the connector), so it can change without
# a plugin update; this script's own copy below is only for when the server can't be reached.
s=0; [ "$sent" -gt "${sent_before:-0}" ] 2>/dev/null && s=1
o=0; [ "$offered" -gt 0 ] 2>/dev/null && o=1
reply=$(curl -fsS --max-time 4 --get --data-urlencode "project=$project" -d "sent=$s" -d "offered=$o" \
  "${BUILDREEL_URL:-https://buildreel.pages.dev/mcp}/hook" 2>/dev/null | tr -d '\n')
case "$reply" in
  '{}') exit 0 ;;
  '{"decision":"block","reason":"'*'"}') printf '%s\n' "$reply"; exit 0 ;;
esac

if [ "$sent" -gt "${sent_before:-0}" ] 2>/dev/null; then # it already sent the update this turn
  [ -n "$post" ] || exit 0
  printf '{"decision":"block","reason":"%s"}\n' "Buildreel: this turn changed $project and sent its update. $post If it isn't a good moment, just stop without mentioning this."
  exit 0
fi
reason="Buildreel: this turn changed $project. If it finished something a person could see or use and you have not sent a Buildreel update for it yet, send one now with the Buildreel connector: a screenshot of what changed and one plain sentence, for project \\\"$project\\\". Only if it shipped a core feature or a new main screen of an iOS app working start to finish, something a user would show a friend, call offer_video first; never for tweaks, fixes, small screens or making something easier to find. If the person asked for a video, call offer_video with asked: true: no weekly limit, same check before sending.${post:+ $post} If nothing visible changed, just stop without mentioning this."
printf '{"decision":"block","reason":"%s"}\n' "$reason"
