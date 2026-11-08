#!/bin/bash
# Tests for buildreel-hook.sh. Run: claude-plugin/buildreel/hooks/test.sh
hook="$(cd "$(dirname "$0")" && pwd)/buildreel-hook.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/buildreel-hook-test.XXXXXX")
export BUILDREEL_HOOK_STATE="$work/state"
# No server by default: the hook falls back to its own wording. The server tests below set it.
export BUILDREEL_URL="http://127.0.0.1:9"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fails=$((fails + 1)); fi; }
# Each session has its own transcript, like Claude Code: $work/<session>.jsonl.
run() { printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"x","stop_hook_active":%s}' "$2" "$work/$2.jsonl" "$3" "${4:-false}" | "$hook" "$1"; }
repo() { mkdir -p "$work/$1" && git -C "$work/$1" init -q && echo hi > "$work/$1/a.txt" && git -C "$work/$1" add . && git -C "$work/$1" -c user.email=t@t -c user.name=t commit -qm one; }
valid() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["decision"])' 2>/dev/null; }
# What a session's transcript records when Claude calls a tool. tool <session> <name> <input json>
n=0
tool() { n=$((n + 1)); printf '{"type":"assistant","timestamp":"x","message":{"content":[{"type":"tool_use","id":"toolu_%s","name":"%s","input":%s,"caller":{"type":"direct"}}]}}\n' "$n" "$2" "$3" >> "$work/$1.jsonl"; }
top() { git -C "$work/$1" rev-parse --show-toplevel; }
# Claude in session $1 edits a plain file in repo $2 (nothing a screen draws).
edit() { echo "$1" >> "$work/$2/a.txt"; tool "$1" Edit "{\"file_path\":\"$(top "$2")/a.txt\",\"old_string\":\"x\"}"; }
# ... edits a screen (a SwiftUI view) in repo $2.
screen() { echo "$1" >> "$work/$2/Home.swift"; tool "$1" Edit "{\"file_path\":\"$(top "$2")/Home.swift\",\"old_string\":\"x\"}"; }
# ... takes a screenshot of the simulator, the way it really shows up (XcodeBuildMCP, or simctl in the shell).
shot() { tool "$1" mcp__XcodeBuildMCP__screenshot '{"returnFormat":"path"}'; }
simshot() { tool "$1" Bash '{"command":"xcrun simctl io booted screenshot /tmp/x.png","description":"Screenshot"}'; }
# ... commits through the shell.
commit() { echo "$1 c" >> "$work/$2/a.txt"; git -C "$work/$2" add -A && git -C "$work/$2" -c user.email=t@t -c user.name=t commit -qm "$1"; tool "$1" Bash '{"command":"git add -A && git commit -m \"Water now button\"","description":"Commit"}'; }
# ... sends an update (a receipt with receipt).
update() { tool "$1" mcp__claude_ai_Buildreel__post_update "{\"project\":\"x\",\"sentence\":\"s\"${2:+,\"extra\":{\"receipt\":true}}}"; }
# Another session, working in the same folder, commits.
other() { echo "$2" >> "$work/$1/b.txt"; git -C "$work/$1" add b.txt && git -C "$work/$1" -c user.email=t@t -c user.name=t commit -qm "$2"; }
says() { printf '%s' "$1" | grep -c "$2"; }
T=1800000000; at() { export BUILDREEL_NOW=$((T + $1 * 60)); }; at 0

repo plain
run start s1 "$work/plain"; screen s1 plain; shot s1
check "does nothing in a project not set up for Buildreel" "$(run stop s1 "$work/plain")" ""

repo app; printf '# App\n\n## Buildreel\nSend updates.\n' > "$work/app/CLAUDE.md"; git -C "$work/app" add . && git -C "$work/app" -c user.email=t@t -c user.name=t commit -qm rule
run start s2 "$work/app"
check "a turn that changed nothing passes" "$(run stop s2 "$work/app")" ""
edit s2 app
check "a turn that only changed code, with nothing to show, says nothing" "$(run stop s2 "$work/app")" ""
screen s2 app
check "editing a screen without looking at it says nothing" "$(run stop s2 "$work/app")" ""
screen s2 app; shot s2
out=$(run stop s2 "$work/app")
check "a screen changed and Claude took a screenshot: send it now" "$(valid "$out")" "block"
check "the ask names the project and the screenshot" "$(says "$out" 'took a screenshot of it.*post_update for project')" "1"
check "it offers a post with it while none was offered" "$(says "$out" 'call offer_post.*never make a post before their yes')" "1"
check "the same changes are never asked about twice" "$(run stop s2 "$work/app")" ""
screen s2 app; shot s2
check "Claude continuing because of the ask is not asked again" "$(run stop s2 "$work/app" true)" ""
echo '{"attachment":{"type":"deferred_tools_delta","addedNames":["mcp__claude_ai_Buildreel__post_update"]}}' >> "$work/s2.jsonl"
screen s2 app; simshot s2
check "a tool list naming post_update is not an update sent; simctl screenshots count" "$(says "$(run stop s2 "$work/app")" 'took a screenshot')" "1"
# Claude sends the update while continuing: noted then, so the next turn isn't taken for it.
update s2; run stop s2 "$work/app" true >/dev/null
at 5; screen s2 app; shot s2
check "another screen change 5 minutes after an update waits" "$(run stop s2 "$work/app")" ""
at 25; screen s2 app; shot s2
check "20 minutes after the last update, the next screen change is sent" "$(says "$(run stop s2 "$work/app")" 'took a screenshot')" "1"
update s2; run stop s2 "$work/app" true >/dev/null
at 50; screen s2 app; shot s2; update s2
out=$(run stop s2 "$work/app")
check "a turn that sent its own update isn't asked anything more" "$out" ""
at 80; screen s2 app; shot s2
check "three screen updates a chat at most" "$(run stop s2 "$work/app")" ""
tool s2 mcp__claude_ai_Buildreel__offer_post '{"piece":"feature"}'
commit s2 app
out=$(run stop s2 "$work/app")
check "a turn that commits is asked for the session's receipt" "$(says "$out" 'saved work on app.*extra { receipt: true }')" "1"
check "but only if it finished what the person asked for" "$(says "$out" "If their request isn't finished yet, end your turn with no reply")" "1"
check "after one post offer in the chat, no more are asked for" "$(says "$out" offer_post)" "0"
update s2 receipt; run stop s2 "$work/app" true >/dev/null
at 100; commit s2 app
check "one receipt, then the next commit is quiet" "$(run stop s2 "$work/app")" ""
at 205; commit s2 app
check "two hours after the receipt, a commit can close another stretch" "$(says "$(run stop s2 "$work/app")" 'receipt: true')" "1"
# The person wraps up: the session's receipt, even on a turn that changed nothing itself.
say() { printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$2" >> "$work/$1.jsonl"; }
repo wrap; printf '## Buildreel\n' > "$work/wrap/CLAUDE.md"; git -C "$work/wrap" add . && git -C "$work/wrap" -c user.email=t@t -c user.name=t commit -qm rule
run start w1 "$work/wrap"
say w1 "Thats it for today, thanks"
check "wrapping up with no work in the chat says nothing" "$(run stop w1 "$work/wrap")" ""
say w1 "Make the add button green"; edit w1 wrap
check "a plain turn says nothing" "$(run stop w1 "$work/wrap")" ""
say w1 "Perfect. That's it for today!"
out=$(run stop w1 "$work/wrap")
check "wrapping up after work asks for the receipt outright" "$(says "$out" 'wrapping up. Close the session with its receipt')" "1"
update w1 receipt; run stop w1 "$work/wrap" true >/dev/null
say w1 "ok good night"
check "and not again once it's sent" "$(run stop w1 "$work/wrap")" ""
say w1 "One more: fix the typo"; edit w1 wrap; run stop w1 "$work/wrap" >/dev/null
at 15; say w1 "done for now"
check "more work after the receipt, then wrapping up again, asks again" "$(says "$(run stop w1 "$work/wrap")" 'wrapping up')" "1"
at 0
say w1 "Is that the right file?"; tool w1 Bash '{"command":"git status"}'
check "a question is not a wrap-up" "$(run stop w1 "$work/wrap")" ""
say w1 "make the button blue, that's it"; edit w1 wrap
check "a request that ends in \"that's it\" is not a wrap-up" "$(run stop w1 "$work/wrap")" ""
say w1 "add a goodnight reminder screen"; edit w1 wrap
check "nor a request that mentions good night" "$(run stop w1 "$work/wrap")" ""
say w1 "that’s it for today"
check "a curly apostrophe still wraps up" "$(says "$(run stop w1 "$work/wrap")" 'wrapping up')" "1"

# Someone who commits every turn (a backup rule) is asked for the receipt once an hour, not every turn.
repo bk; printf '## Buildreel\n' > "$work/bk/CLAUDE.md"; git -C "$work/bk" add . && git -C "$work/bk" -c user.email=t@t -c user.name=t commit -qm rule
run start b1 "$work/bk"; at 0
commit b1 bk
check "the first commit asks" "$(says "$(run stop b1 "$work/bk")" 'saved work on')" "1"
at 5; commit b1 bk
check "Claude skipped it (mid-task); the next commit 5 minutes later is quiet" "$(run stop b1 "$work/bk")" ""
at 40; commit b1 bk
check "and 40 minutes later" "$(run stop b1 "$work/bk")" ""
at 65; commit b1 bk
check "an hour after the last ask, a commit asks again" "$(says "$(run stop b1 "$work/bk")" 'saved work on')" "1"
at 0

repo late; printf '## Buildreel\n' > "$work/late/AGENTS.md"
screen s3 late; shot s3
check "installed mid-session: the first stop only takes a baseline" "$(run stop s3 "$work/late")" ""

# An older state file (plugin 0.8.0 kept three numbers) still works.
repo old; printf '## Buildreel\n' > "$work/old/CLAUDE.md"
run start s6 "$work/old"; read -r f a b _ < "$BUILDREEL_HOOK_STATE/s6"; printf '%s %s %s' "$f" "$a" "$b" > "$BUILDREEL_HOOK_STATE/s6"
screen s6 old; shot s6
check "an older plugin's state file is read" "$(says "$(run stop s6 "$work/old")" 'took a screenshot')" "1"

# A chat that's resumed keeps what it did: work since its last receipt still counts when the person wraps up.
repo rs; printf '## Buildreel\n' > "$work/rs/CLAUDE.md"; git -C "$work/rs" add . && git -C "$work/rs" -c user.email=t@t -c user.name=t commit -qm rule
run start r1 "$work/rs"; edit r1 rs; run stop r1 "$work/rs" >/dev/null
run start r1 "$work/rs"; say r1 "nice, that's it for today"
check "resuming a chat doesn't forget its work" "$(says "$(run stop r1 "$work/rs")" 'wrapping up')" "1"

# Like Strut's real folder: spaces, a curly and a straight apostrophe, brackets.
odd="Silas’s Mac (2)/it's my app"
mkdir -p "$work/Silas’s Mac (2)"; repo "$odd"; printf '## Buildreel\n' > "$work/$odd/CLAUDE.md"
run start s4 "$work/$odd"; screen s4 "$odd"; shot s4
out=$(run stop s4 "$work/$odd")
check "a folder with spaces and apostrophes still works" "$(valid "$out")" "block"
check "and keeps its name" "$(says "$out" "it's my app")" "1"

# Several sessions in one folder: each is asked only about what it changed itself.
repo team; printf '## Buildreel\n' > "$work/team/CLAUDE.md"
run start lead "$work/team"; run start dev "$work/team"
tool lead Read "{\"file_path\":\"$(top team)/a.txt\"}"
tool lead Bash '{"command":"git status && git log --oneline -5 2>/dev/null | head -n 3 >&2","description":"Show status"}'
other team "dev's work"
check "a session that only read is not asked while another session commits" "$(run stop lead "$work/team")" ""
other team "more of dev's work"; echo wip >> "$work/team/a.txt"; shot lead
check "nor on its next stop, even after a screenshot" "$(run stop lead "$work/team")" ""
tool lead Write '{"file_path":"/elsewhere/notes/Handoff.swift","content":"x"}'; shot lead
other team "dev again"
check "writing a file outside the project does not count" "$(run stop lead "$work/team")" ""
screen dev team; shot dev
check "the session that edits is asked once" "$(valid "$(run stop dev "$work/team")")" "block"
check "and only once" "$(run stop dev "$work/team")" ""
other team "lead commits by hand"
tool dev Bash '{"command":"git add b.txt && git commit -m \"Lead\\u0027s \\\"fix\\\"\"","description":"Commit"}'
check "a commit made through the shell counts" "$(valid "$(run stop dev "$work/team")")" "block"
echo y >> "$work/team/a.txt"
tool dev Bash '{"command":"cat > notes.txt <<EOF\nhi\nEOF","description":"Write notes"}'
check "a shell write with nothing to show says nothing" "$(run stop dev "$work/team")" ""
cp "$work/dev.jsonl" "$work/copy"; cat "$work/copy" >> "$work/dev.jsonl"; other team "lead again"
check "an old tool call logged again later does not count" "$(run stop dev "$work/team")" ""
mkdir -p "$work/dev/subagents"
n=$((n + 1)); printf '{"type":"tool_use","id":"toolu_%s","name":"Edit","input":{"file_path":"%s/Home.swift"}}\n' "$n" "$(top team)" > "$work/dev/subagents/agent-1.jsonl"
echo sub >> "$work/team/Home.swift"; at 30; shot dev
check "a screen edit made by one of the session's subagents counts" "$(valid "$(run stop dev "$work/team")")" "block"
at 0

# ---- Clips (0.10.0): something that moves goes as a short clip of the real app ----
repo mo; printf '## Buildreel\n' > "$work/mo/CLAUDE.md"; git -C "$work/mo" add . && git -C "$work/mo" -c user.email=t@t -c user.name=t commit -qm rule
# Claude in session $1 adds an animation to a screen in repo $2 (or removes one: the old_string holds it).
anim() { echo "$1 anim" >> "$work/$2/Home.swift"; tool "$1" Edit "{\"file_path\":\"$(top "$2")/Home.swift\",\"old_string\":\"Text(a)\",\"new_string\":\"Text(a).transition(.move(edge: .bottom))\"}"; }
unanim() { echo "$1 unanim" >> "$work/$2/Home.swift"; tool "$1" Edit "{\"file_path\":\"$(top "$2")/Home.swift\",\"old_string\":\"withAnimation(.spring) { x }\",\"new_string\":\"x\"}"; }
record() { tool "$1" Bash '{"command":"xcrun simctl io booted recordVideo --codec h264 --force /tmp/r.mov &","description":"Record"}'; }
clip() { tool "$1" mcp__claude_ai_Buildreel__post_update '{"project":"x","sentence":"s","upload_id":"a","recording_id":"b"}'; }
run start m1 "$work/mo"
anim m1 mo
check "animation code never seen running says nothing" "$(run stop m1 "$work/mo")" ""
anim m1 mo; shot m1
out=$(run stop m1 "$work/mo")
check "animation code and a screenshot: a short clip, not a still" "$(says "$out" 'as a short clip instead of a still')" "1"
check "the clip ask is valid JSON" "$(valid "$out")" "block"
check "it says how to record, trim, check and send" "$(says "$out" 'recordVideo.*ffmpeg.*frames.*kind \\"recording\\".*recording_id')" "1"
clip m1; run stop m1 "$work/mo" true >/dev/null
at 25; screen m1 mo; shot m1
out=$(run stop m1 "$work/mo")
check "after a clip, a still screen change is a screenshot again" "$(says "$out" 'took a screenshot')$(says "$out" 'short clip')" "10"
update m1; run stop m1 "$work/mo" true >/dev/null
at 50; unanim m1 mo; shot m1
check "removing an animation isn't motion" "$(says "$(run stop m1 "$work/mo")" 'short clip')" "0"
at 0

run start m2 "$work/mo"
screen m2 mo; run stop m2 "$work/mo" >/dev/null
record m2
check "a recording after a screen change: send it, even on a turn that changed nothing else" "$(says "$(run stop m2 "$work/mo")" 'short clip')" "1"
clip m2; run stop m2 "$work/mo" true >/dev/null
at 30; record m2
check "a recording with no screen change since the last update says nothing" "$(run stop m2 "$work/mo")" ""
at 60; screen m2 mo; record m2
check "a second clip a chat is fine" "$(says "$(run stop m2 "$work/mo")" 'short clip')" "1"
clip m2; run stop m2 "$work/mo" true >/dev/null
at 90; anim m2 mo; shot m2
out=$(run stop m2 "$work/mo")
check "two clips a chat at most, then the screenshot" "$(says "$out" 'took a screenshot')$(says "$out" 'short clip')" "10"
at 0

# Edits made in the shell count too: a script that rewrites a screen file, sed -i on one. Reading one doesn't.
run start m5 "$work/mo"
echo m5 >> "$work/mo/Home.swift"
tool m5 Bash '{"command":"python3 - <<'"'"'EOF'"'"'\np=\"App/Home.swift\"\ns=open(p).read().replace(\"landed = true\", \"withAnimation(.easeInOut(duration: 1.2)) { landed = true }\")\nopen(p, \"w\").write(s)\nEOF","description":"Edit"}'
shot m5
check "a script that adds an animation to a screen file, then a screenshot: a clip" "$(says "$(run stop m5 "$work/mo")" 'short clip')" "1"
run start m6 "$work/mo"
echo m6 >> "$work/mo/Home.swift"; tool m6 Bash '{"command":"sed -i \"\" \"s/Water/Water now/\" App/Home.swift","description":"Edit"}'; shot m6
out=$(run stop m6 "$work/mo")
check "sed -i on a screen file, then a screenshot: the screenshot update" "$(says "$out" 'took a screenshot')$(says "$out" 'short clip')" "10"
run start m7 "$work/mo"
edit m7 mo; tool m7 Bash '{"command":"cat App/Home.swift | grep withAnimation","description":"Read"}'; shot m7
check "reading a screen file is not editing one" "$(run stop m7 "$work/mo")" ""

# A 0.9.0 state file (eleven numbers) still works, and a new recording isn't taken for one already there.
run start m3 "$work/mo"; record m3; run stop m3 "$work/mo" >/dev/null
cut -d' ' -f1-11 "$BUILDREEL_HOOK_STATE/m3" > "$work/st" && mv "$work/st" "$BUILDREEL_HOOK_STATE/m3"
screen m3 mo; shot m3
out=$(run stop m3 "$work/mo")
check "a 0.9.0 state file is read; its old recording isn't new" "$(says "$out" 'took a screenshot')$(says "$out" 'short clip')" "10"
# The commit ask still notes when it went (the state line's eleventh number), now that more follow it.
commit m3 mo; at 1; run stop m3 "$work/mo" >/dev/null
check "the receipt ask's time is kept in its place" "$(cut -d' ' -f11 "$BUILDREEL_HOOK_STATE/m3")" "$BUILDREEL_NOW"
check "and the numbers after it stay" "$(awk '{ print NF }' "$BUILDREEL_HOOK_STATE/m3")" "13"
at 0

# What the server is told: motion, a recording, clips sent so far.
port=$((20000 + RANDOM % 20000))
python3 -c 'import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200); s.end_headers(); s.wfile.write(json.dumps({"decision": "block", "reason": "Q " + s.path}, separators=(",", ":")).encode())
    def log_message(s, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()' "$port" & srvpid=$!
sleep 1
run start m4 "$work/mo"; anim m4 mo; shot m4
out=$(BUILDREEL_URL="http://127.0.0.1:$port" run stop m4 "$work/mo")
check "the server hears motion=1 rec=0 clips=0" "$(says "$out" 'motion=1&rec=0&clips=0')" "1"
clip m4; BUILDREEL_URL="http://127.0.0.1:$port" run stop m4 "$work/mo" true >/dev/null
screen m4 mo; record m4
out=$(BUILDREEL_URL="http://127.0.0.1:$port" run stop m4 "$work/mo")
check "then motion=0 rec=1 clips=1" "$(says "$out" 'motion=0&rec=1&clips=1')" "1"
kill $srvpid 2>/dev/null; wait $srvpid 2>/dev/null

# ---- tokens-hook.sh: the token card's counts, sent in the background ----
# The wording comes from Buildreel's server when it answers (a file stands in for it here).
mkdir -p "$work/srv"; srv="file://$work/srv"
repo served; printf '## Buildreel\n' > "$work/served/CLAUDE.md"; git -C "$work/served" add . && git -C "$work/served" -c user.email=t@t -c user.name=t commit -qm rule
run start s5 "$work/served"
printf '{"decision":"block","reason":"Buildreel: new wording from the server."}\n' > "$work/srv/hook"
screen s5 served; shot s5
check "the server's wording is used when it answers" "$(BUILDREEL_URL=$srv run stop s5 "$work/served")" '{"decision":"block","reason":"Buildreel: new wording from the server."}'
printf '{}' > "$work/srv/hook"; screen s5 served; shot s5
check "the server saying nothing means nothing" "$(BUILDREEL_URL=$srv run stop s5 "$work/served")" ""
printf 'oops' > "$work/srv/hook"; screen s5 served; shot s5
check "an odd answer falls back to the hook's own wording" "$(BUILDREEL_URL=$srv run stop s5 "$work/served" | grep -c "took a screenshot")" "1"

tokens="$(dirname "$hook")/tokens-hook.sh"
export BUILDREEL_TOKEN_KEY="$work/key" BUILDREEL_HOOK_STATE="$work/tstate"
# A stand-in counter that notes how it was run, slowly, like the real one on a big Mac.
printf 'import sys, time\ntime.sleep(2)\nopen("%s/counted", "a").write(" ".join(sys.argv[1:]) + "\\n")\n' "$work" > "$work/counter.py"
export BUILDREEL_COUNTER="$work/counter.py"
trun() { printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"Stop","stop_hook_active":%s}' "$1" "$work/$1.jsonl" "$work/app" "${2:-false}" | "$tokens" stop; }
counted() { for _ in $(seq 20); do [ -f "$work/counted" ] && break; sleep 0.3; done; cat "$work/counted" 2>/dev/null | wc -l | tr -d ' '; }

echo '{"type":"user","message":"hi"}' > "$work/t1.jsonl"
check "no key and no Buildreel connector in the chat: nothing" "$(trun t1)" ""
echo '{"attachment":{"type":"deferred_tools_delta","addedNames":["mcp__claude_ai_Buildreel__count_tokens"]}}' > "$work/t2.jsonl"
check "no key in a chat with the connector, but Claude is already continuing: wait" "$(trun t2 true)" ""
out=$(trun t2)
check "no key in a chat with the connector: Claude is asked to set it up" "$(valid "$out")" "block"
check "with count_tokens keep: true" "$(printf '%s' "$out" | grep -c 'count_tokens with keep: true')" "1"
check "and asked only once, not every turn" "$(trun t2)" ""
check "no counts were sent without a key" "$(counted)" "0"

printf '{"v":1,"send":"https://buildreel.pages.dev/mcp/tokens/key","key":"brk_x"}' > "$work/key"
start=$(date +%s)
check "with a key the hook says nothing" "$(trun s9)" ""
check "and returns at once, the counter runs on its own" "$(( $(date +%s) - start < 2 ))" "1"
check "the counter runs in the background with the key, for this chat" "$(counted)" "1"
check "told which chat it ran after and which folder" "$(grep -c -- '--background --ai claude_code --cwd .*/app --session s9' "$work/counted")" "1"
trun s9 >/dev/null; sleep 3
check "at most once every 30 minutes" "$(counted)" "1"
touch -t 202601010000 "$work/tstate/tokens-sent"; trun s9 >/dev/null
check "and again once 30 minutes passed" "$(sleep 3; counted)" "2"
printf '{"v":1,"stopped":true}' > "$work/key"; touch -t 202601010000 "$work/tstate/tokens-sent"; rm -f "$work/tstate/tokens-asked"
check "a Mac the person stopped is not asked again" "$(trun t2)" ""
check "and sends nothing" "$(sleep 3; counted)" "2"

echo; [ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
