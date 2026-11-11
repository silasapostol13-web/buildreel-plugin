# Buildreel for Claude Code

Buildreel turns your AI build sessions into posts you can share: a screenshot and one plain
sentence per update, which the Buildreel iPhone app turns into images and videos for X, Threads,
TikTok and Instagram. The app never posts for you.

This plugin makes Claude Code send those updates by itself:

- While you build: when a screen changes and Claude looks at it (a simulator or browser
  screenshot), that screenshot goes to your phone as an update, a few times a chat at most.
- When what changed moves (an animation, a transition, a short flow) and Claude has seen it
  running, it records a few seconds of the real app doing it, trims it to the moment, checks it,
  and sends that clip instead of a still, ready to post from your phone. Two clips a chat at most.
- When you wrap up ("that's it for today") or Claude finishes what you asked and commits, it
  closes the session with a receipt card: what got done for your users, the day, the time, a
  milestone and what's next. It lands on your phone too.
- All of this only happens in projects you set up for Buildreel (a `## Buildreel` section in the
  project's `CLAUDE.md` or `AGENTS.md`; the connector's `setup_project` writes it). Every other
  turn, the plugin stays quiet. It also waits while your builds, tests or a review are still
  running, and asks for a receipt only after real work (not a session that only wrote notes or
  docs), because each reminder costs a Claude step from your own usage.
- At good moments (a big feature, a new main screen) it offers a video or a post with a one-tap
  Yes / Not now. Nothing is made without your yes.
- It keeps your token card up to date: after chats it sends your AI token counts. Numbers, never
  chat text, prompts, file paths or code. A folder's name goes only for projects you set up for
  Buildreel; every other chat on your Mac is counted together as "other", with no name.

## Install

You need the Buildreel iPhone app ([TestFlight](https://testflight.apple.com/join/f48GWtb3) for now)
and Claude Code or Codex on a Mac.

**One line (easiest).** Open the app, sign in, and it shows a line with your own code to paste into
Terminal. Starting on the Mac instead? Run:

```bash
curl -fsSL https://buildreel.app/install | sh
```

It connects Claude Code and Codex to Buildreel (a browser opens to sign in with the Apple ID you use
on your iPhone), installs this plugin, and makes your first token card. With no code it ends with a
QR code for the app. Read it first if you like: `curl -fsSL https://buildreel.app/install`.

Then, in the project you're building, tell Claude Code "set up Buildreel".

**Just the plugin, by hand:**

```bash
claude plugin marketplace add silasapostol13-web/buildreel-plugin && claude plugin install buildreel@buildreel
```

The plugin needs the Buildreel connector. If you use Claude Code with a Claude account, add it at
<https://buildreel.app/connect/claude> (connectors added on claude.ai show up in Claude Code too). If you
use an API key instead, claude.ai connectors don't reach Claude Code, so add it directly:

```bash
claude mcp add --transport http --scope user buildreel https://buildreel.app/mcp && claude mcp login buildreel
```

Restart Claude Code after installing.

**Turn on updates, once:** in Claude Code type `/plugin`, open **Marketplaces**, pick **buildreel**
and choose **Enable auto-update** (Buildreel's install line from the iPhone app does this for you). Without
it, update by hand with `claude plugin marketplace update buildreel` and `claude plugin update buildreel@buildreel`.
If your plugin is out of date, Claude mentions it once, in one line, the next time Buildreel asks for an update.
The connector itself updates on its own.

## What runs on your Mac

Two small hooks, both in `buildreel/hooks/`, both readable:

- `buildreel-hook.sh` looks at the end of a turn at what the turn did in a Buildreel project (a
  screen edited and screenshotted or recorded, whether the edit added an animation, a commit,
  whether you said you're wrapping up) and, only then,
  reminds Claude to send the update or the receipt. It sends Buildreel a few yes/no flags and
  counts to pick the wording, never your messages or code.
- `tokens-hook.sh` runs `count-tokens.py` in the background. It reads token counts from Claude
  Code's and Codex's local chat logs and sends, per session and day: which AI, a hash of the
  session id, the date, four counts, and the project's folder name only for a project set up for
  Buildreel ("other" for every other chat). To see exactly what it would send:
  `python3 count-tokens.py --dry --json` (it sends nothing). Its key lives in
  `~/.config/buildreel/token-key`, only on your Mac.

Privacy: <https://buildreel.app/privacy/>. Questions: hello@buildreel.app.
