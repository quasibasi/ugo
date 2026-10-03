# Ugo

macOS notes and todos app, SwiftUI + SwiftData. README.md has the feature
overview and layout of the sources.

## Build and run

Always go through the script:

```bash
scripts/build.sh release --install --run
```

It compiles with swiftc (works while the Xcode license is unaccepted), moves
the result to `~/Applications/Ugo.app`, quits any Ugo already running and opens
the new copy. Use `scripts/build.sh debug --run` only when an unoptimised build
is needed for debugging; it also quits the running copy first.

Never launch the app any other way: no `open build/...`, no `xcodebuild`, no
copying a bundle into `/Applications`. macOS treats every bundle path as a
separate app, so a second copy opened beside the first shows up as a second
Ugo in the Dock and stays listed in Spotlight. Exactly one `Ugo.app` should
exist on the machine, at `~/Applications/Ugo.app`.

Several Claude sessions may work in this repo at the same time. Each rebuilds
and relaunches the same installed copy, so the app restarting is expected.
