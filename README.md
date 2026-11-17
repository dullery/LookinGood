# Lookin' Good

A World of Warcraft: Forever addon. It tracks your online guild members, and when you're near one it asks you to `/say Hey <name>! Lookin' good!`.

## Install

Copy this folder into the Forever client's `Interface/AddOns/` directory. The folder must be named `LookinGood`.

If the addon shows as "out of date", run this in game to see the client's interface number, then update `## Interface:` in `LookinGood.toc`:

```
/run print((select(4, GetBuildInfo())))
```

## How it works

- **Online members:** The addon reads the guild roster: who's online and which zone they're in.
- **Location sharing (opt-in):** The first time the addon loads, a welcome screen asks you to turn on location sharing. Guildmates who share send their position over the hidden guild addon channel, so the addon knows exactly how far away they are. Sharing works both ways: you see other people's positions only while you share yours. Positions go only to your guild, and only while you're outside instances and out of combat. Change it with `/lg share on` / `/lg share off`, or reopen the screen with `/lg welcome`.
- **Guildmates without the addon:** They're detected when they're a unit you can see (party/raid, target, focus, mouseover, or a friendly nameplate). Then they pass a 15 yard range check, measured with Linen Bandage range. If that check isn't available, the client's ~11 yard trade range is used instead. Turn on friendly nameplates (Shift+V by default) to catch more of them.
- **Greeting:** When someone is in range, a **Say hi to <name>** button appears. Left-click it, or press your keybind (Options → Keybindings → AddOns → Lookin' Good), to send the `/say`. Right-click skips them. Drag the button to move it; `/lg move` shows it any time so you can position it.
- **Cooldown:** Each person is greeted at most once per 30 minutes (configurable).

### Why a click and not fully automatic?

Forever runs on the modern Retail client, and Blizzard only lets `/say` be sent from a real key press or mouse click outside instances. An addon that sends it on a timer gets blocked. So Lookin' Good detects the guildmate and lines up the message, and you fire it with one key or click.

## Commands

| Command | Effect |
| --- | --- |
| `/lg list` | Online guild members, zone, and distance if known |
| `/lg greet` | Greet the next nearby guildmate |
| `/lg on` / `/lg off` | Turn greeting prompts on or off |
| `/lg share on` / `off` | Share positions with the guild (off until you turn it on) |
| `/lg welcome` | Show the welcome screen again |
| `/lg move` | Show the greeting button so you can drag it into place |
| `/lg resetpos` | Put the greeting button back in its default spot |
| `/lg range <yards>` | Greeting distance (default 15) |
| `/lg cooldown <minutes>` | Wait before greeting the same person again (default 30) |
| `/lg message <text>` | Custom greeting; `{name}` is replaced with their name |
| `/lg reset` | Clear greeting cooldowns |
