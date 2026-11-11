#!/usr/bin/env python3
# Buildreel token counter: adds up your AI's token counts on this Mac and sends the numbers.
# Reads Claude Code's chats (~/.claude/projects) and Codex's (~/.codex/sessions). For each session
# and day it sends: which AI, a hash of the session id, the date, four counts (new input, output,
# cache writes, cache reads) and which project: a project's folder name only when that project is
# set up for Buildreel (a "## Buildreel" section in its CLAUDE.md or AGENTS.md); every other chat is
# sent as "other", with no name. Never chat text, prompts, file paths, other folders' names or code.
# See exactly what it would send: python3 buildreel-tokens.py --dry --json
# Usage: python3 buildreel-tokens.py --send LINK [--ai claude_code|codex] [--keep]   (--dry prints instead)
#   --keep         also save this Mac's lasting key (~/.config/buildreel/token-key, yours only), so
#                  Buildreel's Claude Code plugin can send the numbers after chats. It can only add numbers.
#   --background   what the plugin runs: send with the saved key; does nothing when there is none.
import glob, hashlib, json, os, re, sys, time, urllib.request
from datetime import datetime, timezone

args = sys.argv[1:]
def option(name):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return None
link, current_ai, dry = option("--send"), option("--ai") or "claude_code", "--dry" in args
keep, background = "--keep" in args, "--background" in args
cwd = os.path.realpath(option("--cwd") or os.getcwd())
home = os.path.expanduser("~")
key_file = os.environ.get("BUILDREEL_TOKEN_KEY") or os.path.join(home, ".config", "buildreel", "token-key")

def good_send(url):
    return isinstance(url, str) and (url.startswith("https://") or url.startswith("http://127.0.0.1:"))

# In the background, only a Mac with a live key sends; one the person stopped stays quiet.
saved = None
if background:
    try:
        with open(key_file) as f:
            saved = json.load(f)
    except (OSError, ValueError):
        sys.exit(0)
    if not (isinstance(saved, dict) and good_send(saved.get("send")) and re.match(r"^brk_[A-Za-z0-9_-]{43}$", str(saved.get("key", "")))):
        sys.exit(0)

rows = {}  # (ai, session, project, day) -> [input, output, cache_write, cache_read]
newest = {}  # ai -> (mtime, session) of the newest chat in this folder: "this session"

def hashed(session):
    return hashlib.sha256(session.encode()).hexdigest()[:24]

def local_day(stamp):
    try:
        t = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t.astimezone().strftime("%Y-%m-%d")

# A folder's project name, or "other": only a git project with a "## Buildreel" section in its CLAUDE.md or
# AGENTS.md (the same test the plugin uses) is named, by its top folder. Nothing else's name leaves this Mac.
named = {}
def project_of(folder):
    if folder not in named:
        name, d = "other", os.path.realpath(folder) if folder else None
        while d:
            if os.path.exists(os.path.join(d, ".git")):
                for doc in ("CLAUDE.md", "AGENTS.md"):
                    try:
                        with open(os.path.join(d, doc), encoding="utf-8", errors="ignore") as f:
                            if any(l.startswith("## Buildreel") for l in f):
                                name = (os.path.basename(d) or "other")[:120]
                    except OSError:
                        pass
                break
            up = os.path.dirname(d)
            d = None if up == d else up
        named[folder] = name
    return named[folder]

def add(ai, session, folder, day, counts):
    if not session or not day or not any(counts):
        return
    project = project_of(folder)
    key = (ai, hashed(session), project, day)
    total = rows.setdefault(key, [0, 0, 0, 0])
    for i, n in enumerate(counts):
        total[i] += max(0, int(n or 0))

def note_newest(ai, path, session, folder):
    if session and folder and os.path.realpath(folder) == cwd:
        m = os.path.getmtime(path)
        if ai not in newest or m > newest[ai][0]:
            newest[ai] = (m, hashed(session))

# Claude Code: every reply's usage. A reply is written once per content block, so each is counted
# once by its message and request id (like ccusage). Subagents' chats count too.
claude_dirs = [os.path.join(d, "projects") for d in
               (os.environ.get("CLAUDE_CONFIG_DIR", ""), os.path.join(home, ".claude"), os.path.join(home, ".config", "claude")) if d]
seen = set()
for base in dict.fromkeys(claude_dirs):
    for path in glob.glob(os.path.join(base, "**", "*.jsonl"), recursive=True):
        session = folder = None
        try:
            with open(path, encoding="utf-8", errors="ignore") as f:
                for line in f:
                    if '"usage"' not in line:
                        continue
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    m = d.get("message") if isinstance(d, dict) else None
                    u = m.get("usage") if isinstance(m, dict) else None
                    if d.get("type") != "assistant" or not isinstance(u, dict):
                        continue
                    key = (m.get("id"), d.get("requestId"))
                    if key[0] and key in seen:
                        continue
                    seen.add(key)
                    session, folder = d.get("sessionId") or session, d.get("cwd") or folder
                    add("claude_code", session, folder, local_day(d.get("timestamp", "")),
                        [u.get("input_tokens"), u.get("output_tokens"), u.get("cache_creation_input_tokens"), u.get("cache_read_input_tokens")])
        except OSError:
            continue
        note_newest("claude_code", path, session, folder)

# Codex: running totals in token_count events; each event adds what grew since the one before.
# Its input includes cached input, so new input is input minus cached.
codex_home = os.environ.get("CODEX_HOME") or os.path.join(home, ".codex")
for path in glob.glob(os.path.join(codex_home, "sessions", "**", "*.jsonl"), recursive=True):
    session = folder = None
    last = [0, 0, 0, 0]
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            for line in f:
                if '"session_meta"' not in line and '"token_count"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                p = d.get("payload") if isinstance(d, dict) else None
                if not isinstance(p, dict):
                    continue
                if d.get("type") == "session_meta":
                    session, folder = p.get("id") or session, p.get("cwd") or folder
                    continue
                info = p.get("info") if p.get("type") == "token_count" else None
                t = info.get("total_token_usage") if isinstance(info, dict) else None
                if not isinstance(t, dict):
                    continue
                cached = t.get("cached_input_tokens") or 0
                now = [max(0, (t.get("input_tokens") or 0) - cached), t.get("output_tokens") or 0, t.get("cache_write_input_tokens") or 0, cached]
                grew = [b - a for a, b in zip(last, now)]
                if any(g < 0 for g in grew):  # the totals started over
                    grew = now
                last = now
                add("codex", session, folder, local_day(d.get("timestamp", "")), grew)
    except OSError:
        continue
    note_newest("codex", path, session, folder)

out = [[ai, s, p, day] + counts for (ai, s, p, day), counts in sorted(rows.items(), key=lambda kv: kv[0][3])]
offset = datetime.now().astimezone().utcoffset()
current = newest.get(current_ai)
if option("--session"):  # the plugin knows the chat it ran after
    current = (0, hashed(option("--session")))
payload = {
    "v": 1,
    "today": datetime.now().astimezone().strftime("%Y-%m-%d"),
    "tz_minutes": int(offset.total_seconds() // 60) if offset else 0,
    "current": {"ai": current_ai, "session": current[1]} if current else None,
    "rows": out,
}

def short(n):
    for size, unit in ((1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")):
        if n >= size:
            return ("%.3g" % (n / size)) + unit
    return str(n)

by_ai = {}
for r in out:
    by_ai[r[0]] = by_ai.get(r[0], 0) + sum(r[4:])
names = {"claude_code": "Claude Code", "codex": "Codex"}
summary = ", ".join("%s %s" % (names[a], short(n)) for a, n in sorted(by_ai.items(), key=lambda x: -x[1])) or "no tokens found"
since = out[0][3] if out else None
line = "Counted %s tokens (%s)%s." % (short(sum(by_ai.values())), summary, " since " + since if since else "")

# Claude Code forgets chats 30 days after they were last touched unless cleanupPeriodDays is raised.
keeps = None
try:
    with open(os.path.join(home, ".claude", "settings.json")) as f:
        keeps = json.load(f).get("cleanupPeriodDays")
except (OSError, ValueError):
    pass

def write_key(content):
    os.makedirs(os.path.dirname(key_file), mode=0o700, exist_ok=True)
    fd = os.open(key_file + ".new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(content, f)
    os.chmod(key_file + ".new", 0o600)
    os.replace(key_file + ".new", key_file)

if dry or not (link or saved):
    print(json.dumps(payload) if dry and "--json" in args else line)
    sys.exit(0)
body = json.dumps(payload, separators=(",", ":")).encode()
headers = {"Content-Type": "application/json", "User-Agent": "Buildreel token count"}  # Cloudflare blocks Python-urllib (error 1010)
if saved:
    url = saved["send"]
    headers["Authorization"] = "Bearer " + saved["key"]
else:
    url = link + ("?keep=1" if keep else "")
req = urllib.request.Request(url, data=body, method="POST", headers=headers)
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        reply = json.loads(r.read().decode() or "{}")
except urllib.error.HTTPError as e:
    if saved and e.code == 401:  # the person turned it off: stop for good on this Mac
        write_key({"v": 1, "stopped": True})
        print("Buildreel turned this Mac's key off; background counts stopped.")
        sys.exit(0)
    print("Buildreel didn't take the numbers: %s" % (e.read().decode()[:300] or e.code))
    sys.exit(0 if saved else 1)
except Exception as e:
    print("Couldn't reach Buildreel: %s" % e)
    sys.exit(1)
print(line + " Sent to Buildreel, which now keeps %s days." % reply.get("days", "?"))
if keep and good_send(reply.get("send")) and re.match(r"^brk_[A-Za-z0-9_-]{43}$", str(reply.get("key", ""))):
    write_key({"v": 1, "send": reply["send"], "key": reply["key"]})
    print("Saved this Mac's key, so Buildreel's Claude Code plugin keeps these numbers fresh after chats (numbers, never chat text).")
if reply.get("milestone"):
    print("Milestone: %s. Show it with token_card." % reply["milestone"])
if "claude_code" in by_ai and not keeps:
    print("Note: Claude Code deletes chats 30 days after they were last used; Buildreel keeps the totals it has been sent.")
