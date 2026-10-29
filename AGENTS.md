# Working on fwd

How changes to fwd are made. The README covers using it; `make test` and
`make app` build and test it.

## Every new feature logs what it does

fwd runs on someone's laptop and talks to hosts we can't see, so the log is
how a problem gets diagnosed after the fact. Each new feature writes to it
with `log.write(_:host:)`:

- each step it takes, and which way it went (fwd's connection or a one-off
  ssh, a setting that turned it off);
- what came back, summarized: counts, names, how long it took;
- every failure, with the message the user didn't see in full.

Log enough to answer "why did it show that?" from the log alone. Never log
secrets. The log is `~/Library/Logs/fwd/fwd.log` (`$FWD_HOME/logs/fwd.log`
when `FWD_HOME` is set), and it's what the Report a Bug window attaches.

## Pull requests need screenshots

A pull request that changes anything you can see includes screenshots in its
description, under a `## Screenshots` heading, so it can be reviewed without
building the app. Show the state the change is about (an open menu, an error,
a toggle switched on), and before and after for a visual fix. Look at each
image yourself before posting it.

The app can draw itself with no one at the screen. After `swift build`:

| Flag | Draws |
|------|-------|
| `.build/debug/fwd --snapshot-panel out.png` | the menu bar panel |
| `--snapshot-hero out.png` | the README picture (run it against a demo ssh config) |
| `--snapshot-report out.png` | the Report a Bug window |
| `--snapshot-herdr out.png` | the VS Code button's menu in each state |
| `--light` | any of these in light mode |

Run snapshots with `FWD_HOME` pointed at a scratch folder and
`FWD_STATS_SERVER=` (empty), so they don't touch your own fwd or send pings.

### Hosting the images: hidden-ref image hosting

This needs no image bucket and adds nothing to the repo's history.

1. Use GitHub's Git Data API to make a blob for each image.
2. Make a tree holding those blobs.
3. Make an orphan commit (no parents) from that tree, so it holds just the images.
4. Point a ref under `refs/uploads/` at the commit, for example
   `refs/uploads/pr-42-<timestamp>`.

Clones don't fetch that namespace, so the images never reach anyone's
checkout. Link each image by the commit's SHA:

```
https://github.com/<owner>/<repo>/blob/<sha>/<file>.png?raw=true
```

Because the link names a commit, an image already in a description never
breaks. Anyone who can see the pull request can see the images. Name image
files for what they show, since the name becomes the alt text.
