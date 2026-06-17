# Lidless

A tiny macOS menu-bar app that keeps your Mac running **even with the lid closed** —
so coding agents (Claude Code, Codex, etc.) keep working while you move around.

> Status: **private / WIP**. Open-source decision not made yet. No license file on purpose.

## How it works

macOS sleeps when you close the lid. The reliable way to override that on Apple Silicon
is the `SleepDisabled` flag in `IOPMrootDomain` (what `sudo pmset -a disablesleep 1` sets).
`caffeinate` does **not** prevent lid-close sleep — only this flag does.

- **M0 (done):** verified on a real Apple Silicon MacBook — lid closed, machine stayed
  reachable over Tailscale. See `scripts/lidless.sh`.
- **M1 (current):** menu-bar app with a single toggle. Sets the flag via `pmset` through an
  admin prompt (`osascript ... with administrator privileges`).
- **M1.5 (next):** privileged helper via `SMAppService` + XPC → password-less, with a
  heartbeat watchdog that auto-clears the flag if the app dies (never get stuck awake).
- **M2 (in progress):** safety guards — low-battery auto-disable, "only while charging",
  thermal auto-pause, persisted preferences. Remaining: app icon + onboarding polish.

## Build

Requires Xcode command-line tools + [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate          # generates Lidless.xcodeproj from project.yml
xcodebuild build -scheme Lidless -destination 'platform=macOS' | xcbeautify
```

The `.xcodeproj` is gitignored — `project.yml` is the source of truth.

## Safety

Running with the lid closed under heavy load can heat the machine and drain the battery.
Keep it plugged in and in a ventilated spot. Always turn it off when you're done.
A reboot resets the flag to default.
