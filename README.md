# sidecar

Connect an iPad as a Sidecar display from the command line.

```sh
sidecar connect       # connect to the first reachable iPad
sidecar disconnect
```

Run `sidecar --help` for exit codes.

## Install

Requires macOS on a Mac that supports Sidecar, and the Xcode Command Line Tools
(`xcode-select --install`). No other dependencies.

```sh
swiftc -O sidecar.swift -o ~/.local/bin/sidecar
```

## Gotcha

Connecting fails if the iPad is locked or asleep, even though it is still
reachable. Wake and unlock it first. The error says so.

## Caveat: private API

There is no public API for Sidecar. This tool drives Apple's private
`SidecarCore` framework, so **a macOS update can break it at any time**. It was
last verified on macOS 26.6.2.

When that happens it exits with code 4 and names what is missing, rather than
crashing. `recon/` has a probe that dumps the framework's current shape, which
is usually enough to fix it — see `recon/README.md`.

## Contributing

Bug reports and fixes are welcome, especially after a macOS update. Please
include your macOS version and the exact error.

The tool is intentionally small: it does what its author actually uses. A new
command is welcome when you have a real need for it, not just because it is
possible.

## License

[MIT](LICENSE)
