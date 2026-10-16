## Install

**Homebrew:** `brew install kylefritz/tap/fwd`

**Download:** unzip `fwd.zip`, drag `fwd.app` into `/Applications`, then run:

```sh
xattr -dr com.apple.quarantine /Applications/fwd.app
```

fwd isn't notarized by Apple, so without that line macOS says it "could not verify fwd is free of malware" the first time you open it. After that, a downloaded copy updates itself.
