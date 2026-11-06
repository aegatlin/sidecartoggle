# CLAUDE.md

Implementation notes for `sidecar`. Read this before changing `sidecar.swift`.

## What this is

A single-file Swift CLI that connects and disconnects an iPad Sidecar display by
driving Apple's **private** `SidecarCore` framework through the Objective-C runtime.
There is no public API for this. Assume Apple will eventually break it.

- Source: `sidecar.swift` (one file, no SwiftPM manifest, no Xcode project)
- Build: `swiftc -O sidecar.swift -o ~/.local/bin/sidecar`
- Diagnostics: `recon/` — not built, not shipped. See `recon/README.md`.
- CI: `.github/workflows/build.yml` compiles on a macOS runner and smoke-tests the
  exit codes that never reach SidecarCore (help, usage errors). It has no iPad, so it
  cannot test connect/disconnect. Keep the smoke test in step with `--help`.
- License: MIT. Open source, not monetized.

## Scope

Deliberately tiny. The owner has one iPad and only ever runs `sidecar connect`
(disconnecting is usually done from the iPad). The CLI is exactly:

```
sidecar connect | disconnect | --help
```

Both commands act on the first device SidecarCore reports. There are no flags, no
device-name argument, no status/list/toggle commands, no `--json`, and a fixed 15s
timeout. An earlier version had all of those; they were removed as unused. The
policy is to add a command only once there is a real need for it, not because it is
possible. Do not add them back unless asked. If you ever need connection status, `connectedDevices`
is the mechanism (see below).

## Architecture

All private-API contact is confined to the `SidecarCore` class in `sidecar.swift`.
It exposes a typed Swift interface:

```swift
init() throws
func devices() throws -> [Device]
func connect(_ device: Device, timeout: TimeInterval) throws
func disconnect(_ device: Device, timeout: TimeInterval) throws
```

`Device` carries `name` and a `fileprivate` `NSObject` handle. Nothing outside
that class references `dlopen`, `perform(Selector(...))`, `NSClassFromString`, or the
framework's existence. **Keep it that way** — the command layer must stay testable and
free of Objective-C.

Selector names are `private static let` constants at the top of the class, so a macOS
update that renames one is a one-line fix.

## The private API surface (verified on macOS 26.6.2)

`/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore`

**`SidecarDisplayManager`** (`+sharedManager`, `+isSupported`, `+model`)

| Member | Notes |
|---|---|
| `devices` → NSArray | All reachable devices. Includes disconnected ones. **Used.** |
| `connectedDevices` → NSArray | The status mechanism, if ever needed. Empty when nothing is connected. Not used. |
| `recentDevices` → NSArray | Not used. |
| `configForDevice:` → SidecarDisplayConfig | Non-nil only while connected. Not used. |
| `connectToDevice:completion:` | **Used.** completion is `@convention(block) (NSError?) -> Void` |
| `connectToDevice:withConfig:completion:` | **Deliberately unused** — see Non-goals. |
| `disconnectFromDevice:completion:` | **Used.** |

**`SidecarDevice`**: `name`, `identifier` (NSUUID), `model`, `version`, `deviceType`
(UTType), `status` (opaque `unsigned long long`), plus camera and capability accessors.

`SidecarDisplayConfig` exists with 22 properties including `transport`. Unused.

## If status is ever needed: `connectedDevices`, not `system_profiler`

Measured both states against `system_profiler SPDisplaysDataType` ground truth:

| | connected | disconnected |
|---|---|---|
| `devices` | 1 | 1 |
| `connectedDevices` | **1** | **0** |
| `configForDevice:` | displayID 4 | nil |
| `status` | `0x8000880302` | `0x880302` |

`connectedDevices` is exact. `system_profiler` costs 1–2s per call and is only a
fallback if this ever breaks.

Bit 39 of `SidecarDevice.status` is evidently the connected flag. **Do not depend on
it** — it is an undocumented bitfield with no stable meaning.

There is no notification, delegate, or observer API. A 3-second listen on both
`NotificationCenter` and `DistributedNotificationCenter` produced nothing, and the
manager exposes no observer registration. Do not go looking again.

## Timeouts

The prior art (`Ocasio-J/SidecarLauncher`) uses a bare `DispatchGroup.wait()` and hangs
forever if the completion block never fires. `SidecarCore.invoke` instead:

1. Installs a 0.05s repeating `Timer` as a run-loop source. Without a source,
   `RunLoop.run(mode:before:)` returns instantly and the loop spins hot on CPU.
2. Polls a lock-guarded `finished` flag until the deadline, running the loop in
   0.05s slices. Do not pass the full deadline to `run(mode:before:)`: a timer firing
   does not make it return (only an input source does), so a completion delivered on
   another queue would go unnoticed until the timeout.

Spinning the run loop rather than blocking the thread means a completion delivered on
the **main queue** would still land, instead of deadlocking. In practice SidecarCore
delivers on its own queue, but this costs nothing and removes the failure mode.

**A timed-out connect is not cancelled.** SidecarCore has no cancel API, so the
connection may still complete a second after exit 5. This is inherent. It is why the
fixed timeout is a generous 15s.

## Exit codes

`0` success · `1` bad usage · `2` no devices reachable · `4` SidecarCore error **or
private API unavailable** · `5` timed out.

There is no `3`: it meant "device not found or ambiguous" and went away with name
matching. The gap is intentional, so the remaining codes keep their meaning. Every code
is documented in `--help`; do not add an undocumented one. Errors go to stderr,
the success line (`connected: <name>`) to stdout.

## Known SidecarCore error codes

| Code | Meaning | Handling |
|---|---|---|
| `-100` | "The device is already in use." | `localizedDescription` is already plain English; passed through |
| `-102` | "The device is not connected." | Same |
| `-203` | `SidecarErrorDeviceWiFiNotEnabled` | **Special-cased.** Really means the iPad is locked or asleep. Replaced with a plain-English hint. |

## Failure when the API is gone

`SidecarCore.init` validates the dlopen, the class, `+sharedManager`, and all four
instance selectors up front, throwing `.unavailable(String)` naming exactly what was
missing. No `fatalError`, no force-unwraps on private-API results, no crash report.
Preserve this property.

## Verified vs unverified

Exercised on real hardware (before the surface was cut down): connect/disconnect
round-trips (connect ~1.5s, disconnect ~0.03s), exit 1, exit 5, and the `-100`/`-102`
paths.

**Not yet exercised:** exit 2 (needs Wi-Fi/Bluetooth off) and the `-203` hint (needs a
locked iPad). The `-203` string is written from the documented behaviour, not observed.

## Gotchas hit during reconnaissance

If you rewrite `recon/probe.swift`, these will bite again:

- **Never call `NSStringFromClass` while iterating `objc_copyClassList`.** It aborts on
  internal classes (`__NSGenericDeallocHandler` does not implement
  `methodSignatureForSelector:`). Use `class_getName`, or better
  `objc_copyClassNamesForImage` — though that returns nothing here, since SidecarCore
  lives in the dyld shared cache rather than being separately loaded.
- **Never `perform()` a selector whose return type is not an object.** Check the type
  encoding starts with `@` first; call `B`/`Q`/`q` returns through a typed
  `@convention(c)` function pointer instead. `SidecarDevice.status` is `Q`.
- **`setvbuf(stdout, nil, _IONBF, 0)`** when probing. Redirected stdout is block
  buffered, so a crash truncates output at a 4KB boundary and makes the crash look like
  it happened somewhere it didn't.
- `String(cString:)` needs an optional-unwrapping helper for the runtime's
  `UnsafePointer<CChar>?` returns.

## Non-goals

Do not add, unless asked: the wired transport (`SidecarDisplayConfig` + `setTransport:`
value 2 + `connectToDevice:withConfig:completion:`), a GUI, a menu bar item, a launchd
agent, a login item, an installer script, window-moving logic (Rectangle handles that),
or any external dependency including ArgumentParser.

The binary lives at `~/.local/bin/sidecar`, which is on PATH via `.zshrc`. It is invoked
manually.
