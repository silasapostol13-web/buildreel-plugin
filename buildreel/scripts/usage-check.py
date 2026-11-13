#!/usr/bin/env python3
# Buildreel usage check: what share of your recent Claude Code sessions went to Buildreel.
# Reads Claude Code's chat logs on this Mac (~/.claude/projects) and prints the result here. It sends nothing
# anywhere: no network code at all (read it first if you like). Run it:
#   curl -fsSL https://buildreel.app/mcp/usage-check.py | python3 -I -
# or, with the plugin installed:  python3 ~/.claude/plugins/cache/buildreel/buildreel/*/scripts/usage-check.py
#
# A model call counts as Buildreel's when it exists only because of Buildreel: it calls a Buildreel tool, it is the
# screenshot or upload step right before one, or it comes after Buildreel's end-of-turn reminder reopened a turn
# (until the next reply), or it is inside a helper agent started for Buildreel work. Each call is weighted the way
# Claude's API prices are shaped (input 1, cache write 1.25 or 2, cache read 0.1, output 5), the fairest single
# "how much usage" number, since Anthropic doesn't publish plan limits in tokens.
import glob, json, os, re, sys, time, statistics as st
from collections import defaultdict

ROOT = os.path.expanduser('~/.claude/projects')
BR_TOOLS = {'post_update', 'get_upload_link', 'catch_up', 'make_post', 'offer_post', 'offer_video', 'get_catalog',
            'setup_project', 'card_status', 'open_on_phone', 'token_card', 'count_tokens', 'live_card', 'connect_check',
            'send_history'}
MARKERS = {'post_update', 'get_upload_link', 'catch_up', 'make_post', 'offer_video'}
UPLOAD_RE = re.compile(r'curl[^|;&]*(-T |--upload-file|-X PUT|--data-binary)[^|;&]*(ecroftwfywadohwprhtz|upload)|buildreel-catchup|count-tokens\.py')
SHOT_RE = re.compile(r'simctl io \S+ (screenshot|recordVideo)|ffmpeg|screencapture')


def weight(u):
    if not u:
        return 0.0
    cc = u.get('cache_creation') or {}
    c1h = cc.get('ephemeral_1h_input_tokens', 0) or 0
    c5m = cc.get('ephemeral_5m_input_tokens')
    total_cc = u.get('cache_creation_input_tokens', 0) or 0
    if c5m is None:
        c5m = max(total_cc - c1h, 0)
    return (u.get('input_tokens', 0) or 0) + 1.25 * c5m + 2 * c1h + 0.1 * (u.get('cache_read_input_tokens', 0) or 0) \
        + 5 * (u.get('output_tokens', 0) or 0)


def load(path):
    """Returns ordered list of events: ('call', id, usage, tool_uses, model) / ('prompt', text) / ('hook', text)."""
    calls = {}
    order = []
    for line in open(path, errors='replace'):
        try:
            d = json.loads(line)
        except Exception:
            continue
        t = d.get('type')
        if t == 'assistant':
            m = d.get('message') or {}
            mid = m.get('id') or d.get('uuid')
            if m.get('model') == '<synthetic>':
                continue
            if mid not in calls:
                calls[mid] = {'usage': None, 'tools': [], 'model': m.get('model'), 'text': ''}
                order.append(('call', mid))
            c = calls[mid]
            if m.get('usage'):
                c['usage'] = m['usage']
            for b in m.get('content') or []:
                if b.get('type') == 'tool_use':
                    c['tools'].append((b.get('name', ''), b.get('input') or {}))
                elif b.get('type') == 'text':
                    c['text'] += b.get('text', '')
        elif t == 'user':
            m = d.get('message') or {}
            content = m.get('content')
            text = content if isinstance(content, str) else ' '.join(
                b.get('text', '') for b in (content or []) if isinstance(b, dict) and b.get('type') == 'text')
            is_result = isinstance(content, list) and any(isinstance(b, dict) and b.get('type') == 'tool_result' for b in content)
            if 'Stop hook feedback' in text:
                order.append(('hook', text))
            elif is_result or d.get('isMeta') or d.get('isCompactSummary'):
                continue
            elif text.strip():
                order.append(('prompt', text))
    return [(k, calls[v]) if k == 'call' else (k, v) for k, v in order]


def tool_short(name):
    return name.rsplit('__', 1)[-1]


def br_prefixes(events):
    p = set()
    for k, v in events:
        if k == 'call':
            for n, _ in v['tools']:
                if n.startswith('mcp__') and tool_short(n) in MARKERS:
                    p.add(n.rsplit('__', 1)[0])
    return p


def is_br_tool(n, prefixes):
    return n.startswith('mcp__') and n.rsplit('__', 1)[0] in prefixes and tool_short(n) in BR_TOOLS


def label(tools):
    names = [tool_short(n) for n, _ in tools]
    if 'catch_up' in names or any(tool_short(n) == 'post_update' and (i.get('at') or i.get('ref')) for n, i in tools):
        return 'catch_up'
    if 'make_post' in names:
        return 'post_made'
    if 'offer_post' in names:
        return 'post_offer'
    for n, i in tools:
        if tool_short(n) == 'post_update':
            ex = i.get('extra') or {}
            if i.get('receipt') or (isinstance(ex, dict) and ex.get('receipt')):
                return 'receipt'
            if i.get('recording_id') or i.get('video'):
                return 'clip'
            return 'update'
    if 'offer_video' in names:
        return 'video_offer'
    if 'setup_project' in names:
        return 'setup'
    if 'connect_check' in names:
        return 'connect_check'
    if names and all(x in ('get_upload_link',) for x in names):
        return 'update'  # upload link without a post_update in the same episode: still update work
    if names:
        return 'tool:' + '+'.join(sorted(set(names)))
    return None


def analyze(path, sub_is_br=False):
    ev = load(path)
    prefixes = br_prefixes(ev)
    total = sum(weight(v['usage']) for k, v in ev if k == 'call')
    ncalls = sum(1 for k, _ in ev if k == 'call')
    episodes = []  # (label, weight, ncalls, hooked)
    if sub_is_br:
        tools = [t for k, v in ev if k == 'call' for t in v['tools']]
        return total, ncalls, [('catch_up_agent', total, ncalls, False)], prefixes
    in_hook = False
    in_catch = False
    cur = None  # [tools, weight, n, hooked]
    calls = [(i, v) for i, (k, v) in enumerate(ev) if k == 'call']
    idx_of = {i: j for j, (i, _) in enumerate(calls)}

    def close():
        nonlocal cur
        if cur:
            lab = label(cur[0]) or ('hook_nothing' if cur[3] else 'other')
            episodes.append((lab, cur[1], cur[2], cur[3]))
        cur = None

    for i, (k, v) in enumerate(ev):
        if k == 'prompt':
            close(); in_hook = False; in_catch = False
            continue
        if k == 'hook':
            if 'Buildreel' in v:
                close(); in_hook = True; cur = [[], 0.0, 0, True]
            continue
        tools = v['tools']
        br = [t for t in tools if is_br_tool(t[0], prefixes)]
        helper = False
        for n, inp in tools:
            s = json.dumps(inp)
            if n == 'Bash' and UPLOAD_RE.search(s):
                helper = True
            if n == 'Bash' and SHOT_RE.search(s):
                # screenshot/clip right before get_upload_link (within the next 3 calls)
                j = idx_of[i]
                for _, nxt in calls[j + 1:j + 4]:
                    if any(tool_short(x) == 'get_upload_link' for x, _ in nxt['tools']):
                        helper = True
        if n_agent := [t for t in tools if t[0] in ('Agent', 'Task') and re.search(r'[Bb]uildreel|catch.?up|history', json.dumps(t[1]))]:
            helper = helper or bool(prefixes)
        if any(tool_short(t[0]) == 'catch_up' for t in br):
            if cur and not in_catch:
                close()
            in_catch = True
        counted = in_catch or in_hook or bool(br) or (helper and bool(tools) and len(br) == 0 and all(
            (n in ('Bash', 'Read', 'Agent', 'Task')) for n, _ in tools))
        if counted:
            if cur is None:
                cur = [[], 0.0, 0, False]
            cur[0].extend(br)
            cur[1] += weight(v['usage'])
            cur[2] += 1
            if (in_hook or in_catch) and not tools:
                # the reopened turn ended (a reply with no tool call)
                close(); in_hook = False; in_catch = False
        else:
            # a plain step: an episode that started in a normal turn ends here
            if cur and not cur[3]:
                close()
    close()
    return total, ncalls, episodes, prefixes


def main():
    days = 14
    if len(sys.argv) > 1 and sys.argv[1].isdigit():
        days = int(sys.argv[1])
    since = time.time() - days * 86400
    sessions = []
    for f in glob.glob(os.path.join(ROOT, '*', '*.jsonl')):
        try:
            if os.path.getmtime(f) < since:
                continue
            text = open(f, errors='replace').read()
        except OSError:
            continue
        if '__post_update"' not in text and 'Buildreel' not in text:
            continue
        total, n, eps, _ = analyze(f)
        for sf in glob.glob(f[:-6] + '/subagents/*.jsonl'):
            st_total, st_n, _, _ = analyze(sf)
            total += st_total
            if re.search(r'__post_update","input":\{[^}]*"at":', open(sf, errors='replace').read()):
                eps.append(('catch_up_agent', st_total, st_n, False))
        if not eps or total <= 0:  # Buildreel's tools only loaded, never used: not a Buildreel session
            continue
        br = sum(e[1] for e in eps)
        kinds = defaultdict(int)
        for e in eps:
            kinds[e[0]] += 1
        sessions.append((os.path.getmtime(f), os.path.basename(os.path.dirname(f)), 100 * br / total, n, kinds))
    print("Buildreel's share of your Claude Code usage, sessions from the last %d days (nothing was sent anywhere)." % days)
    if not sessions:
        print("No sessions with Buildreel in them yet. Build with Buildreel for a few days, then run this again.")
        return
    words = {'update': ('update', 'updates'), 'receipt': ('receipt', 'receipts'), 'clip': ('clip', 'clips'),
             'post_offer': ('post offer', 'post offers'), 'post_made': ('post', 'posts'),
             'video_offer': ('video offer', 'video offers'), 'catch_up': ('history catch-up', 'history catch-ups'),
             'catch_up_agent': ('history catch-up', 'history catch-ups'), 'connect_check': ('check-in', 'check-ins'),
             'setup': ('setup', 'setups'), 'hook_nothing': ('reminder that sent nothing', 'reminders that sent nothing')}
    other = ('other Buildreel step', 'other Buildreel steps')
    print()
    print('  Day     Buildreel  Session size  What Buildreel did')
    for at, folder, share, n, kinds in sorted(sessions, reverse=True)[:20]:
        what = ', '.join('%d %s' % (c, words.get(k, other)[c != 1]) for k, c in sorted(kinds.items(), key=lambda x: -x[1]))
        print('  %s  %6.1f%%  %6d steps  %s' % (time.strftime('%b %d', time.localtime(at)), share, n, what))
    if len(sessions) > 20:
        print('  (the newest 20 of %d)' % len(sessions))
    shares = sorted(s[2] for s in sessions)
    mid = st.median(shares)
    print()
    print('Typical session: %.1f%% of its usage went to Buildreel (median of %d sessions).' % (mid, len(sessions)))
    print('Buildreel aims to stay under 10%% of a normal session. %s' % (
        'Yours is under that.' if mid < 10 else 'Yours is above that: please send Buildreel this result.'))
    print('Short sessions read higher, because Buildreel is a bigger part of less work.')


if __name__ == '__main__':
    main()
