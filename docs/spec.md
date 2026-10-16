# fwd: a small menu bar port forwarder for macOS

Date: 2026-10-09
Status: draft for review

## Purpose

People who develop on remote machines over SSH (a cloud dev box, a home
server, a work VM) keep needing remote ports on their laptop's `localhost`.
Dev servers come and go on many ports, and laptops drop off the network all
the time: the lid closes, the Wi-Fi changes. `fwd` keeps the right remote
ports reachable with almost no interaction, and recovers by itself after a
drop.

Success looks like: open the lid, and within a few seconds every port that was
forwarded before is forwarded again, without touching the app.

A survey of existing tools (Core Tunnel, sshfwd, SSH TunnelBuilder, several
small open-source menu bar apps) found none with wildcard ranges, and none
combining quick add, ranges and liveness. Hence a new app.

## Audience

An open-source tool for technical users: people who already have a working
`~/.ssh/config` and key-based login, and are comfortable with a terminal. The
app has no host setup of its own; if `ssh <host>` works in a terminal, the
host works in fwd. Examples in this document use the made-up hosts `devbox`,
`homelab` and `staging`.

## Scope

In scope:

- Hosts read from `~/.ssh/config`, following `Include`.
- Local forwards only (remote port made reachable on the laptop).
- Per-host port entries with history, on/off toggle, remove, clear all.
- Wildcard entries that follow whatever is listening in a range.
- Optional laptop-side port with `->`.
- Automatic nearby port when the laptop port is taken.
- Status per port: listening and, if the probe succeeds, traffic.
- Automatic reconnect after sleep, lid close, or network loss.
- Menu bar panel, plus a normal window showing the same view.
- Read-only display of each host's `LocalForward` and `RemoteForward` lines
  from the ssh config, with their current status.
- Update check against GitHub releases, with an offer to restart.
- Launch at login.
- A terminal command that opens the app.
- Public repository with README, license and tagged releases.
- Install through Homebrew from the project's own tap.

Out of scope: creating remote forwards, managing the config's own forwards,
SOCKS proxies, editing `~/.ssh/config`, password or interactive
authentication inside the app, non-loopback remote targets, treating two host
aliases as the same machine, Intel Macs, Windows remotes, localization, telemetry of any
kind, and Developer ID signing or notarization (see Distribution).

## Port entry syntax

One text field per host. `*` stands for exactly one digit. Spaces around `->`
are optional and `→` is accepted too.

| Input | Meaning |
|---|---|
| `3000` | remote 3000 on laptop 3000 |
| `3000 -> 4000` | remote 3000 on laptop 4000 |
| `31**` | every listening remote port in 3100 to 3199, same number on the laptop |
| `3*** -> 4***` | every listening remote port in 3000 to 3999, shifted to 4000 to 4999 |

Rules:

- The left side is always the remote port; the right side is the laptop port.
- In a wildcard mapping both sides must have `*` in the same positions, so the
  mapping is a fixed offset.
- Laptop ports below 1024 are rejected at entry (they need root). Remote ports
  below 1024 are fine, for example `80 -> 8080`.
- Entering something already in the history turns it on rather than
  duplicating it.
- An optional name follows the port: `3000 api`, `3000 -> 4000 web`. A name
  is a trailing word that starts with a letter, up to 24 characters. Pills
  show it in front of the port. Re-entering an entry with a name renames it;
  without one, keeps the old name. Right-click → Rename… changes or clears it.

## Laptop port conflicts

If the wanted laptop port is unavailable (used by another process, or by
another fwd forward such as a different host's 3000), fwd picks the next free
port upward, trying up to 50 ports. This applies to plain entries, explicit
`->` entries and each port discovered through a wildcard.

- The pill shows the real mapping, for example `3000 → 3001`, with a marker
  that it was moved.
- The assignment is sticky: it is stored and reused after reconnects so URLs
  stay stable. It is re-picked only if that port is itself taken later. It
  does not jump back when the original port frees up; toggling the entry off
  and on re-evaluates it.
- If nothing is free within 50 ports, the pill shows "blocked".

## Architecture

Swift 6, SwiftUI, SwiftPM package, driving the system `/usr/bin/ssh`. Using
the system client means everything in the user's config (ProxyJump,
ProxyCommand, identity files, the agent, hardware keys, certificates) works
exactly as it does in a terminal, with no SSH implementation of our own.

The app stores desired state and a reconciler makes actual state match it.
Reconnecting is therefore not a special path: after a drop, actual state is
empty and the reconciler re-applies everything.

Units:

- **HostList**: parses `~/.ssh/config` and its `Include`s for concrete `Host`
  names, skipping patterns containing `*`, `?` or `!`. Re-read when the file
  changes and when the panel opens.
- **ConfigForwards**: per host, the `LocalForward` and `RemoteForward` lines
  from `ssh -G <host>`, plus their status. See Forwards from the ssh config.
- **PortPattern**: parses entry text into a remote range plus laptop offset.
  Pure logic.
- **PortAllocator**: given a wanted laptop port and the set of ports fwd
  already holds, returns a free one. A port counts as free only if
  `127.0.0.1` can be bound and nothing answers a connection on it over IPv4
  or IPv6; binding alone would miss a server listening on all interfaces or
  only on `::1`, which a forward would then shadow. Holds the sticky
  assignments.
- **Connection**: one per host that has anything enabled. Owns the ssh master
  process and control socket. Operations: start, check, stop, add forward,
  cancel forward, run a remote command.
- **RemoteScanner**: lists remote listening TCP ports through the master. Runs
  one POSIX `sh` snippet that tries `ss -ltnH`, then `netstat -an`, then
  `lsof -nP -iTCP -sTCP:LISTEN`, so it works on Linux, macOS and BSD remotes
  whatever the user's login shell is. `netstat` comes before `lsof` because
  an unprivileged `lsof` only sees the user's own processes. The script is a
  single line (csh rejects multi-line quoted commands), falls through when
  `ss` exists but fails, and marks its output with a `#fwd:<tool>` line so
  anything a login script prints before it is ignored.
- **TrafficSampler**: which forwarded laptop ports have a connection open,
  from `nettop` samples of the ssh master process.
- **Reconciler**: per host, diffs desired forwards (entries, expanded against
  the scan for wildcards) against active forwards and issues add and cancel
  calls.
- **PowerMonitor**: sleep and wake notifications, `NWPathMonitor`, and the
  clamshell state from IOKit.
- **Store**: YAML in `~/.config/fwd/`, read and written with the Yams
  package. See Storage.
- **Updater**: checks GitHub releases and swaps the app bundle. See Updates.
- **UI**: `MenuBarExtra` with a window-style panel, and a regular `Window`
  hosting the same root view.

### Storage

`~/.config/fwd/ports.yaml` is the user's file: the entries per host, in the
same text form typed into the app. It is safe to edit by hand or keep in
dotfiles.

```yaml
hosts:
  devbox:
    - port: "3000"
      on: true
      name: api
    - port: "3*** -> 4***"
      on: false
  homelab:
    - port: "8080"
      on: true
```

- The app watches the file and reloads on change, so hand edits apply without
  a restart. An unparseable file leaves the running state untouched and shows
  the parse error in the panel; the app does not overwrite it until it parses
  again.
- Writes are atomic (temp file plus rename). Comments in the file are not
  preserved when the app rewrites it.
- Sticky laptop port assignments are app-owned runtime state and live
  separately in `~/.config/fwd/state.yaml`, so `ports.yaml` stays portable
  between machines. Deleting `state.yaml` is harmless.
- `~/.config/fwd/config.yaml` holds preferences: `check_for_updates`
  (default `true`), `send_usage_stats` (default `true`) and `update_channel`
  (`stable` or `beta`, default `stable`). A missing file means defaults.
- `state.yaml` also holds `install_id`, a random UUID made on first launch
  for counting installs. It isn't derived from the machine or the user.

### ssh invocation

Master, one per host:

```
ssh -M -N -S <socket> \
  -o BatchMode=yes -o ClearAllForwardings=yes -o ExitOnForwardFailure=no \
  -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o ConnectTimeout=8 \
  -o ControlPersist=no -o RemoteCommand=none -o RequestTTY=no <host>
```

- Sockets live in `/tmp/fwd-<uid>/` (mode 700) with short hashed names, so
  they never collide with the user's own ControlMaster setup and stay under
  the 104-byte Unix socket path limit whatever the home folder is called.
- `ClearAllForwardings=yes` ignores `LocalForward` and `RemoteForward` lines
  in the config, so fwd never fights a terminal session for those ports. It is
  passed on every ssh invocation, not just the master: a probe showed that a
  command run through the control socket without it makes the master open the
  config's forwards after all.
- `RemoteCommand=none` and `RequestTTY=no` neutralize config entries that
  would otherwise break a background connection or the scan command.
- Host names are passed after `--` and never through a shell, so an unusual
  alias cannot be read as an option or a command.
- Add: `ssh -F none -S <socket> -O forward -L 127.0.0.1:<laptop>:localhost:<remote> <host>`.
  The target is `localhost` so a remote server listening only on IPv6 is
  reached too.
- Cancel: same with `-O cancel`.
- Add and cancel are the exception to the rule above. `ClearAllForwardings`
  on such a call also clears the `-L` being requested, so the call succeeds
  and does nothing. They read no config at all instead (`-F none`), which
  leaves no config forwards to drag along; the socket is all they need.
- At launch, fwd asks any master still listening in its socket folder to
  exit. A run that was killed or crashed would otherwise leave masters
  holding laptop ports. At quit, every master is closed synchronously
  (about two seconds each at most) before the app exits, so a logout or
  restart is never delayed or cancelled.
- Only one copy of the app runs. A second launch brings the first to the
  front and exits, since two copies would close each other's connections.
- Health: `ssh -S <socket> -O check <host>`.
- Scan: `ssh -S <socket> <host> '<scan command>'`.

Forwards always bind `127.0.0.1` on the laptop, never other interfaces.

## Connection lifecycle

Per-host states: idle (nothing enabled), standby (ports on, nothing asking
for a connection), connecting, connected, retrying, paused (asleep or no
network), needs attention.

fwd never holds a connection open just because a port is on. A host with
enabled entries connects only for one of these reasons:

- **Your ssh session.** Every 2 seconds fwd reads `ps` for `ssh` processes
  and takes the destination from each command line (skipping option values,
  `user@` and `ssh://`). `-G`, `-O`, `-Q`, `-V` and `-W` (ProxyJump's hop) are
  not sessions, and fwd's own processes are recognized by its socket
  directory. The host connects when your session appears, reconnects while it
  lasts, and disconnects when your last session to it ends.
- **Keep connected.** An enabled entry with `keep: true` keeps its host
  connected with no session, reconnecting after drops, sleep and network
  changes. Set from the pill's menu, with a pin on the pill.
- **A click.** Turning a port on, Screen Sharing, Connect or Retry connects
  once: the first attempt gets the short schedule (2s, 5s, 15s, 30s) and then
  gives up to standby. After it connects, a drop, sleep or network loss ends
  it; the host goes to standby rather than reconnecting. Unchecking Keep
  connected on a connected host counts as a click, so it doesn't drop mid-use.

In standby the card says "Not connected · starts when you ssh in" with a
Connect button.

- A host disconnects when the last entry is turned off, or when its last
  reason to connect goes away.
- A dead link is noticed within roughly 10 to 15 seconds via the keepalive
  options; the master exits and the host moves to retrying (or standby, if
  only a click connected it).
- Retry schedule while awake with a network path: 2s, 5s, 15s, 30s, then every
  60s for as long as your session lasts or the entry is kept.
- No network path: no polling. The host is paused until `NWPathMonitor`
  reports a usable path.
- Lid closed and asleep: the process is suspended by macOS, so nothing runs.
  On the will-sleep notification hosts are marked paused and masters stopped.
- Lid closed but awake (external display): treated as awake. If the clamshell
  is closed and the link is down, the retry loop skips straight to the 60s
  interval.
- On wake, or when the network path returns: after a 1 second settle, each
  host with your session or a kept entry runs `-O check`, kills a stale master
  if the check fails, and reconnects immediately with the retry schedule
  reset. Other hosts go to standby.
- Screen Sharing turned on by the button turns itself off again: once a
  viewer has connected through the forward and then none has for 30 seconds,
  or if none connects within 2 minutes. A kept Screen Sharing entry stays on.
- A sign-in proxy that opens a browser (cloudflared's "A browser window
  should have opened at the following URL") is "needs attention" even though
  ssh then reports a timeout, so retries never open more browser tabs.
- Authentication never prompts (`BatchMode=yes`). Anything that needs a human
  puts the host in "needs attention" and stops retrying: a key not loaded in
  the agent, a password-only host, an unknown or changed host key, an expired
  single sign-on session behind a ProxyCommand. The card shows the last ssh
  error line with two buttons: "Retry", and "Open in Terminal", which runs
  `ssh <host>` in the user's terminal so they can complete whatever ssh is
  asking for. After a successful retry the host continues normally.

## Scanning and status

While a host is connected the scanner runs every 5 seconds, and immediately
after connect. Each result feeds the reconciler and the pills.

Port states shown on a pill:

| State | Meaning |
|---|---|
| off | entry disabled |
| waiting | forwarded or ready, nothing listening remotely |
| live | a server is listening on the remote port |
| active | live, and a connection is open through it at the last sample |
| moved | modifier: laptop port differs from the wanted one |
| blocked | no laptop port available |

"Active" comes from sampling open connections every few seconds while the
panel or window is showing. A long-lived connection always shows; a single
quick request can fall between samples.

Single-port entries are forwarded as soon as the host connects, listening or
not, so the first request works the moment the server starts. Wildcard entries
forward only ports that are currently listening, and cancel them when they
stop.

## Forwards from the ssh config

Each host card also lists the `LocalForward` and `RemoteForward` lines that
apply to that host, as read-only pills visually distinct from fwd's own
(labelled "config", no toggle). They are read with `ssh -G <host>`, so
`Include` and `Match` are resolved the way ssh resolves them. Commented-out
lines are not shown.

fwd does not open these forwards: its own connections still use
`ClearAllForwardings=yes`. They are opened by the user's own ssh sessions, and
fwd only reports whether that has happened.

Status of a `LocalForward` (checked on the laptop with `lsof`, every 5 seconds
while the panel or window is open):

| State | Meaning |
|---|---|
| on | the laptop port is held by an `ssh` process |
| not forwarded | nothing is listening on the laptop port |
| taken | the laptop port is held by something else; the pill names it, including "fwd" when fwd itself holds it |

Status of a `RemoteForward` (the listener is on the remote, so it needs fwd's
connection to that host):

| State | Meaning |
|---|---|
| on | fwd is connected to the host and its scan sees the remote port listening |
| not forwarded | fwd is connected and the remote port is not listening |
| unknown | fwd has no connection to that host |

Known interaction: fwd does not reserve the config's laptop ports. If fwd is
already holding a port that a config `LocalForward` wants, the user's next ssh
session will fail to bind it, and the config pill shows "taken by fwd". In the
other order, fwd's entry is bumped to a nearby port as usual.

## UI

- Menu bar icon: the fwd mark, two solid rounded chevrons (`>>`), drawn in
  code (`Sources/fwd/Icon.swift`) as a template image. Dimmed when idle, full
  when forwarding, a dot top-right for attention and bottom-right when an
  update is waiting.
- App icon: the same chevrons in white on a green-to-teal rounded square,
  rendered by the app itself (`fwd --write-iconset`) during `scripts/bundle.sh`.
- Panel: one card per host. Each card has the host name, a one-line status, a
  port field (Enter adds) and the entry pills.
- Hosts with entries are listed first as full cards. All other hosts from the
  config sit below in a compact list, and a filter field appears when there
  are more than eight hosts, so a config with hundreds of hosts stays usable.
- Pill: click toggles on or off; hover reveals remove; a live pill has an
  "open" control for `http://localhost:<laptop port>`, or `vnc://` when the
  remote port is 5900 to 5909, which opens the Screen Sharing app. A wildcard
  pill expands to show the ports it currently forwards.
- The menu bar panel shows everything the window does. Its height follows its
  content: the host list is measured and the panel is exactly that tall, up to
  the screen's height, and scrolls only past that. (A bare ScrollView in a
  `MenuBarExtra` window has no height of its own and collapses.)
- Per-host "Clear all" removes that host's history.
- Screen Sharing: every host has a display button. One click adds (or turns
  on) the entry `5900 -> 5901` named `vnc`, waits for the forward, and opens
  `vnc://<ssh User>@localhost:<laptop port>` in macOS's built-in Screen
  Sharing app with the user name filled in. Laptop 5901 because the laptop's
  own Screen Sharing holds 5900; a second host bumps to 5902 as usual. An
  existing entry for remote 5900 is reused, whatever its laptop port. If the
  scan shows nothing listening on 5900 the button says to turn on Screen
  Sharing on that machine instead of opening a dead connection. Auth or
  connection problems surface as the host's usual errors; after 30 s without
  a connection it says so and the forward keeps retrying.
- Footer: "Turn all off", the version, and a ••• menu in four groups, Title
  Case as macOS menus are: "Edit SSH Config", "Edit fwd Settings" (creates
  config.yaml with every option commented), "Show Log" (⌥: "Copy Log
  Location"); "Report a Bug…", "Request a Feature…"; "Check for Updates…",
  "Launch at Login" (a checkbox), "Install Terminal Command"; "Pop Out into a
  Window" (panel only), "Quit fwd" (⌘Q).
- First run with no usable hosts shows a short explanation, an "Open ssh
  config" button, an "Add an example host" button and a link to the README
  instead of an empty panel. The example is a commented `Host devbox` block
  with the user's login name, appended (never written over anything) and
  only offered while the config has no hosts; the file and `~/.ssh` get
  ssh's permissions (0600, 0700) if fwd creates them.
- "Open ssh config" (also in the ••• menu) opens the file in VS Code if it's
  installed, else in `$EDITOR` in a Terminal window (read from the login
  shell, since apps don't inherit the shell's environment), else TextEdit.
- Tone is small and friendly: rounded pills, soft colors, a little motion on
  state changes. Follows light and dark mode. Every state also has a text or
  shape cue and a VoiceOver label, so nothing depends on color alone.

## Errors

- Invalid entry text: the field shakes and shows a one-line reason; nothing is
  stored.
- Forward add fails for a reason other than a port conflict: pill shows
  "blocked" with the ssh message on hover.
- Host removed from the config: its card stays, greyed, until cleared.
- Scan command unavailable on the remote: single ports still forward; wildcard
  pills show "can't scan this host".
- No `~/.ssh/config`, or one that ssh rejects: the panel says so and shows
  ssh's own message.
- The last ssh error line per host is shown on its card; full detail is in the
  log.

## Logging

Everything goes to `~/Library/Logs/fwd/fwd.log` as plain timestamped lines
tagged with the host: state changes, connects and retries, forwards added,
cancelled and bumped, sleep, wake and network events, config and `ports.yaml`
reloads, update checks, and all ssh stderr. Scan results are logged only when
they change. When the file passes 5 MB it is renamed to
`~/Library/Logs/fwd/fwd.log.1`, replacing the previous one. The footer's
"Copy Log Location" (⌥ on "Show Log") puts the full log path on the clipboard, which is the
thing to paste into a bug report.

## Privacy

fwd makes three kinds of network connection: the user's own ssh sessions,
the update check to GitHub, and with each update check a ping to the stats
server that counts installs (see Updates). `send_usage_stats: false` stops
the ping alone; `check_for_updates: false` stops both. It sends nothing
else. The log stays on the machine unless the user puts it in an issue
(see Reporting).

## Distribution

- Source lives in the public GitHub repository `kylefritz/fwd`, MIT licensed.
  The repository slug is one constant in the source, used by the Updater.
- Bundle identifier `io.github.kylefritz.fwd`, `LSUIElement` set so there is no
  Dock icon.
- Requires macOS 26 or later on Apple Silicon. Intel Macs and older macOS
  versions are not supported; 26 is what the app is built and tested on.
- Releases are built by a GitHub Actions workflow on a version tag
  (`vX.Y.Z`): build, bundle, ad-hoc `codesign`, zip, and publish a release
  with one asset, `fwd.zip`. `scripts/bundle.sh` does the bundling and is the
  same script used locally. `scripts/release.sh <version>` stamps the version
  and pushes the tag.
- Building from source needs only Command Line Tools: `make app` produces
  `fwd.app`, `make install` copies it to `/Applications`.
- Homebrew is the recommended install: `brew install kylefritz/tap/fwd`, from
  the project's own tap repository (`kylefritz/homebrew-tap`). It is a formula
  that builds from the tagged source on the user's machine, not a cask that
  downloads the prebuilt app. A locally built app is never quarantined, so
  this route has no Gatekeeper step. The formula installs `fwd.app` under the
  Homebrew prefix and links the `fwd` terminal command onto `PATH`. The
  release workflow updates the formula's URL and checksum on each tag.
- The app is ad-hoc signed and not notarized. A copy downloaded with a browser
  is quarantined and Gatekeeper blocks it until the user approves it in System
  Settings or removes the quarantine attribute. The README gives both sets of
  steps and the build-from-source route, which has no such step.
  Developer ID signing and notarization would remove this friction; it needs a
  paid Apple Developer account and is left for later.
- README covers: what it does, install (Homebrew first), the Gatekeeper step, the entry syntax,
  requirements (key-based login that works without prompts), file locations,
  privacy, and troubleshooting with the log.

## Updates

- Checks `api.github.com/repos/kylefritz/fwd/releases/latest` at launch and
  every 6 hours while awake, and on demand from "Check for updates". The
  automatic checks are skipped when `check_for_updates` is `false`.
- If the release tag is a higher version than the running one, the zip is
  downloaded in the background, unpacked to a temporary folder and checked:
  bundle identifier matches, version matches the tag, `codesign --verify`
  passes.
- A version that is already downloaded and verified is not downloaded again
  by later checks, and its offer stays on screen while they run.
- When it is ready the panel shows "fwd X.Y.Z is ready" with a "Restart to
  update" button and a link to the release notes, and the menu bar icon gets
  a small dot. Nothing restarts without the click.
- On restart the app swaps the new bundle into place, keeping the old one
  until the swap succeeds, then relaunches. Forwards drop for a moment and are
  re-applied at launch from `ports.yaml`.
- If the app's folder is not writable, or any check fails, the panel instead
  offers "Open release page" and the reason is logged.
- Failed checks (offline, rate limited) are logged and retried at the next
  interval, with no UI.
- `bundle.sh` stamps `FwdCommit` (the short commit, `-dirty` with uncommitted
  changes; empty without git, as in Homebrew's tarball build) into
  Info.plist. The footer shows `dev · <commit>` for a dev build, and bug
  reports give the version with the commit. `fwd --version` prints only the
  version, which the release checks compare with the tag.
- A build from source reports version `dev` and never self-updates; it only
  mentions that a release exists.

### Counting installs

- Each update check also sends `POST https://fwd.kylefritz.co/v1/ping`, in
  its own task, with `X-Fwd-Install` (the random `install_id`),
  `X-Fwd-Version`, `X-Fwd-Channel`, `X-Fwd-Kind` (`release`, `homebrew`,
  `source`) and `X-Fwd-OS`. Its answer and failures are ignored. It never
  follows a redirect, so a rule on the domain can't send these details
  elsewhere.
- The Worker in `worker/` adds the IP address and country and writes a row
  to the `fwd_pings` Analytics Engine dataset. Release information and
  downloads always come from GitHub directly, so the stats server can't
  affect updates; on top of that, the updater only downloads from
  `github.com/kylefritz/fwd/releases/download/`.
- `make stats` prints GitHub's download counts per release (which include
  self-updates) and, with Cloudflare credentials, installs per day and per
  version from the dataset.

### Beta channel

- Every commit on `main` that passes CI is published by `beta.yml` as a
  GitHub prerelease named after the next patch: `v0.1.1-beta.<run>`. The
  newest ten are kept; the Homebrew formula only follows tagged releases, and
  `release.yml` ignores beta tags.
- `update_channel: beta` in `config.yaml` makes the updater read
  `releases?per_page=30` instead of `releases/latest` and take the highest
  version among published (non-draft) releases of either kind. Otherwise
  the channel is `stable`, and an unknown value means stable.
- Versions order as `0.1.0 < 0.1.1-beta.57 < 0.1.1-beta.58 < 0.1.1`, so a beta
  install moves onto the release that follows it. The channel is read at
  every check; no restart needed.
- A Homebrew install never replaces itself either, because Homebrew owns
  those files. When a newer release exists the panel shows "fwd X.Y.Z is
  available" with the command `brew upgrade fwd` and a copy button, then
  "Restart to finish updating" once the upgraded version is on disk.

Trust: an update is trusted because it came over HTTPS from the project's
repository, nothing stronger. The README says so. Updates downloaded by the
app are not quarantined and launch normally.

## Reporting

- **Report a Bug…** and **Request a Feature…** in the ••• menu open a window
  with the kind, a title, how much log to include (none, 15 minutes, 1 hour,
  24 hours, 7 days; a bug defaults to the last hour, a feature request to
  none), "Replace host names" (on by default), and a preview of exactly the
  text that will be shared.
- Always removed: URL query strings (sign-in tokens live there), `key=value`
  secrets and `Bearer` credentials, IPv4 addresses, and the home folder
  (shown as `~`). With "Replace host names", ssh host aliases become
  `host1`, `host2`, … numbered by first appearance, other domain names
  become `[hostname]`, and the user name becomes `user`.
- **Continue on GitHub** opens the `bug.yml` or `feature.yml` issue form
  with the title, version, macOS version and log filled in. A log that would
  push the link past 7,500 characters is instead saved to a file shown in
  Finder and copied, and the log field says to drag or paste it in. Nothing
  is posted until the user submits the form.

## Launch at login

A footer checkbox registers the app with `SMAppService.mainApp`. It is off by
default. The checkbox reflects the system's state, so changes made in System
Settings show up.

## Terminal command

Typing `fwd` in a terminal opens the app's window, starting the app first if
it is not running. If it is already running, the existing instance comes to
the front; a second copy is never started.

- The command is a small script shipped inside the bundle at
  `fwd.app/Contents/Resources/bin/fwd`. It asks macOS to open the app by
  bundle identifier, so it keeps working if the app is moved, and it returns
  immediately rather than tying up the terminal.
- `fwd --version` prints the installed version; `fwd --help` prints usage.
  Those are the only arguments.
- The footer item "Install Terminal Command" symlinks the script to
  `~/.local/bin/fwd`, which needs no administrator password. If that folder
  is not on `PATH`, the app shows the one line to add to the shell profile.
  The item reads "Terminal command installed" once the link exists and points
  at this copy of the app. `make install` creates the same link.
- Because it is a symlink into the bundle, updates carry the command along
  with no reinstall.
- A Homebrew install puts `fwd` on `PATH` by itself, and the footer item is
  hidden.
- Without installing anything, `open -a fwd` does the same job.

## Testing

The suite is automatic: `make test` runs all of it locally, and GitHub Actions
runs it on every push and pull request. A release tag is only built if it
passes. No Docker or other external service is needed.

To make that possible the package has two targets: `FwdCore`, a library
holding everything except the views, and `fwd`, the thin SwiftUI app. Tests
drive `FwdCore` headless. Three seams exist for testing and are otherwise
invisible: the ssh config path, the `~/.config/fwd` and log locations, and the
releases URL can each be overridden; retry and poll intervals are injected so
tests run them in milliseconds; and sleep, wake, network and lid events come through
a protocol so tests can fire them.

### Layer 1: unit tests

Pure logic, no processes: PortPattern (valid and invalid entries, wildcard
offsets), HostList parsing including `Include` and pattern hosts, parsing of
`ssh -G` output for config forwards, PortAllocator, Reconciler diffing against
a fake Connection, the retry schedule, version comparison, `ports.yaml`
round-trips and bad-file handling, and scan output parsing from recorded
samples of `ss`, `lsof` and `netstat`.

### Layer 2: integration tests against a real sshd

The test harness starts a throwaway OpenSSH server on `127.0.0.1` on a free
high port, running as the current user with no privileges: a generated host
key, a generated login key, and its own `sshd_config`, all in a temporary
folder, plus a matching temporary ssh config that defines test hosts. This was
tried and works with the stock `/usr/sbin/sshd`, both locally and in principle
on GitHub's macOS runners, which is why no container is needed.

Against it the suite checks, end to end with real `ssh`:

- A forward carries bytes: an HTTP request through the laptop port reaches a
  listener on the "remote" side; after cancel it no longer does.
- A wildcard entry forwards a port when a listener appears in its range and
  cancels it when the listener stops.
- A taken laptop port is bumped to the next free one, and the choice sticks
  across a reconnect.
- Recovery: after the master is killed, and separately after the server is
  stopped and restarted, every enabled forward comes back with no input.
- Simulated sleep, wake and network-loss events pause and resume as specified,
  including no polling while there is no network.
- A host with the wrong key ends in "needs attention" and stops retrying.
- `LocalForward` and `RemoteForward` lines in the test config are listed with
  the right status and are never opened by fwd itself.
- Editing `ports.yaml` on disk is picked up; a broken file is not overwritten.

The harness stops only the processes it started, by the process IDs it
recorded, and never by name, so it cannot touch a real ssh session on the
machine.

### Layer 3: updater tests

A local HTTP server stands in for GitHub and serves a fake "latest release"
and zip. Tests cover: newer, same and older versions; a download that fails
verification; the bundle swap into a temporary folder, including keeping the
old bundle when the swap fails; and the Homebrew and source-build cases that
must not self-replace.

### Layer 4: Linux scan check

The remote scan is a single `sh` script file. A small Linux job in GitHub
Actions runs that script against real `ss` with a known listener and checks
the output parses. This covers Linux remotes without building the app there.

### Not automated

- The look of the panel and window. View logic lives in `FwdCore` view models
  and is unit tested; the pixels are checked by eye.
- Real lid-close and Wi-Fi changes on a laptop, checked by hand before a
  release using a short checklist in the repository.
- The Homebrew formula, checked with `brew install --build-from-source` and
  `brew test` before the tap is updated; the formula's `test` block runs
  `fwd --version`.

## Risks to resolve first

1. **Traffic via `nettop`**: resolved. `nettop` runs unprivileged and lists
   the master's open connections by laptop port; an automated test holds a
   connection open through a forward and sees it. It reports connections
   open at sample time, which is what "active" now means.
2. **`swift test` with Command Line Tools only**: resolved. Swift Testing
   ships with the Command Line Tools but outside the default search path;
   `make test` adds the framework path when Xcode is not selected.
3. **`-O forward` failure reporting**: resolved by a probe. A forward onto a
   busy laptop port exits 255 with only "Port forwarding failed", so ssh's
   message cannot identify a port conflict. The allocator's own test-bind is
   therefore the conflict check, and any `-O forward` failure after a
   successful test-bind is treated as a generic error. The same probe
   confirmed the 104-byte limit on the control socket path.
4. **Launch at login for an ad-hoc signed app**: still unverified. Confirm `SMAppService`
   accepts it. If not, the checkbox is dropped and the README explains adding
   it under Login Items by hand.
5. **Homebrew formula**: still unverified until the first tagged release
   exists to build from. Confirm the app builds inside Homebrew's build
   environment (SwiftPM fetching the Yams dependency there), and that launch
   at login survives a `brew upgrade`, since the app's real path under the
   Homebrew prefix includes the version number.

## Decisions

- **Name**: `fwd`, kept knowing that other small projects share it (several
  dormant port forwarders on GitHub). No Homebrew formula or cask uses the
  name. The README title spells out "fwd: SSH port forwarding for the macOS
  menu bar" so it can be found by search.
