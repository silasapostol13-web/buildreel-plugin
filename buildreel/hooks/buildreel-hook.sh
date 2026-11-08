#!/bin/bash
# Buildreel for Claude Code: shows Buildreel in the chat at real moments while someone builds, and
# closes each work session with its receipt.
#
#   buildreel-hook.sh start   SessionStart: remember how the project looks now.
#   buildreel-hook.sh stop    Stop: look at what this turn did and, only at a real moment, ask Claude
#                             to send something to Buildreel:
#     - a screen changed and Claude just took a screenshot of it: send it as an update now;
#     - the turn saved work (a commit): if it finished what the person asked for, send the receipt;
#     - the person wraps up ("that's it for today"): send the session's receipt;
#     - it sent an update: offer a post if it's a good moment (at most once a chat).
#   Every other turn says nothing. How often each may come (caps, gaps) is decided by Buildreel's
#   server (/mcp/hook), so it can change without a plugin update.
#
# Only acts in git repos whose CLAUDE.md or AGENTS.md has a "## Buildreel" section (added by the
# connector's setup_project). Only asks about changes the session made itself, never twice for
# the same changes, so it can't loop.
input=$(cat)
mode=$1

field() { printf '%s' "$input" | tr '\n' ' ' | sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" | head -n 1; }

# Claude continuing because of an ask: note what it sent (so the next turn isn't asked about it again),
# never ask again now, so it can't loop.
active=0
case "$input" in *'"stop_hook_active":true'* | *'"stop_hook_active": true'*) active=1 ;; esac

cwd=$(field cwd)
session=$(field session_id | tr -cd 'A-Za-z0-9_-')
transcript=$(field transcript_path)
[ -n "$cwd" ] && [ -n "$session" ] || exit 0
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
grep -qs '^## Buildreel' "$root/CLAUDE.md" "$root/AGENTS.md" || exit 0

# One tiny file per session holding a fingerprint of the project and what the session did so far.
state=${BUILDREEL_HOOK_STATE:-"$HOME/.claude/buildreel-hook"}
mkdir -p "$state" 2>/dev/null || exit 0
file="$state/$session"

# How the project looks: last commit, changed and new files, and the changes themselves (new files' too).
now=$({ git -C "$root" rev-parse HEAD 2>/dev/null; git -C "$root" status --porcelain 2>/dev/null; git -C "$root" diff 2>/dev/null
  git -C "$root" ls-files -o --exclude-standard 2>/dev/null | head -n 200 | (cd "$root" && git hash-object --stdin-paths 2>/dev/null); } | shasum | cut -c1-40)

# What this session did so far, read from its transcript (its subagents' included), each tool call
# counted once. Other sessions working in the same folder change the project too, and those are
# theirs to report, so only a turn where this session's own count went up is asked about.
logs() { cat "$transcript" "${transcript%.jsonl}"/subagents/*.jsonl 2>/dev/null; }
ids() { sed 's/.*"id":"\([^"]*\)".*/\1/' | sort -u | wc -l | tr -d ' '; }
use='"type":"tool_use","id":"[^"]*","name":'
bash="$use\"Bash\",\"input\":\\{\"command\":\"([^\"\\\\]|\\\\.)*\""
edits() { logs | grep -oE "$use\"(Edit|Write|MultiEdit|NotebookEdit)\",\"input\":\\{\"(file_path|notebook_path)\":\"[^\"]*" | grep -F "\":\"$root/"; }
# Updates sent (real calls only: the chat's list of available tools names post_update too), and the
# ones of them that were a session's receipt (extra { receipt: true }).
sent=$(logs | grep -oE "$use\"[^\"]*__post_update\"" | ids)
receipts=$(logs | awk '{ gsub(/\{"type":"tool_use"/, "\n&"); print }' | grep -E "^\{$use\"[^\"]*__post_update\"" \
  | sed 's/"caller":.*//' | grep -E '"receipt": *true' | sed 's/^{"type":"tool_use","id":"\([^"]*\)".*/\1/' | sort -u | wc -l | tr -d ' ')
writes='(^|[^a-z])git( +-[cC] +[^ ]+)* +(commit|apply|am|cherry-pick|revert|merge|mv|rm|restore|checkout|reset|stash)|sed +-[a-z]*i|perl +-[a-z]*i|(^|[^a-z-])(tee|mv|cp|rm|touch|mkdir|ln|patch|trash|rsync|ditto|unzip|xcodegen)( |\\n|$)|--fix|--write|>'
mine=$({
  edits
  # Before looking for ">", drop the ones that write nothing: 2>/dev/null, >&2, ->, =>, >=.
  logs | grep -oE "$bash" | sed -E 's#[0-9&]*>>? *"?/dev/null"?##g; s#[0-9]*>&[0-9-]##g; s#[-=]>|>=##g' | grep -E "$writes"
} | ids)
# Edits to files that draw a screen (SwiftUI, web, Android, Flutter, asset catalogs).
ui=$(edits | grep -E '\.(swift|tsx|jsx|vue|svelte|css|scss|sass|less|html|xib|storyboard|dart|kt|astro)$|\.xcassets/' | ids)
# Screenshots of the product: the simulator, a browser, an Xcode tool. Not other apps on the Mac.
shots=$({
  logs | grep -oE "$use\"[^\"]*[Ss]creenshot[^\"]*\"" | grep -v 'computer-use'
  logs | grep -oE "$use\"[^\"]*([Bb]rowser|chrome|[Ss]imulator|playwright)[^\"]*\",\"input\":\\{\"action\":\"screenshot\""
  logs | grep -oE "$bash" | grep -E 'simctl +io [^ ]+ +screenshot|screencapture '
} | ids)
commits=$(logs | grep -oE "$bash" | grep -E '(^|[^a-z])git( +-[cC] +[^ ]+)* +commit' | ids)
offered=$(logs | grep -oE "$use\"[^\"]*__offer_post\"" | ids)
# Whether the person's latest message wraps the session up ("that's it for today", "done for now"): read here,
# on this Mac, and only a yes / no goes to Buildreel, never their words.
said=$(grep '"type":"user"' "$transcript" 2>/dev/null | grep -v '"isMeta":true' | grep -v '"tool_result"' | tail -n 1 \
  | perl -ne 'if (/"content":"((?:[^"\\]|\\.)*)"/ || /"type":"text","text":"((?:[^"\\]|\\.)*)"/) { $_ = lc $1; s/\\u2019|\xe2\x80\x99/\x27/g; s/\\n/ /g; print }' 2>/dev/null)
wrap=0
# Only a short message that is itself the goodbye: "make the button blue, that's it" or "add a goodnight screen" isn't one.
if [ "$(printf '%s' "$said" | wc -w | tr -d ' ')" -le 8 ] 2>/dev/null; then
  printf '%s' "$said" | grep -qE "(that'?s|thats) (it|all) for (today|now|tonight|the day)|(i'?m|im|i am|we'?re) (done|finished|out)( for (today|now|tonight|the day))?[ .!]*$|done for (today|now|tonight|the day)|call it a (day|night)|(signing|logging) off|^[^a-z]*(ok(ay)?|thanks?|nice|great|perfect)?[ ,.!]*good ?night|(stop|wrap( it| things)? up) (here|there|for (today|now|tonight))|that'?s a wrap" && wrap=1
fi
clock=${BUILDREEL_NOW:-$(date +%s)} # tests set the time

# The state: fingerprint, the counts above when last seen, when the last update and receipt went out,
# how many screen edits there were when the last update went, and this session's changes at the last receipt.
# A chat that's resumed (or compacted) keeps what it did so far; only the project's look is taken again.
if [ "$mode" = start ] && [ -s "$file" ]; then
  sed -i.bak "s/^[^ ]*/$now/" "$file" 2>/dev/null; rm -f "$file.bak"
  exit 0
fi
if [ ! -f "$file" ] || [ "$mode" = start ]; then
  printf '%s %s %s %s %s %s %s %s %s %s %s\n' "$now" "$sent" "$mine" "$receipts" "$shots" "$commits" 0 0 "$ui" "$mine" 0 > "$file"
  exit 0
fi
read -r was sent_before mine_before receipts_before shots_before commits_before sent_at receipt_at ui_at mine_r asked_at < "$file"
: "${sent_before:=0}" "${mine_before:=0}" "${receipts_before:=0}" "${shots_before:=0}" "${commits_before:=$commits}" "${sent_at:=0}" "${receipt_at:=0}" "${ui_at:=0}" "${mine_r:=0}" "${asked_at:=0}"
s=0; [ "$sent" -gt "$sent_before" ] 2>/dev/null && { s=1; sent_at=$clock; ui_at=$ui; }
[ "$receipts" -gt "$receipts_before" ] 2>/dev/null && { receipt_at=$clock; mine_r=$mine; }
printf '%s %s %s %s %s %s %s %s %s %s %s\n' "$now" "$sent" "$mine" "$receipts" "$shots" "$commits" "$sent_at" "$receipt_at" "$ui_at" "$mine_r" "$asked_at" > "$file"
[ "$active" = 1 ] && exit 0
changed=1
{ [ "$now" = "$was" ] || ! [ "$mine" -gt "$mine_before" ] 2>/dev/null; } && changed=0 # nothing new, or the changes were another session's
# Wrapping up after work that has no receipt yet asks for it even on a turn that changed nothing itself.
[ "$wrap" = 1 ] && [ "$s" = 0 ] && [ "$mine" -gt "$mine_r" ] 2>/dev/null || wrap=0
[ "$changed" = 1 ] || [ "$wrap" = 1 ] || exit 0

# This turn: a new screenshot after editing a screen since the last update, a commit, how long since
# the last update and receipt (minutes, -1 for none yet this chat).
shot=0; [ "$shots" -gt "$shots_before" ] 2>/dev/null && [ "$ui" -gt "$ui_at" ] 2>/dev/null && shot=1
commit=0; [ "$commits" -gt "$commits_before" ] 2>/dev/null && commit=1
since=-1; [ "$sent_at" -gt 0 ] 2>/dev/null && since=$(( (clock - sent_at) / 60 ))
rsince=-1; [ "$receipt_at" -gt 0 ] 2>/dev/null && rsince=$(( (clock - receipt_at) / 60 ))
# When a commit last asked for the receipt: it waits an hour after an ask too, sent or not, so a person who
# commits every turn isn't asked every turn.
asince=-1; [ "$asked_at" -gt 0 ] 2>/dev/null && asince=$(( (clock - asked_at) / 60 ))
# Notes that a commit's receipt ask went out (the state line's last number).
noteask() { case "$1" in *'saved work on'*) sed -i.bak "s/ [0-9]*\$/ $clock/" "$file" 2>/dev/null; rm -f "$file.bak" ;; esac; }
o=0; [ "$offered" -gt 0 ] 2>/dev/null && o=1
project=$(basename "$root" | sed 's/[\\"]//g')

# The wording comes from Buildreel's server each time (hookReply in the connector), so it can change without
# a plugin update; this script's own copy below is only for when the server can't be reached.
reply=$(curl -fsS --max-time 4 --get --data-urlencode "project=$project" -d v=2 -d "sent=$s" -d "offered=$o" \
  -d "shot=$shot" -d "commit=$commit" -d "updates=$sent" -d "receipts=$receipts" -d "since=$since" -d "receipt_since=$rsince" -d "wrap=$wrap" -d "asked_since=$asince" \
  "${BUILDREEL_URL:-https://buildreel.pages.dev/mcp}/hook" 2>/dev/null | tr -d '\n')
case "$reply" in
  '{}') exit 0 ;;
  '{"decision":"block","reason":"'*'"}') noteask "$reply"; printf '%s\n' "$reply"; exit 0 ;;
esac

post=""
[ "$o" = 0 ] && post=" If this is also a good moment for a post (a feature done start to finish, a screen that looks very different, ready for testers, launch, first dollar: offer_post lists the kinds), call offer_post on your own with a short line of your own on what's new, then end your turn and wait for their answer; never make a post before their yes."
block() { noteask "$1"; printf '{"decision":"block","reason":"%s"}\n' "$1"; exit 0; }
[ "$s" = 1 ] && exit 0 # it sent an update this turn: nothing more to ask
if [ "$wrap" = 1 ] && { [ "$rsince" -lt 0 ] || [ "$rsince" -ge 10 ]; }; then
  block "Buildreel: the person is wrapping up. Close the session with its receipt now: post_update for project \\\"$project\\\" with extra { receipt: true }; sentence: what this session got done since its last receipt, said to a stranger; benefit; milestone if one was reached; next: what comes next; and a screenshot if there is a screen to show. Then end your turn with one short line at most; don't repeat your summary."
fi
moments=$((sent - receipts))
if [ "$shot" = 1 ] && [ "$moments" -lt 3 ] && { [ "$since" -lt 0 ] || [ "$since" -ge 20 ]; }; then
  block "Buildreel: this turn changed how $project looks and you took a screenshot of it. Send it to Buildreel now, without asking: get_upload_link, upload that screenshot (or a fresh one of the same screen), then post_update for project \\\"$project\\\" with one plain sentence on what's new on screen, benefit and screen. Skip it only if the screen looks the same as in your last Buildreel update, or is broken or half-done.$post Then end your turn with one short line at most."
fi
if [ "$commit" = 1 ] && { [ "$rsince" -lt 0 ] || [ "$rsince" -ge 60 ]; } && { [ "$asince" -lt 0 ] || [ "$asince" -ge 60 ]; }; then
  block "Buildreel: this turn saved work on $project. If it finished what the person asked for in this chat, close the session with its receipt now: post_update for project \\\"$project\\\" with extra { receipt: true }; sentence: what this whole session got done, said to a stranger; benefit; milestone if one was reached; next: what comes next; and a screenshot if there is a screen to show. If their request isn't finished yet, end your turn with no reply."
fi
exit 0
