# Before a release: checks that aren't automated

Run these on a laptop with the built app and at least one real remote host.

## Sleep, lid and network

- [ ] With a forward live, close the lid for a minute and open it. The forward
      works again within about 10 seconds, with no interaction.
- [ ] Turn Wi-Fi off. The host shows "Paused (no network)" and the log shows
      no retries. Turn Wi-Fi on: it reconnects.
- [ ] Switch to a different network (for example a phone hotspot). Forwards
      recover.
- [ ] With an external display attached and the lid closed, forwards keep
      working.

## The interface

- [ ] Menu bar icon changes between idle, forwarding and attention.
- [ ] Pills: borders and corners look right in light and dark mode.
- [ ] A bad entry shakes the field and explains why.
- [ ] Hovering a pill shows remove; the open button opens the browser.
- [ ] "Open in Terminal" on a host that needs attention opens a terminal
      running `ssh <host>`.
- [ ] VoiceOver reads each pill's port and state.

## Installing and updating

- [ ] "Launch at login" turns on, survives a logout, and turns off.
- [ ] "Install Terminal Command" works, and `fwd open` then opens the window.
- [ ] Quit from the menu: no `ssh` processes for fwd remain
      (`pgrep -fl "/tmp/fwd-"` prints nothing).
- [ ] From the previous release, "Check for updates" finds this one and
      "Restart to update" comes back on the new version with forwards restored.
- [ ] `brew install --build-from-source kylefritz/tap/fwd` and `brew test fwd`
      pass, and `fwd --version` matches the tag.
