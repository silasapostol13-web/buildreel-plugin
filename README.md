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
  turn, the plugin stays quiet.
- At good moments (a big feature, a new main screen) it offers a video or a post with a one-tap
  Yes / Not now. Nothing is made without your yes.
- It keeps your token card up to date: after chats it sends your AI token counts. Numbers only,
  never chat text, prompts, file paths or code.

## Install

You need the Buildreel iPhone app (TestFlight for now) and the Buildreel connector.

1. Connect Claude to Buildreel: open <https://buildreel.app/connect/claude>, click Add, then
   Connect, and sign in with the same Apple ID you use in the app. Connectors you add on
   claude.ai show up in Claude Code too.
2. Add the plugin in a terminal:

```bash
claude plugin marketplace add silasapostol13-web/buildreel-plugin
```

```bash
claude plugin install buildreel@buildreel
```

3. Restart Claude Code. In a project, ask Claude to "set up this project for Buildreel".

4. Turn on updates, once: in Claude Code type `/plugin`, open **Marketplaces**, pick
   **buildreel** and choose **Enable auto-update**. Claude Code doesn't let a plugin do this for you.
   Without it, update by hand with `claude plugin marketplace update buildreel` and
   `claude plugin update buildreel@buildreel`. The connector itself updates on its own.

## What runs on your Mac

Two small hooks, both in `buildreel/hooks/`, both readable:

- `buildreel-hook.sh` looks at the end of a turn at what the turn did in a Buildreel project (a
  screen edited and screenshotted or recorded, whether the edit added an animation, a commit,
  whether you said you're wrapping up) and, only then,
  reminds Claude to send the update or the receipt. It sends Buildreel a few yes/no flags and
  counts to pick the wording, never your messages or code.
- `tokens-hook.sh` runs `count-tokens.py` in the background. It reads token counts from Claude
  Code's and Codex's local chat logs and sends, per session and day: which AI, a hash of the
  session id, the folder's name, the date and four counts. Its key lives in
  `~/.config/buildreel/token-key`, only on your Mac.

Privacy: <https://buildreel.app/privacy/>. Questions: hello@buildreel.app.
