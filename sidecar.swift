// sidecar — connect/disconnect an iPad as a Sidecar display from the command line.
//
// Build:  swiftc -O sidecar.swift -o ~/.local/bin/sidecar
//
// Everything that touches Apple's private SidecarCore framework lives in the
// `SidecarCore` type below. The command layer never learns the framework exists.

import Foundation

// MARK: - Exit codes

enum ExitCode: Int32 {
    case success      = 0
    case usage        = 1
    case noDevices    = 2
    case sidecarError = 4
    case timedOut     = 5
}

func fail(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data("sidecar: \(message)\n".utf8))
    exit(code.rawValue)
}

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data("\(line)\n".utf8))
}

// MARK: - Private-API isolation layer
//
// The only part of the program that knows about SidecarCore, `perform(Selector(...))`,
// or Objective-C at all. It presents a small typed Swift interface and turns every
// missing class or selector into a `SidecarCoreError.unavailable` rather than a crash.

struct Device {
    let name: String
    fileprivate let object: NSObject
}

enum SidecarCoreError: Error {
    /// The private API is gone or has changed shape. The payload names what was missing.
    case unavailable(String)
    /// SidecarCore ran and reported a failure.
    case failed(code: Int, message: String)
    /// The completion block never fired within the deadline.
    case timedOut(TimeInterval)
}

final class SidecarCore {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"

    private static let managerClassName   = "SidecarDisplayManager"
    private static let devicesSelector    = "devices"
    private static let connectSelector    = "connectToDevice:completion:"
    private static let disconnectSelector = "disconnectFromDevice:completion:"
    private static let nameSelector       = "name"

    private let manager: NSObject

    init() throws {
        guard dlopen(Self.frameworkPath, RTLD_LAZY) != nil else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            throw SidecarCoreError.unavailable("could not load \(Self.frameworkPath): \(reason)")
        }

        guard let managerClass = NSClassFromString(Self.managerClassName) as? NSObject.Type else {
            throw SidecarCoreError.unavailable("class \(Self.managerClassName) not found")
        }

        let shared = Selector(("sharedManager"))
        guard managerClass.responds(to: shared) else {
            throw SidecarCoreError.unavailable("+[\(Self.managerClassName) sharedManager] not found")
        }
        guard let instance = managerClass.perform(shared)?.takeUnretainedValue() as? NSObject else {
            throw SidecarCoreError.unavailable("+[\(Self.managerClassName) sharedManager] returned nothing")
        }
        manager = instance

        // Check every selector we depend on up front, so a broken API is reported once
        // and clearly rather than mid-operation.
        for selector in [Self.devicesSelector, Self.connectSelector, Self.disconnectSelector] {
            guard manager.responds(to: Selector((selector))) else {
                throw SidecarCoreError.unavailable("-[\(Self.managerClassName) \(selector)] not found")
            }
        }
    }

    /// Every Sidecar-capable device currently reachable, connected or not.
    func devices() throws -> [Device] {
        guard let raw = manager.perform(Selector((Self.devicesSelector)))?
            .takeUnretainedValue() as? [NSObject] else { return [] }

        let nameSel = Selector((Self.nameSelector))
        return try raw.map { object in
            guard object.responds(to: nameSel) else {
                throw SidecarCoreError.unavailable("-[SidecarDevice \(Self.nameSelector)] not found")
            }
            let name = object.perform(nameSel)?.takeUnretainedValue() as? String ?? "(unnamed device)"
            return Device(name: name, object: object)
        }
    }

    func connect(_ device: Device, timeout: TimeInterval) throws {
        try invoke(Self.connectSelector, on: device, timeout: timeout)
    }

    func disconnect(_ device: Device, timeout: TimeInterval) throws {
        try invoke(Self.disconnectSelector, on: device, timeout: timeout)
    }

    /// Calls a `…Device:completion:` selector and waits for the completion block,
    /// giving up after `timeout`. The run loop is kept spinning so a completion
    /// delivered on the main queue would land instead of deadlocking.
    private func invoke(_ selectorName: String, on device: Device, timeout: TimeInterval) throws {
        let lock = NSLock()
        var finished = false
        var failure: NSError?

        let completion: @convention(block) (NSError?) -> Void = { error in
            lock.lock()
            finished = true
            failure = error
            lock.unlock()
        }

        _ = manager.perform(Selector((selectorName)), with: device.object, with: completion)

        let deadline = Date().addingTimeInterval(timeout)

        // A repeating timer gives the run loop a source, so run(mode:before:) blocks
        // for a tick instead of returning instantly and burning CPU.
        let keepAlive = Timer(timeInterval: 0.05, repeats: true) { _ in }
        RunLoop.current.add(keepAlive, forMode: .default)
        defer { keepAlive.invalidate() }

        while true {
            lock.lock()
            let done = finished
            let error = failure
            lock.unlock()

            if done {
                if let error {
                    throw SidecarCoreError.failed(code: error.code,
                                                  message: error.localizedDescription)
                }
                return
            }
            if Date() >= deadline {
                throw SidecarCoreError.timedOut(timeout)
            }
            // Bound each wait to one tick. A timer firing does not make run(mode:before:)
            // return — only an input source does — so waiting until `deadline` would
            // miss a completion delivered off the main thread until the timeout expired.
            RunLoop.current.run(mode: .default,
                                before: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }
}

// MARK: - Error reporting

/// Apple returns this when the iPad is unreachable over the wireless link — in practice,
/// almost always because it is locked or asleep. It still appears in the device list.
let deviceWiFiNotEnabled = -203

let timeout: TimeInterval = 15

func report(_ error: Error, action: String, device: Device?) -> Never {
    guard let error = error as? SidecarCoreError else {
        fail("\(action) failed: \(error.localizedDescription)", .sidecarError)
    }

    let name = device.map { " '\($0.name)'" } ?? ""

    switch error {
    case .unavailable(let missing):
        fail("""
             the private SidecarCore API this tool depends on is unavailable: \(missing).
             A macOS update has probably changed or removed it.
             """, .sidecarError)

    case .timedOut:
        fail("\(action)\(name) timed out after \(Int(timeout))s.", .timedOut)

    case .failed(let code, let message):
        if code == deviceWiFiNotEnabled {
            fail("""
                 \(action)\(name) failed: the iPad is not reachable. It is almost \
                 always locked or asleep — wake it and unlock it, then try again.
                 (SidecarErrorDeviceWiFiNotEnabled, \(code))
                 """, .sidecarError)
        }
        fail("\(action)\(name) failed: \(message) (\(code))", .sidecarError)
    }
}

// MARK: - Help

let helpText = """
sidecar — connect and disconnect an iPad Sidecar display

USAGE
  sidecar connect      Connect to the first reachable iPad
  sidecar disconnect   Disconnect from it
  sidecar --help       Show this text

EXIT CODES
  0  success
  1  bad usage
  2  no Sidecar-capable devices reachable
  4  SidecarCore reported an error, or its private API is unavailable
  5  timed out after 15s waiting for SidecarCore

NOTES
  Connecting fails with SidecarErrorDeviceWiFiNotEnabled (-203) when the iPad is
  locked or asleep, even though it is still reachable. Wake and unlock it first.
"""

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())

guard argv.count == 1 else {
    if argv.isEmpty {
        FileHandle.standardError.write(Data("\(helpText)\n".utf8))
        exit(ExitCode.usage.rawValue)
    }
    fail("expected one command, got '\(argv.joined(separator: " "))'. Run 'sidecar --help'.", .usage)
}

let action: (SidecarCore, Device) throws -> Void
let verb: String
let done: String

switch argv[0] {
case "--help", "-h", "help":
    emit(helpText)
    exit(ExitCode.success.rawValue)
case "connect":
    action = { try $0.connect($1, timeout: timeout) }
    verb = "connecting to"
    done = "connected"
case "disconnect":
    action = { try $0.disconnect($1, timeout: timeout) }
    verb = "disconnecting from"
    done = "disconnected"
default:
    fail("unknown command '\(argv[0])'. Run 'sidecar --help'.", .usage)
}

let core: SidecarCore
let device: Device
do {
    core = try SidecarCore()
    guard let first = try core.devices().first else {
        fail("no Sidecar-capable devices are reachable", .noDevices)
    }
    device = first
} catch {
    report(error, action: "startup", device: nil)
}

do { try action(core, device) }
catch { report(error, action: verb, device: device) }

emit("\(done): \(device.name)")
