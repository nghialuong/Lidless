# Security Policy

## Supported versions

Lidless is a small project; security fixes land on the latest `main` and the most
recent release. Please test against the latest code before reporting.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately via GitHub's **Security Advisories** — go to the repository's
**Security** tab → **Report a vulnerability**. If you can't use that, email
**nghialt01146@gmail.com** instead.

Please include steps to reproduce, the macOS version, and the impact you observed.
I'll acknowledge as soon as I can and keep you posted on a fix.

## Security-relevant surface

Lidless is not sandboxed and installs a **privileged background helper** to do its job,
so a few areas matter more than usual:

- **Root LaunchDaemon** (`LidlessHelper`) registered via `SMAppService`. It runs as
  root and toggles the macOS `SleepDisabled` flag (`IOPMrootDomain`).
- **XPC interface** (`LidlessHelperProtocol`) between the menu-bar app and the helper —
  the only channel the app uses to change power state.
- **Heartbeat watchdog**: if the app stops checking in (>90s), the helper restores
  normal sleep on its own, so the Mac can't get stuck awake after a crash.
- **Admin-prompt fallback** (`PowerManager`) shells out to `pmset` via `osascript`
  with administrator privileges when the helper isn't installed.

Issues in any of these (privilege escalation, unauthorized XPC use, the watchdog
failing to restore sleep) are the most valuable to report.
