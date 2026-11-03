#!/bin/bash
# Tests for buildreel-hook.sh. Run: claude-plugin/buildreel/hooks/test.sh
hook="$(cd "$(dirname "$0")" && pwd)/buildreel-hook.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/buildreel-hook-test.XXXXXX")
export BUILDREEL_HOOK_STATE="$work/state"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fails=$((fails + 1)); fi; }
# Each session has its own transcript, like Claude Code: $work/<session>.jsonl.
run() { printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"x","stop_hook_active":%s}' "$2" "$work/$2.jsonl" "$3" "${4:-false}" | "$hook" "$1"; }
repo() { mkdir -p "$work/$1" && git -C "$work/$1" init -q && echo hi > "$work/$1/a.txt" && git -C "$work/$1" add . && git -C "$work/$1" -c user.email=t@t -c user.name=t commit -qm one; }
valid() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["decision"])' 2>/dev/null; }
# What a session's transcript records when Claude calls a tool. tool <session> <name> <input json>
n=0
tool() { n=$((n + 1)); printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_%s","name":"%s","input":%s}]}}\n' "$n" "$2" "$3" >> "$work/$1.jsonl"; }
top() { git -C "$work/$1" rev-parse --show-toplevel; }
# Claude in session $1 edits a.txt in repo $2.
edit() { echo "$1" >> "$work/$2/a.txt"; tool "$1" Edit "{\"file_path\":\"$(top "$2")/a.txt\",\"old_string\":\"x\"}"; }
# Another session, working in the same folder, commits.
other() { echo "$2" >> "$work/$1/b.txt"; git -C "$work/$1" add b.txt && git -C "$work/$1" -c user.email=t@t -c user.name=t commit -qm "$2"; }

repo plain
run start s1 "$work/plain"; edit s1 plain
check "does nothing in a project not set up for Buildreel" "$(run stop s1 "$work/plain")" ""

repo app; printf '# App\n\n## Buildreel\nSend updates.\n' > "$work/app/CLAUDE.md"; git -C "$work/app" add . && git -C "$work/app" -c user.email=t@t -c user.name=t commit -qm rule
run start s2 "$work/app"
check "a turn that changed nothing passes" "$(run stop s2 "$work/app")" ""
edit s2 app
out=$(run stop s2 "$work/app")
check "a turn that changed the project asks for an update" "$(valid "$out")" "block"
check "the ask names the project" "$(printf '%s' "$out" | grep -c 'for project')" "1"
check "a video the person asked for goes through offer_video with asked: true" "$(printf '%s' "$out" | grep -c 'asked: true')" "1"
check "the ask also offers a video, only for a core feature or main screen" "$(printf '%s' "$out" | grep -c 'offer_video.*never for tweaks, fixes, small screens')" "1"
check "the same changes are never asked about twice" "$(run stop s2 "$work/app")" ""
edit s2 app
check "Claude continuing because of the ask is not asked again" "$(run stop s2 "$work/app" true)" ""

edit s2 app
echo '{"attachment":{"type":"deferred_tools_delta","addedNames":["mcp__claude_ai_Buildreel__post_update"]}}' >> "$work/s2.jsonl"
check "a tool list naming post_update is not an update sent" "$(run stop s2 "$work/app" | grep -c 'send one now')" "1"
edit s2 app
tool s2 mcp__claude_ai_Buildreel__post_update '{}'
out=$(run stop s2 "$work/app")
check "Claude already sent the update this turn: it's only asked about a post" "$(printf '%s' "$out" | grep -c 'sent its update.*call offer_post')" "1"
check "and the ask doesn't ask for another update" "$(printf '%s' "$out" | grep -c 'send one now')" "0"
edit s2 app
out=$(run stop s2 "$work/app")
check "the next change after that is asked about again" "$(valid "$out")" "block"
check "the update ask also offers a post at a good moment, whatever the project's text says" "$(printf '%s' "$out" | grep -c 'good moment for a post.*call offer_post.*never make a post before their yes')" "1"
tool s2 mcp__claude_ai_Buildreel__offer_post '{"piece":"feature"}'
edit s2 app
out=$(run stop s2 "$work/app")
check "after one post offer in the chat, no more are asked for" "$(printf '%s' "$out" | grep -c offer_post)" "0"
check "but updates still are" "$(valid "$out")" "block"
edit s2 app
tool s2 mcp__claude_ai_Buildreel__post_update '{}'
check "and a turn that sent its update then passes" "$(run stop s2 "$work/app")" ""

repo late; printf '## Buildreel\n' > "$work/late/AGENTS.md"
edit s3 late
check "installed mid-session: the first stop only takes a baseline" "$(run stop s3 "$work/late")" ""

# Like Strut's real folder: spaces, a curly and a straight apostrophe, brackets.
odd="Silas’s Mac (2)/it's my app"
mkdir -p "$work/Silas’s Mac (2)"; repo "$odd"; printf '## Buildreel\n' > "$work/$odd/CLAUDE.md"
run start s4 "$work/$odd"; edit s4 "$odd"
out=$(run stop s4 "$work/$odd")
check "a folder with spaces and apostrophes still works" "$(valid "$out")" "block"
check "and keeps its name" "$(printf '%s' "$out" | grep -c "it's my app")" "1"

# Several sessions in one folder: each is asked only about what it changed itself.
repo team; printf '## Buildreel\n' > "$work/team/CLAUDE.md"
run start lead "$work/team"; run start dev "$work/team"
tool lead Read "{\"file_path\":\"$(top team)/a.txt\"}"
tool lead Bash '{"command":"git status && git log --oneline -5 2>/dev/null | head -n 3 >&2","description":"Show status"}'
other team "dev's work"
check "a session that only read is not asked while another session commits" "$(run stop lead "$work/team")" ""
other team "more of dev's work"; echo wip >> "$work/team/a.txt"
check "nor on its next stop" "$(run stop lead "$work/team")" ""
tool lead Write '{"file_path":"/elsewhere/notes/handoff.md","content":"x"}'
other team "dev again"
check "writing a file outside the project does not count" "$(run stop lead "$work/team")" ""
edit dev team
check "the session that edits is asked once" "$(valid "$(run stop dev "$work/team")")" "block"
check "and only once" "$(run stop dev "$work/team")" ""
other team "lead commits by hand"
tool dev Bash '{"command":"git add b.txt && git commit -m \"Lead\\u0027s \\\"fix\\\"\"","description":"Commit"}'
check "a commit made through the shell counts" "$(valid "$(run stop dev "$work/team")")" "block"
echo y >> "$work/team/a.txt"
tool dev Bash '{"command":"cat > notes.txt <<EOF\nhi\nEOF","description":"Write notes"}'
check "a shell command that writes a file counts" "$(valid "$(run stop dev "$work/team")")" "block"
cp "$work/dev.jsonl" "$work/copy"; cat "$work/copy" >> "$work/dev.jsonl"; other team "lead again"
check "an old tool call logged again later does not count" "$(run stop dev "$work/team")" ""
mkdir -p "$work/dev/subagents"
n=$((n + 1)); printf '{"type":"tool_use","id":"toolu_%s","name":"Edit","input":{"file_path":"%s/a.txt"}}\n' "$n" "$(top team)" > "$work/dev/subagents/agent-1.jsonl"
echo sub >> "$work/team/a.txt"
check "an edit made by one of the session's subagents counts" "$(valid "$(run stop dev "$work/team")")" "block"

# ---- tokens-hook.sh: the token card's counts, sent in the background ----
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
