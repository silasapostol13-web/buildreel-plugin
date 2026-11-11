#!/bin/bash
# Buildreel for Claude Code: shows Buildreel in the chat at real moments while someone builds, and
# closes each work session with its receipt.
#
#   buildreel-hook.sh start   SessionStart: remember how the project looks now.
#   buildreel-hook.sh stop    Stop: look at what this turn did and, only at a real moment, ask Claude
#                             to send something to Buildreel:
#     - a screen changed and Claude just took a screenshot of it: send it as an update now;
#     - what changed moves (animation or transition code edited, or Claude recorded the screen) and Claude
#       saw it running: send a short clip of the real app doing it instead of the screenshot;
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
writes='(^|[^a-z])git( +-[cC] +[^ ]+)* +(commit|apply|am|cherry-pick|revert|merge|mv|rm|restore|checkout|reset|stash)|sed +-[a-z]*i|perl +-[a-z]*i|(^|[^a-z-])(tee|mv|cp|rm|touch|mkdir|ln|patch|trash|rsync|ditto|unzip|xcodegen)( |\\n|$)|--fix|--write|\.write(_text)?\(|writeFileSync|>'
# Shell commands that write something. Before looking for ">", drop the ones that write nothing: 2>/dev/null, >&2, ->, =>, >=.
shellw() { logs | grep -oE "$bash" | sed -E 's#[0-9&]*>>? *"?/dev/null"?##g; s#[0-9]*>&[0-9-]##g; s#[-=]>|>=##g' | grep -E "$writes"; }
mine=$({ edits; shellw; } | ids)
# Real work, what a receipt is about: edits to anything but notes and docs (.md, .txt, …), and shell commands that
# write a code file in the project (its redirect, tee, sed -i or perl -i target, a script that writes files and names
# one; git apply, patch, xcodegen). A session
# that only wrote a plan, a handoff or research, or worked in a scratch folder, isn't asked for a receipt (most such
# asks ended in "skipping").
notes='\.(md|mdx|markdown|txt|rst|adoc)$'
code='\.(swift|m|mm|h|c|cc|cpp|kt|java|dart|ts|tsx|js|jsx|mjs|cjs|vue|svelte|css|scss|sass|less|html|astro|py|rb|go|rs|php|sql|json|ya?ml|toml|plist|pbxproj|xcassets|storyboard|xib|gradle|sh)'
shellwork() { shellw | perl -ne '
  BEGIN { $root = shift @ARGV; $code = shift @ARGV; }
  ($id) = /"id":"([^"]+)"/; ($c) = /"command":"((?:[^"\\]|\\.)*)"/; next unless defined $c;
  $c =~ s/\\n/\n/g; $c =~ s/\\"/"/g;
  $away = 0; # a cd somewhere else: its relative paths are not the project
  while ($c =~ /(?:^|[;&|(\n])\s*cd\s+"?([^\s;&|"]+)/g) { $d = $1; if (index("$d/", "$root/") == 0) { $away = 0 } elsif ($d =~ m{^[/~\$]}) { $away = 1 } }
  @t = (); push @t, $1 while $c =~ /(?:[0-9&]?>>?|\btee(?:\s+-a)?)\s*["\x27]?([^\s;&|"\x27<>()]+)/g;
  # sed -i / perl -i: the files named in that command; a script that writes files (python, node): the files it names
  for $part (split /&&|\|\||[;|\n]/, $c) { if ($part =~ /\b(?:sed|perl)\s+(?:-[a-zA-Z]*\s+)*-[a-z]*i/) { push @t, $1 while $part =~ /([^\s"\x27<>(),]+)/g; } }
  if ($c =~ /\.write(?:_text|_bytes)?\(|writeFileSync|writeFile\(|open\([^)]*,\s*["\x27][wa]/) { push @t, $1 while $c =~ /([^\s"\x27<>(),=\[\]]+)/g; }
  $hit = !$away && $c =~ /\bgit(?:\s+-C\s+\S+)?\s+apply\b|(?:^|[;&|\n]\s*)patch\s|\bxcodegen\b/ ? 1 : 0;
  for (@t) { next unless /$code$/; if (m{^/}) { $hit = 1 if index($_, "$root/") == 0; } elsif (!$away && !/^[\$~]/) { $hit = 1; } }
  print "\"id\":\"$id\"\n" if $hit;
' "$root" "$code"; }
work=$({ edits | grep -vE "$notes"; shellwork; } | ids)
# Edits to files that draw a screen (SwiftUI, web, Android, Flutter, asset catalogs), with the edit tools or in the shell
# (sed -i, a script that rewrites the file). Tests aren't screens, even in Swift.
screens='\.(swift|tsx|jsx|vue|svelte|css|scss|sass|less|html|xib|storyboard|dart|kt|astro)'
tests() { printf '%s' "/(Tests?|[A-Z][A-Za-z]*Tests|tests?|__tests__|specs?)/|Tests?\\.[A-Za-z]+$1|/test_[^/\"]*\\.[A-Za-z]+$1|[._](test|spec)\\.[A-Za-z]+$1"; }
ui=$({ edits | grep -E "$screens\$|\\.xcassets/" | grep -vE "$(tests '$')"; shellw | grep -E "$screens([^A-Za-z]|\$)"; } | ids)
# Screenshots of the product: the simulator, a browser, an Xcode tool. Not other apps on the Mac.
shots=$({
  logs | grep -oE "$use\"[^\"]*[Ss]creenshot[^\"]*\"" | grep -v 'computer-use'
  logs | grep -oE "$use\"[^\"]*([Bb]rowser|chrome|[Ss]imulator|playwright)[^\"]*\",\"input\":\\{\"action\":\"screenshot\""
  logs | grep -oE "$bash" | grep -E 'simctl +io [^ ]+ +screenshot|screencapture '
} | ids)
commits=$(logs | grep -oE "$bash" | grep -E '(^|[^a-z])git( +-[cC] +[^ ]+)* +commit' | ids)
# Screen recordings of the product: the simulator, a browser's recorder, an Xcode tool. Not other apps on the Mac.
recs=$({
  logs | grep -oE "$use\"[^\"]*(record_sim_video|[Rr]ecord_?[Vv]ideo|gif_creator|[Ss]creen_?[Rr]ecord)[^\"]*\"" | grep -v 'computer-use'
  logs | grep -oE "$bash" | grep -E 'simctl +io +[^ ]+ +recordVideo|screencapture [^|;&]* -[a-zA-Z]*v|recordVideo|--save-video'
} | ids)
# Each tool call on its own line, to read inside one call's input.
calls() { logs | awk '{ gsub(/\{"type":"tool_use"/, "\n&"); print }'; }
# Edits to screen files that add or change motion (animations, transitions); with the edit tools, what's removed isn't counted.
moves='withAnimation|\.animation\(|\.transition\(|matchedGeometryEffect|matchedTransitionSource|navigationTransition|[Pp]haseAnimator|[Kk]eyframeAnimator|contentTransition|symbolEffect|\.spring\(|interpolatingSpring|UIView\.animate|UIViewPropertyAnimator|CABasicAnimation|@keyframes|animation:|framer-motion|AnimatePresence|<motion\.|useSpring|gsap|startViewTransition|view-transition|\.animate\(|AnimationController|Animated[A-Z][a-z]|TweenAnimationBuilder|Hero\(|animate[A-Z][A-Za-z]*AsState|AnimatedVisibility|AnimatedContent|Crossfade\('
motion=$({
  calls | grep -E "^\{$use\"(Edit|Write|MultiEdit)\"" | grep -F "\":\"$root/" | grep -E "\"file_path\":\"[^\"]*$screens\"" \
    | grep -vE "\"file_path\":\"[^\"]*($(tests '"'))" | sed -E 's/"old_string":"([^"\\]|\\.)*"//g; s/"caller":.*//' | grep -E "$moves"
  shellw | grep -E "$screens([^A-Za-z]|\$)" | grep -E "$moves"
} | ids)
# Updates sent with a clip (recording_id).
clips=$(calls | grep -E "^\{$use\"[^\"]*__post_update\"" | sed 's/"caller":.*//' | grep -E '"recording_id": *"[^"]' \
  | sed 's/^{"type":"tool_use","id":"\([^"]*\)".*/\1/' | sort -u | wc -l | tr -d ' ')
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
# Work still running in the background when the turn ended (a build, the tests, an upload, a reviewer agent): the
# session isn't done, and an ask then mostly ends in "not yet". Background commands and agents Claude Code started in
# the last 30 minutes and not yet reported finished or stopped. Things meant to keep running (a dev server, a screen
# recording, a log) don't count, nor does one started longer ago (stuck or forgotten).
longrun='recordVideo|log stream|tail -f|--watch|(^|[^a-z])watch |(npm|pnpm|yarn|bun) (run )?(dev|start|serve|preview)|vite([^a-z]|$)|next (dev|start)|http\.server|(^|[^a-z])serve([^a-z]|$)|(^|[ /])server([ .]|$)|dev-?server|[-_/]dev([^a-z/]|$)|PORT=|--port|ngrok|supabase start|swift run|rails s|flask run|uvicorn|gunicorn|php -S|live-server|browser-sync|expo start|metro|jekyll serve|hugo server|docker[ -]compose up'
pending=$(logs | perl -ne '
  BEGIN { use Time::Local; $now = shift @ARGV; $long = shift @ARGV; }
  $t = /"timestamp":"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/ ? timegm($6, $5, $4, $3, $2 - 1, $1) : $now;
  if (/"type":"tool_use","id":"([^"]+)","name":"Bash","input":(\{.*)/) {
    ($id, $in) = ($1, $2); $in =~ s/"caller":.*//; ($cmd) = $in =~ /^\{"command":"((?:[^"\\]|\\.)*)"/; $cmd =~ s{/dev/(null|std(out|err|in)|tty)}{}g;
    $start{$id} = $t if $in =~ /"run_in_background":true/ && $cmd !~ /$long/;
  }
  if (/"tool_use_id":"([^"]+)","type":"tool_result","content":\[\{"type":"text","text":"Async agent launched[^"]*agentId: (\w+)/) { $start{$1} = $t; $task{$2} = $1; }
  $task{$2} = $1 if /"tool_use_id":"([^"]+)","type":"tool_result","content":"Command running in background with ID: (\w+)/;
  $done{$1} = 1 while /<tool-use-id>([^<]+)<\/tool-use-id>/g;
  push @stop, $1 while /"name":"(?:TaskStop|KillShell|KillBash)","input":\{"(?:task_id|shell_id)":"(\w+)"/g;
  END { $done{$task{$_}} = 1 for grep { $task{$_} } @stop; print scalar(grep { !$done{$_} && $now - $start{$_} < 1800 } keys %start); }
' "$clock" "$longrun" 2>/dev/null)
: "${pending:=0}"

# The state: fingerprint, the counts above when last seen, when the last update and receipt went out,
# how many screen edits there were when the last update went, this session's changes at the last receipt, when a
# commit last asked for the receipt, the recordings when last seen, the motion edits when the last update went, the
# real work at the last receipt and at the last commit ask, and whether an ask is being held while work runs.
# A chat that's resumed (or compacted) keeps what it did so far; only the project's look is taken again.
if [ "$mode" = start ] && [ -s "$file" ]; then
  sed -i.bak "s/^[^ ]*/$now/" "$file" 2>/dev/null; rm -f "$file.bak"
  exit 0
fi
if [ ! -f "$file" ] || [ "$mode" = start ]; then
  printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' "$now" "$sent" "$mine" "$receipts" "$shots" "$commits" 0 0 "$ui" "$mine" 0 "$recs" "$motion" "$work" "$work" 0 > "$file"
  exit 0
fi
read -r was sent_before mine_before receipts_before shots_before commits_before sent_at receipt_at ui_at mine_r asked_at recs_before motion_at work_r work_a held < "$file"
: "${sent_before:=0}" "${mine_before:=0}" "${receipts_before:=0}" "${shots_before:=0}" "${commits_before:=$commits}" "${sent_at:=0}" "${receipt_at:=0}" "${ui_at:=0}" "${mine_r:=0}" "${asked_at:=0}" "${recs_before:=$recs}" "${motion_at:=$motion}" "${work_r:=0}" "${work_a:=0}" "${held:=0}"
s=0; [ "$sent" -gt "$sent_before" ] 2>/dev/null && { s=1; sent_at=$clock; ui_at=$ui; motion_at=$motion; }
[ "$receipts" -gt "$receipts_before" ] 2>/dev/null && { receipt_at=$clock; mine_r=$mine; work_r=$work; }
# Work still running: say nothing yet and keep what this turn did new for the stop after the work finishes (Claude Code
# starts a turn when it does). Not when the person is wrapping up. While an ask is held, a stop where Claude continued
# for another hook, or a turn that sent an update on its own, notes only what was sent (and the screens it covered),
# so the held commit isn't taken as seen.
if { [ "$active" = 0 ] && [ "$wrap" = 0 ] && [ "$pending" -gt 0 ] 2>/dev/null; } || { [ "$active" = 1 ] && [ "$held" = 1 ]; }; then
  [ -n "$BUILDREEL_DEBUG" ] && echo "buildreel: waiting, $pending running" >&2
  [ "$s" = 1 ] && { shots_before=$shots; recs_before=$recs; }
  printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' "$was" "$sent" "$mine_before" "$receipts" "$shots_before" "$commits_before" "$sent_at" "$receipt_at" "$ui_at" "$mine_r" "$asked_at" "$recs_before" "$motion_at" "$work_r" "$work_a" 1 > "$file"
  exit 0
fi
printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' "$now" "$sent" "$mine" "$receipts" "$shots" "$commits" "$sent_at" "$receipt_at" "$ui_at" "$mine_r" "$asked_at" "$recs" "$motion" "$work_r" "$work_a" 0 > "$file"
[ "$active" = 1 ] && exit 0
# A new recording after editing a screen since the last update: Claude watched it move, even on a turn that changed nothing.
rec=0; [ "$recs" -gt "$recs_before" ] 2>/dev/null && [ "$ui" -gt "$ui_at" ] 2>/dev/null && rec=1
changed=1
[ "$held" = 1 ] && was=held # a held ask: a resumed chat's new look of the project doesn't make its work old
{ [ "$now" = "$was" ] || ! [ "$mine" -gt "$mine_before" ] 2>/dev/null; } && changed=0 # nothing new, or the changes were another session's
# Wrapping up after real work that has no receipt yet asks for it even on a turn that changed nothing itself.
[ "$wrap" = 1 ] && [ "$s" = 0 ] && [ "$work" -gt "$work_r" ] 2>/dev/null || wrap=0
[ "$changed" = 1 ] || [ "$wrap" = 1 ] || [ "$rec" = 1 ] || exit 0

# This turn: a new screenshot after editing a screen since the last update, a commit, how long since
# the last update and receipt (minutes, -1 for none yet this chat).
shot=0; [ "$shots" -gt "$shots_before" ] 2>/dev/null && [ "$ui" -gt "$ui_at" ] 2>/dev/null && shot=1
# A commit asks for the receipt only after real work since the last receipt, and since the last ask: one that came
# back "not finished yet" isn't asked again until more work is done.
commit=0; [ "$commits" -gt "$commits_before" ] 2>/dev/null && [ "$work" -gt "$work_r" ] 2>/dev/null && [ "$work" -gt "$work_a" ] 2>/dev/null && commit=1
moved=0; [ "$motion" -gt "$motion_at" ] 2>/dev/null && moved=1
since=-1; [ "$sent_at" -gt 0 ] 2>/dev/null && since=$(( (clock - sent_at) / 60 ))
rsince=-1; [ "$receipt_at" -gt 0 ] 2>/dev/null && rsince=$(( (clock - receipt_at) / 60 ))
# When a commit last asked for the receipt: it waits an hour after an ask too, sent or not, so a person who
# commits every turn isn't asked every turn.
asince=-1; [ "$asked_at" -gt 0 ] 2>/dev/null && asince=$(( (clock - asked_at) / 60 ))
# Notes that a commit's receipt ask went out, and the real work then (the state line's 11th and 15th numbers). The
# receipt line riding on a screen ask notes only the work: the next commit asks again after more work, even in the hour.
noteask() { case "$1" in
  *'this turn saved work on'*) awk -v c="$clock" -v w="$work" '{ $11 = c; $15 = w; print }' "$file" > "$file.new" 2>/dev/null && mv "$file.new" "$file" ;;
  *'also saved work on'*) awk -v w="$work" '{ $15 = w; print }' "$file" > "$file.new" 2>/dev/null && mv "$file.new" "$file" ;;
esac; }
o=0; [ "$offered" -gt 0 ] 2>/dev/null && o=1
project=$(basename "$root" | sed 's/[\\"]//g')
# This plugin's own version, so the server can tell an out-of-date plugin to update itself (once, on an ask it sends anyway).
pv=$(sed -n 's/.*"version": *"\([0-9.]*\)".*/\1/p' "$(dirname "$0")/../.claude-plugin/plugin.json" 2>/dev/null | head -n 1)

# The wording comes from Buildreel's server each time (hookReply in the connector), so it can change without
# a plugin update; this script's own copy below is only for when the server can't be reached.
reply=$(curl -fsS --max-time 4 --get --data-urlencode "project=$project" -d v=2 -d "sent=$s" -d "offered=$o" \
  -d "shot=$shot" -d "commit=$commit" -d "updates=$sent" -d "receipts=$receipts" -d "since=$since" -d "receipt_since=$rsince" -d "wrap=$wrap" -d "asked_since=$asince" \
  -d "motion=$moved" -d "rec=$rec" -d "clips=$clips" -d hold=1 -d "pv=$pv" \
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
due=0; [ "$commit" = 1 ] && { [ "$rsince" -lt 0 ] || [ "$rsince" -ge 60 ]; } && { [ "$asince" -lt 0 ] || [ "$asince" -ge 60 ]; } && due=1
# A screen ask on a turn that also finished the work covers the receipt too, or the receipt would be lost.
also=""; [ "$due" = 1 ] && also=" This turn also saved work on $project: if it finished what the person asked for in this chat, also close the session with its receipt after that update: post_update for project \\\"$project\\\" with extra { receipt: true }; sentence: what this whole session got done, said to a stranger; benefit; milestone if one was reached; next: what comes next."
if { [ "$rec" = 1 ] || { [ "$moved" = 1 ] && [ "$shot" = 1 ]; }; } && [ "$clips" -lt 2 ] && [ "$moments" -lt 3 ] && { [ "$since" -lt 0 ] || [ "$since" -ge 20 ]; }; then
  block "Buildreel: this turn changed something on $project that moves (an animation or transition) and you've seen it running. Send it to Buildreel as a short clip instead of a still, now and without asking: record the real app doing it once (iOS: xcrun simctl io booted recordVideo --codec h264 --force /tmp/buildreel-clip-raw.mov in the background, then kill -INT it; or use the recording you just took), trim it with ffmpeg to the 2 to 8 seconds around the motion as a portrait, silent MP4, look at its frames, and send it only if the motion is plainly visible and it shows only the real app. Then get_upload_link with kind \\\"recording\\\", upload it, get_upload_link for a screenshot of where it ends, and post_update for project \\\"$project\\\" with recording_id, upload_id, one plain sentence on what's new, benefit and screen. If the clip doesn't work out, send the screenshot as a normal update.$also$post Then end your turn with one short line at most."
fi
if [ "$shot" = 1 ] && [ "$moments" -lt 3 ] && { [ "$since" -lt 0 ] || [ "$since" -ge 20 ]; }; then
  block "Buildreel: this turn changed how $project looks and you took a screenshot of it. Send it to Buildreel now, without asking: get_upload_link, upload that screenshot (or a fresh one of the same screen), then post_update for project \\\"$project\\\" with one plain sentence on what's new on screen, benefit and screen. Skip it only if the screen looks the same as in your last Buildreel update, or is broken or half-done.$also$post Then end your turn with one short line at most."
fi
if [ "$due" = 1 ]; then
  block "Buildreel: this turn saved work on $project. If it finished what the person asked for in this chat, close the session with its receipt now: post_update for project \\\"$project\\\" with extra { receipt: true }; sentence: what this whole session got done, said to a stranger; benefit; milestone if one was reached; next: what comes next; and a screenshot if there is a screen to show. If their request isn't finished yet, end your turn with no reply."
fi
exit 0
