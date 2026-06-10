<a id="readme-top"></a>

<div align="center">
  <img src="icon.png" alt="Beacon Logo" width="128" height="128">
  <h1>Beacon</h1>
  <p>A native macOS menu bar app for monitoring remote GPU servers and Slurm clusters over SSH.</p>
  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple" alt="macOS 14+">
    <img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.2">
    <img src="https://img.shields.io/badge/License-MIT-green.svg?style=flat-square" alt="MIT License">
  </p>
  <p>
    <a href="https://github.com/timkoopmans/beacon/issues">Report Bug</a>
    ·
    <a href="https://github.com/timkoopmans/beacon/issues">Request Feature</a>
  </p>
</div>

> Beacon is a fork of [NVBeacon](https://github.com/jaein4722/NVBeacon) by [Jaein Lee (@jaein4722)](https://github.com/jaein4722). All credit for the original app — the menu bar UI, SSH polling engine, notifications, and packaging — goes to the upstream project. This fork extends it beyond NVIDIA GPU monitoring with host CPU/memory metrics and Slurm cluster status.

## About

Beacon gives you a fast view of one or more remote servers from the macOS menu bar without keeping Terminal open.

It connects over `ssh`, polls each enabled target server, and turns the result into a compact menu bar summary plus a detailed popover UI with GPU utilization, host CPU/memory, Slurm queue state, process details, and job alerts. It is built for people who regularly ask:

- Is the server busy right now?
- Which GPU is running my job?
- Which process is running on that GPU?
- What is in the Slurm queue, and which nodes are free?
- Did my training job finish?
- Has a watched GPU stayed idle long enough to reuse?

## Screenshots

<div align="center">
  <img src="assets/menu-bar-summary.png" alt="Beacon menu bar summary" width="320">
</div>

<p align="center"><em>At-a-glance menu bar summary</em></p>

<div align="center">
  <img src="assets/popover-overview.png" alt="Beacon popover UI in light mode" width="46%">
  <img src="assets/popover-overview-dark.png" alt="Beacon popover UI in dark mode" width="46%">
</div>

<p align="center"><em>Detailed light and dark mode popovers with per-GPU status, process details, and job notification controls</em></p>

## Features

### Added in this fork

- Slurm cluster panel: running/pending job counts, idle/busy node counts, and per-job rows (job ID, partition, user, state, elapsed time, node list)
- Host CPU and memory metrics per server: load, aggregate and per-core CPU utilization, memory usage, and top user processes
- Refined status menu layout

### From NVBeacon

- Native macOS menu bar UI with compact status text or icon-only mode
- Remote NVIDIA GPU monitoring over `ssh` using `nvidia-smi`
- Multiple server targets with per-server enable/disable, authentication, connection reuse, and remote command settings
- Per-GPU utilization, memory, temperature, and process count
- On-demand process details with user, PID, memory, and command preview
- Automatic detection and highlighting of your own remote SSH user processes and GPUs
- Job completion alerts through macOS Notification Center when watched GPU processes exit
- GPU idle notifications with configurable idle duration and memory threshold
- Configurable busy GPU detection based on active processes, memory usage, or utilization
- Optional launch at login using the standard macOS login item mechanism
- Import from local `~/.ssh/config`
- SSH key authentication and password-based authentication
- English / Korean UI with a `System` language option
- Light / dark / system appearance support
- Optional Dock icon and configurable popover outside-click behavior

## Requirements

- macOS 14 or later
- SSH access from your Mac to the target server
- `nvidia-smi` available on the remote host for GPU metrics
- `sinfo`/`squeue` available on the remote host for Slurm metrics (optional)

## Installation

Beacon is built from source. With [just](https://github.com/casey/just) installed:

```bash
git clone git@github.com:timkoopmans/beacon.git
cd beacon
just deploy   # builds Beacon.app and installs it to ~/Applications
```

Other useful recipes: `just test`, `just run` (debug test bundle), `just package` (DMG). Run `just` to list everything.

## Quick Start

1. Launch Beacon.
2. Right-click the menu bar item and open `Settings…`.
3. Add a server target directly or import a saved host from `~/.ssh/config`.
4. Add more server targets if you want one menu bar summary across multiple machines.
5. Choose the authentication method for each server.
6. Allow notifications if you want job completion or GPU idle alerts.
7. Left-click the menu bar item to open the popover.

All settings apply automatically. There is no separate apply button.

## Notifications

Beacon supports two kinds of work alerts for remote GPU jobs:

- `Process Exit`: watch a running GPU process and get notified when it really exits
- `GPU Idle`: star a GPU and get notified when it stays idle long enough for the next job

You can manage notification permission, active watches, and recent notification history from the `Notifications` tab in Settings.

## Settings Overview

Beacon uses a native macOS-style settings window with these sections:

- `General`: server list, per-server connection/authentication, polling, startup, busy GPU detection, update preferences
- `Notifications`: permission, test notification, active watches, history, idle thresholds
- `Appearance`: theme, language, Dock icon, menu bar summary, popover behavior
- `Advanced`: remote command override
- `About`: version, links, runtime summary, and current configuration

## Notes

- Beacon uses your local SSH setup directly, including `~/.ssh/config`.
- In key-based mode, background polling does not read from Keychain.
- In password-based mode, each server password is stored in macOS Keychain and unlocked into memory once per app session to avoid repeated Keychain prompts during polling.
- If the remote non-interactive shell has a limited `PATH`, set `Remote Command` to an absolute path such as `/usr/bin/nvidia-smi`.
- Launch at login is only available from a packaged app bundle, not `swift run`.
- Short release notes are tracked in [CHANGELOG.md](CHANGELOG.md).

## For Developers

Development, packaging, test app, and release workflow notes live in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [NVBeacon](https://github.com/jaein4722/NVBeacon) by [Jaein Lee (@jaein4722)](https://github.com/jaein4722) — the original project this fork is built on
- [Best README Template](https://github.com/othneildrew/Best-README-Template) for the structural inspiration

<p align="right">(<a href="#readme-top">back to top</a>)</p>
