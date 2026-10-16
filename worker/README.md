# fwd stats server

A Cloudflare Worker at `https://fwd.kylefritz.co` that counts fwd installs.

Each time fwd checks for updates it also sends `POST /v1/ping` here, with:

| Header | Value |
|---|---|
| `X-Fwd-Install` | a random ID made on first launch (`install_id` in `~/.config/fwd/state.yaml`) |
| `X-Fwd-Version` | the app's version |
| `X-Fwd-Channel` | `stable` or `beta` |
| `X-Fwd-Kind` | `release`, `homebrew` or `source` |
| `X-Fwd-OS` | the macOS version |

The Worker adds the caller's IP address and country and writes one row to
the `fwd_pings` Analytics Engine dataset, then answers `204`. It never
answers with anything the app uses: release information and downloads come
from GitHub directly, so nothing about updates depends on this Worker.
`check_for_updates: false` in `~/.config/fwd/config.yaml` stops the pings too.

```sh
npm install
npm test          # vitest
npm run check     # tsc
npm run deploy    # wrangler deploy; attaches fwd.kylefritz.co
```

`make stats` in the repository root reports downloads and installs.
