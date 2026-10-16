# fwd command line: design

Date: 2026-10-16. Status: draft for review. Branch: `cli`.

## Goal

Let people and coding agents on the Mac that runs fwd do from a terminal
what they can do in the panel: see hosts and ports with their live state,
forward ports and get their local URLs, wait until a server answers, turn
ports off, remove them, keep them connected, connect a host, and open
Screen Sharing.

An agent (for example Claude Code on the laptop, working on devbox) should
be able to run one command and get back either a working URL or a clear
reason why not, in a form it can parse.

## Decisions already made

- Agents run on the same Mac as fwd. Agents on remote hosts are out of scope.
- The command controls the running app over a private Unix socket (not by
  editing files, not through a URL scheme).
- `forward` is the default command: `fwd 3000` forwards port 3000.
- The host can be left out when exactly one host is connected.
- Work happens on the `cli` branch; merging it to `main` publishes the next
  beta.

## Commands

```
fwd                                      open the window (unchanged)
fwd [forward] [host] <port>... [--keep] [--wait] [--timeout S] [--json]
fwd status [host] [--all] [--json]
fwd wait [host] <port> [--timeout S] [--json]
fwd off [host] <port>... [--json]
fwd remove [host] <port>... [--json]
fwd keep [host] <port>... [--off] [--json]
fwd connect [host] [--timeout S] [--json]
fwd screen [host] [--json]
fwd --version
fwd --help
```

### Choosing the command

- No arguments: open the window, as today.
- `--version` / `-v`: print exactly the app's version (`0.1.0`, `dev`). The
  release and Homebrew checks compare this with the tag, so nothing else may
  be printed.
- `--help` / `-h`: usage.
- If the first word is one of `forward`, `status`, `wait`, `off`, `remove`,
  `keep`, `connect`, `screen`, that is the command.
- Otherwise the command is `forward` and every argument goes to it. So
  `fwd 3000` and `fwd devbox 3000 5173 api` are forwards.
- A host literally named like a command is reached by naming the command:
  `fwd forward status 3000`.

### Host and ports

Positional arguments after the command are read in order:

1. **Host.** If the first argument is a host fwd knows (in the ssh config
   or in `ports.yaml`), it is the host. Otherwise the host is left out.
2. **Ports.** Each following argument is a port in the panel's syntax:
   `3000`, `"3000->4000"`, `"3000 -> 4000"`, `"31**"`, `"3*** -> 4***"`. Ports
   with `->` or `*` need quotes in a shell, which reads `>` as a redirect
   and `*` as a filename pattern.
3. **Names.** An argument that starts with a letter, right after a port, is
   that port's name: `fwd devbox 5173 web 8000 api`. A quoted `"5173 web"`
   works too.

An argument that is none of these (not a command, not a known host, not a
port, not a name in a name's position) is an error: `fwd: "stauts" isn't a
command, a host or a port`, exit 2. A typo never turns into a forward.

**Leaving the host out.** Allowed when exactly one host is connected; that
host is used. With none or several connected, exit 2 and list them:

```
fwd: 2 hosts are connected (devbox, gpu-box); say which, like: fwd devbox 3000
fwd: no host is connected; say which, like: fwd devbox 3000
```

`status` never needs a host. `screen` follows the rule above. `connect` is
for a host that isn't connected yet, so its host can be left out when
exactly one host has ports on and isn't connected.

Host and port resolution happens in the app, which knows the host list and
connection states; the command sends the raw arguments.

### What each command does

All of them go through the same `AppModel` actions the panel uses, and are
logged in fwd's log as `cli: <command> <args>`.

- **forward**: for each port, add it (or turn it on if it is already in the
  list, setting its name if one is given), exactly like typing it in the
  host's field. This counts as a click: the host connects once and does not
  reconnect on its own unless your ssh session is open or the port is kept.
  `--keep` also marks each port Keep connected. Then wait (up to
  `--timeout`, default 30s) until the host is connected and each single port
  is forwarded or blocked. A range returns as soon as the host is connected,
  with whatever it currently forwards. With `--wait`, also wait until each
  single port is live (a server answers on the remote), sharing the same
  timeout.
- **status**: hosts with ports, or that are connected, in panel order; with
  a host, just that host; `--all` includes every host in the ssh config.
- **wait**: block until the port is live, up to `--timeout` (default 60s).
  It does not turn anything on: if the port isn't on, exit 1 with
  `3000 is off on devbox; run: fwd devbox 3000`. For a range, live means at
  least one port in it is live.
- **off**: turn ports off. They stay in the list. Off ports are ignored.
- **remove**: remove ports from the list, on or off.
- **keep**: mark ports Keep connected; `--off` clears it. Clearing it on a
  connected host does not drop the connection (same as the panel).
- **connect**: the Connect button. Waits up to `--timeout` (default 30s)
  for the host to connect.
- **screen**: the Screen Sharing button. Forwards 5900, opens the viewer,
  and prints the `vnc://` URL.

## Output

Human output is short and lines up in columns. `--json` prints exactly one
JSON object on stdout, nothing else; errors in JSON mode are also a JSON
object on stdout (`{"ok":false,...}`), so an agent can always parse stdout.
Human-mode errors go to stderr.

Human examples:

```
$ fwd devbox 3000 5173 web
devbox  3000            http://localhost:3000   live
devbox  web 5173        http://localhost:5173   waiting   nothing listening on the remote yet

$ fwd status
devbox   connected · 3 forwarded
  web     5173 -> 15173   http://localhost:15173   live     kept
  api     8000            http://localhost:8000    live
          9229                                     off
staging  not connected · starts when you ssh in
  admin   8080                                     off
```

### JSON

Every reply has `ok`. A successful reply carries the command's data; a
failed one carries `error` (a sentence) and `code` (the exit code).

A port, as it appears in every reply:

```json
{
  "port": "5173 -> 15173",
  "name": "web",
  "on": true,
  "keep": true,
  "state": "live",
  "reason": null,
  "local": 15173,
  "url": "http://localhost:15173",
  "forwards": []
}
```

- `state` is one of `off`, `pending` (host not connected), `waiting`
  (forwarded, nothing listening), `live`, `active` (live, with a connection
  open through it), `blocked`, `invalid`; `reason` explains `blocked` and
  `invalid`, otherwise null.
- `local` and `url` are null until the port is forwarded. `url` is
  `vnc://...` for Screen Sharing ports and `http://...` otherwise.
- `forwards` lists a range's current ports, each `{"remote", "local",
  "url", "state"}`; empty for a single port.

A host:

```json
{
  "host": "devbox",
  "state": "connected",
  "status": "Connected · 3 forwarded",
  "inSSHConfig": true,
  "ports": [ ... ]
}
```

`state` is one of `idle`, `standby`, `connecting`, `connected`, `retrying`,
`paused`, `needs-attention`; `status` is the card's status line.

Replies:

- `status`: `{"ok":true,"hosts":[host, ...]}`
- `forward`, `off`, `remove`, `keep`, `wait`: `{"ok":true,"host":host}`,
  where `host.ports` holds only the ports the command named.
- `connect`: `{"ok":true,"host":host}`.
- `screen`: `{"ok":true,"host":host,"url":"vnc://kyle@localhost:5901"}`, the
  host object like every other command.
- Failure: `{"ok":false,"code":1,"error":"devbox needs you: ...","host":host?}`.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | done |
| 1 | couldn't do it: needs attention, blocked, unreachable, port off for `wait` |
| 2 | bad usage: unknown command, host or port; host needed but ambiguous |
| 3 | the fwd app couldn't be started or reached, or speaks another protocol version |
| 4 | timed out (`--wait`, `wait`, `connect`, `forward`) |

`forward` exits 0 when every port is forwarded (`waiting`, `live` or
`active`); 1 if any is blocked or the host needs attention; 4 if the
timeout passes first. With `--wait`, only `live` and `active` count.

## How it's built

### In the app: `ControlServer` (FwdCore)

- Listens on `<socketDir>/control.sock`, in the same owner-checked `0700`
  folder as the ssh control sockets (`/tmp/fwd-<uid>/`). A stale socket
  file from a crashed run is removed before binding.
- Accepts a connection, checks the peer is the same user (`getpeereid`), and
  reads one request: a single line of JSON, at most 64 KB, within 5 seconds.
  It writes one reply line and closes the connection.
- Requests are handled on the main actor against `AppModel`. Waiting
  (`forward`, `wait`, `connect`) watches the session states and cards with a
  timeout, never polling faster than every 200 ms, and never holds up other
  requests or the panel.
- Started by `AppModel.start()` and stopped by `shutdown()`. If the socket
  can't be created, the app logs it and carries on without the command line.
- Request envelope: `{"v":1,"cmd":"forward","args":["devbox","3000"],
  "keep":false,"wait":false,"timeout":30,"all":false,"off":false}`. Fields a
  command doesn't use are ignored.
- A request with a different `v` gets `{"ok":false,"code":3,"error":
  "This fwd command and the fwd app are different versions; update fwd."}`.

### The command: `fwd-cli` (new executable target)

- Replaces `scripts/fwd`. `scripts/bundle.sh` copies the built binary to
  `fwd.app/Contents/Resources/bin/fwd`, the path the ~/.local/bin symlink and
  the Homebrew formula already point at, so neither changes.
- Links FwdCore for the request and reply types, `Paths` and `PortPattern`.
- Finds its app by resolving its own path (through symlinks) to the
  enclosing `fwd.app`, and reads the version from that `Info.plist`. Run
  outside a bundle (from `.build`), the version is `dev`.
- Honors `FWD_HOME` like the app, so tests and sandboxes reach a sandboxed
  app's socket.
- No arguments: `open -b io.github.kylefritz.fwd --args --show-window`, falling
  back to opening the enclosing bundle, as the script does today.
- If the socket isn't there or refuses the connection, it starts the app in
  the background without a window (`open -g -b io.github.kylefritz.fwd`,
  falling back to the enclosing bundle), then retries every 200 ms for up to
  10 seconds before exit 3: `fwd: couldn't reach the fwd app; is it
  installed? (open -a fwd)`.
- Its own timeout for a reply is the request's timeout plus 10 seconds.

### Files

- `Sources/FwdCore/Control/ControlProtocol.swift`: request, reply, port and
  host types (Codable), exit codes.
- `Sources/FwdCore/Control/ControlServer.swift`: the socket listener.
- `Sources/FwdCore/Control/ControlHandler.swift`: resolves hosts and ports
  and runs commands against `AppModel`; no socket code, so it can be tested
  directly.
- `Sources/fwd-cli/main.swift` and small siblings: argument parsing,
  launching the app, the socket client, human and JSON output.
- `AppModel` gains only what the handler needs to read (known hosts,
  sessions' states) and to wait on (a way to be notified when cards change).

## Testing

- **Arguments** (`fwd-cli` parsing, as a pure function in FwdCore so tests
  can reach it): the default command, command words, flags, name positions,
  `--version` untouched.
- **Host and port resolution** (handler, with a model built from fixtures):
  known host first, host left out with one, none and two connected hosts,
  a typo, a host named like a port.
- **Handler against `AppModel`** with the fake connection from the
  existing test rig: `forward` reaches `waiting` then `live`; `--keep`;
  `wait` on an off port; `wait` timing out with exit 4; `off`, `remove`,
  `keep --off` on a connected host; needs-attention gives exit 1.
- **Server**: a real socket in a temp folder: one request, one reply;
  oversized and malformed requests; a protocol version mismatch; a stale
  socket file is replaced.
- **End to end**: the integration suite's sshd, a real `AppModel` with
  `ControlServer`, and `CLIRunner` (the command's request loop) in process:
  forward a port, start a server on the remote, `wait`, and fetch through the
  tunnel. The built binary itself is checked by CI's `fwd --version` and
  `fwd --help` steps.
- CI's existing check `fwd --version` = the tag keeps guarding `--version`.

## Documentation

- README "From the terminal" becomes a short section on the command line
  with examples for people and a paragraph for agents (`--json`, exit codes,
  `fwd 3000 --wait`).
- `docs/spec.md` "Terminal command" is rewritten to match this design.
- `fwd --help` lists every command, the port syntax and the exit codes.

## Out of scope

- Agents or commands on remote hosts.
- Editing the ssh config or `config.yaml` from the command line.
- A `log` command (Report a Bug and the log file cover it).
- Shell completion.
