## What and why

<!-- What does this PR change, and why? Link the issue it fixes, e.g. "Fixes #12". -->

## How it was tested

CI only checks that the app builds. Behaviour needs a real iPhone.

- [ ] Ran GreanCast against a real iPhone (`make run` or ⌘R in Xcode)
- [ ] `make selftest` passes
- Tested with: macOS __ · Xcode __ · iPhone __ on iOS __ · USB / Wi‑Fi

<!-- If you changed input handling or the transport, please include measured latencies
     (the inspector shows the last command's latency), not estimates. -->

## Checklist

- [ ] No new dependencies (Apple frameworks only)
- [ ] No compiler warnings
- [ ] No personal signing settings committed (team IDs go in `Config/Local.xcconfig`, which is git-ignored)
- [ ] README / CONTRIBUTING updated if behaviour or setup changed
- [ ] I agree that my contribution is licensed under the MIT License
