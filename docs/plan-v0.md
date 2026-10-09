# fwd Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu bar app that keeps SSH local port forwards alive per
host, with wildcard ranges, auto port bumping, and self-recovery after sleep
or network loss.

**Architecture:** `FwdCore` (library, no views) holds desired state and a
reconciler that drives the system `ssh` through a per-host ControlMaster.
`fwd` is a thin SwiftUI/AppKit shell over it. Tests drive `FwdCore` headless
against a throwaway local `sshd`.

**Tech Stack:** Swift 6 toolchain (language mode 5), SwiftPM, SwiftUI +
AppKit, Yams, Swift Testing, system `/usr/bin/ssh`, GitHub Actions, Homebrew
tap.

**Spec:** `docs/spec.md`

This plan was written for native execution in the same session as the spec,
at the owner's request to go straight to implementation. It fixes file
boundaries, interfaces and order; code is written test-first per task rather
than pre-inlined here.

## Global Constraints

- macOS 26 or later, Apple Silicon only.
- Builds with Command Line Tools only (no Xcode): `swift build`, `swift test`.
- Every `ssh` invocation carries `-o ClearAllForwardings=yes` and
  `-o BatchMode=yes`; host names go after `--`; nothing passes through a shell.
- Forwards bind `127.0.0.1` only. Laptop ports below 1024 are never used.
- Control socket paths stay under 104 bytes.
- Tests stop only processes they started, by recorded PID. Never by name.
- User files: `~/.config/fwd/{ports,state,config}.yaml`. Log:
  `~/Library/Logs/fwd/fwd.log`, rotated at 5 MB to `fwd.log.1`.
- Repo `kylefritz/fwd`; bundle id `io.github.kylefritz.fwd`.
- No network calls except the user's ssh sessions and the GitHub update check.

## Review Focus

1. A config with hundreds of hosts, or hosts using `Match`, `Include` globs,
   quoted names, or tabs: the host list must still load and stay responsive.
2. A hand-edited `ports.yaml` that is empty, half-written, or has the wrong
   shape: the app keeps running on its last good state and does not overwrite.
3. A wildcard range where dozens of ports appear at once, some already taken
   on the laptop: every one gets a distinct laptop port.
4. The remote has none of `ss`, `lsof`, `netstat`, or prints unexpected
   output: single ports still forward; nothing crashes.
5. The master dies while a forward or scan call is in flight: the session
   moves to retrying once, not twice, and no forward is left half-recorded.

## File Map

```
Package.swift
Makefile
Sources/FwdCore/
  Paths.swift             locations + env overrides (FWD_HOME, FWD_SSH_CONFIG, FWD_RELEASES_URL)
  Log.swift               file logger with rotation
  Shell.swift             async Process runner
  PortPattern.swift       entry text -> remote range + laptop offset
  SSHConfig.swift         host list (Include-aware), `ssh -G` forward parsing
  PortAllocator.swift     free-port search, sticky assignments, test-bind
  Store.swift             ports.yaml / state.yaml / config.yaml
  Connection.swift        Connection protocol + SSHConnection (ControlMaster)
  RemoteScanner.swift     scan script + output parsing
  Reconciler.swift        desired vs active -> add / cancel
  PowerMonitor.swift      PowerEvents protocol + SystemPowerMonitor
  HostSession.swift       per-host state machine, retry, scan loop
  ConfigForwards.swift    status of config LocalForward / RemoteForward
  TrafficSampler.swift    per-forward activity
  Updater.swift           release check, verify, swap, install kind
  AppModel.swift          top-level observable model the views bind to
Sources/fwd/
  FwdApp.swift            MenuBarExtra, window, app delegate, reopen handling
  PanelView.swift         host cards, pills, footer
  LoginItem.swift         SMAppService wrapper
  CommandInstaller.swift  ~/.local/bin/fwd symlink
Tests/FwdCoreTests/
  PortPatternTests, SSHConfigTests, PortAllocatorTests, StoreTests,
  ScannerParseTests, ReconcilerTests, VersionTests, UpdaterTests,
  SSHTestServer.swift (throwaway sshd harness), IntegrationTests
scripts/  bundle.sh  release.sh  scan.sh  fwd (terminal command)
.github/workflows/  ci.yml  release.yml
Formula/fwd.rb            copied to kylefritz/homebrew-tap on release
README.md  LICENSE  docs/manual-checklist.md
```

## Tasks

### Phase A: core that forwards

- [ ] **A0 Probes.** Package skeleton with Yams; confirm `swift test` runs
  under Command Line Tools; probe `nettop` for per-port bytes. Record results
  in the spec's risk list.
- [ ] **A1 PortPattern.** `PortPattern.parse(_:) throws -> PortPattern`;
  `remoteRange`, `offset`, `isWildcard`, `canonicalText`, `laptopPort(for:)`.
  Tests: all four table rows, bad input, low laptop ports, mismatched stars.
- [ ] **A2 SSHConfig.** `SSHConfig.hosts(configPath:) -> [String]`;
  `SSHConfig.parseForwards(sshG:) -> [ConfigForward]`. Tests: Include globs,
  pattern hosts skipped, multi-name Host lines, recorded `ssh -G` output.
- [ ] **A3 PortAllocator.** `allocate(wanted:key:) -> Int?`, `release(_:)`,
  `forget(keyPrefix:)`, injectable `isFree`. Tests: bump, sticky, 50 limit,
  many ports at once get distinct results.
- [ ] **A4 Store + Paths + Log.** Load/save with atomic writes, change
  detection by mtime, bad file leaves state alone. Tests: round-trip, empty,
  wrong shape, broken YAML not overwritten, log rotation.
- [ ] **A5 Connection + scanner.** `protocol Connection { start, isAlive,
  stop, addForward, cancelForward, run }`; `SSHConnection`; scan script and
  parsers for `ss`, `lsof`, `netstat`. Tests: parser fixtures; script constant
  equals `scripts/scan.sh`.
- [ ] **A6 SSH test harness + first integration tests.** `SSHTestServer`
  (unprivileged sshd, PID-tracked). Tests: bytes flow through a forward,
  cancel stops it, config forwards are not opened.
- [ ] **A7 Reconciler.** Pure `Reconciler.plan(entries:listening:active:
  allocate:) -> (add, cancel)`. Tests: singles always, wildcards follow the
  scan, nil scan keeps singles, removal cancels.
- [ ] **A8 HostSession + PowerMonitor.** States idle, connecting, connected,
  retrying, paused, needsAttention; `Timing` struct for retry and scan
  intervals; fake power events in tests. Integration tests: wildcard follows
  listeners, bump sticks, recovery after master kill and server restart,
  sleep/wake/network events, wrong key ends in needsAttention, in-flight
  failure retries once.
- [ ] **A9 ConfigForwards + TrafficSampler.** Local status via `lsof`, remote
  status via the scan. Integration test for the three local states.
- [ ] **A10 AppModel.** Owns sessions, store, allocator, power monitor;
  add/toggle/remove/clear/turn-all-off; reload on file change. Tests: add
  duplicate turns on, hand edit applies, last entry off disconnects.

### Phase B: the app

- [ ] **B1 App shell.** `MenuBarExtra` panel + AppKit window, reopen handling,
  host cards, pills, footer with log items. Build and launch check.
- [ ] **B2 bundle.sh + Makefile.** `make app`, `make install`, `make test`.
- [ ] **B3 Terminal command.** `scripts/fwd`, installer to `~/.local/bin`.
- [ ] **B4 Launch at login.** `SMAppService`; verify with ad-hoc signing.

### Phase C: shipping

- [ ] **C1 Updater.** Install kind, version compare, download, verify, swap.
  Tests against a local HTTP server.
- [ ] **C2 CI + release workflows**, Linux scan job.
- [ ] **C3 Homebrew formula**, verified with `brew install --build-from-source`.
- [ ] **C4 README, LICENSE, manual checklist.**
- [ ] **C5 Final review** against the spec, section by section.

Each task ends with `swift test` green and a commit.
