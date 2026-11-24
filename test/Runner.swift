// Offline test runner and process/assertion helpers for the Brother DCP-T420W driver.

import Darwin
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ initial: Value) { storage = initial }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}

func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws -> Never {
    throw TestFailure("\(file):\(line): \(message)")
}

func expectTrue(
    _ condition: Bool, _ message: @autoclosure () -> String = "Expected true",
    file: StaticString = #filePath, line: UInt = #line
) throws {
    if !condition { throw TestFailure("\(file):\(line): \(message())") }
}

func expectFalse(
    _ condition: Bool, _ message: @autoclosure () -> String = "Expected false",
    file: StaticString = #filePath, line: UInt = #line
) throws {
    if condition { throw TestFailure("\(file):\(line): \(message())") }
}

func expectEqual<T: Equatable>(
    _ lhs: T, _ rhs: T, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) throws {
    if lhs != rhs {
        let extra = message()
        let suffix = extra.isEmpty ? "" : " (\(extra))"
        throw TestFailure("\(file):\(line): Expected \(lhs) == \(rhs)\(suffix)")
    }
}

func expectNotEqual<T: Equatable>(
    _ lhs: T, _ rhs: T, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) throws {
    if lhs == rhs {
        let extra = message()
        let suffix = extra.isEmpty ? "" : " (\(extra))"
        throw TestFailure("\(file):\(line): Expected \(lhs) != \(rhs)\(suffix)")
    }
}

func expectAlmostEqual(
    _ lhs: Double, _ rhs: Double, delta: Double,
    file: StaticString = #filePath, line: UInt = #line
) throws {
    if abs(lhs - rhs) > delta {
        throw TestFailure("\(file):\(line): Expected \(lhs) ~= \(rhs) (delta \(delta))")
    }
}

func expectThrows<E: Error>(
    _ errorType: E.Type, _ context: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ body: () throws -> Void
) throws {
    do {
        try body()
    } catch is E {
        return
    } catch {
        throw TestFailure("\(file):\(line): Unexpected error \(error) (\(context()))")
    }
    let extra = context()
    let suffix = extra.isEmpty ? "" : " (\(extra))"
    throw TestFailure("\(file):\(line): Expected \(E.self) to be thrown\(suffix)")
}

struct ProcessResult {
    let returncode: Int32
    let stdout: Data
    let stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

func runProcess(
    _ executable: String,
    _ args: [String] = [],
    stdin: Data? = nil,
    stdoutFile: URL? = nil,
    stdoutHandle: FileHandle? = nil,
    env: [String: String]? = nil,
    timeout: TimeInterval = 30
) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    if let env { process.environment = env }

    let outBox = LockedBox(Data())
    let errBox = LockedBox(Data())
    let ioGroup = DispatchGroup()

    var stdoutPipe: Pipe?
    var fileOutputHandle: FileHandle?
    if let stdoutHandle {
        process.standardOutput = stdoutHandle
    } else if let stdoutFile {
        FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
        let fh = try FileHandle(forWritingTo: stdoutFile)
        fileOutputHandle = fh
        process.standardOutput = fh
    } else {
        let pipe = Pipe()
        stdoutPipe = pipe
        process.standardOutput = pipe
    }

    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    var stdinPipe: Pipe?
    if stdin != nil {
        let pipe = Pipe()
        stdinPipe = pipe
        process.standardInput = pipe
    }

    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }

    try process.run()

    if let pipe = stdoutPipe {
        ioGroup.enter()
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            outBox.withLock { $0 = data }
            ioGroup.leave()
        }
    }

    ioGroup.enter()
    DispatchQueue.global().async {
        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        errBox.withLock { $0 = data }
        ioGroup.leave()
    }

    if let inputData = stdin, let pipe = stdinPipe {
        ioGroup.enter()
        DispatchQueue.global().async {
            if !inputData.isEmpty {
                try? pipe.fileHandleForWriting.write(contentsOf: inputData)
            }
            try? pipe.fileHandleForWriting.close()
            ioGroup.leave()
        }
    }

    if done.wait(timeout: .now() + timeout) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = done.wait(timeout: .now() + 5)
        try? fileOutputHandle?.close()
        ioGroup.wait()
        throw TestFailure("Process timed out after \(Int(timeout))s: \(executable)")
    }

    try? fileOutputHandle?.close()
    ioGroup.wait()

    let code: Int32
    if process.terminationReason == .uncaughtSignal {
        code = -process.terminationStatus
    } else {
        code = process.terminationStatus
    }
    return ProcessResult(
        returncode: code,
        stdout: outBox.withLock { $0 },
        stderr: errBox.withLock { $0 })
}

func withTempDir(suffix: String = "", _ body: (URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("brother-\(UUID().uuidString)\(suffix)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

enum TestConfig {
    static var root: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["BROTHER_ROOT"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static var filter: String {
        ProcessInfo.processInfo.environment["BROTHER_FILTER"]
            ?? root.appendingPathComponent("filter/rastertobrother").path
    }

    static var scanner: String {
        ProcessInfo.processInfo.environment["BROTHER_SCANNER"]
            ?? root.appendingPathComponent("scanner/brscan").path
    }

    static var genppd: String {
        ProcessInfo.processInfo.environment["BROTHER_GENPPD"]
            ?? root.appendingPathComponent("build/genppd").path
    }

    static var ppd: String {
        root.appendingPathComponent("ppd/Brother-DCP-T420W.ppd").path
    }
}

struct TestCase {
    let name: String
    let body: () throws -> Void
}

@main
enum TestRunner {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let suite = pwgToolTests() + rasterTests() + scannerTests() + printPipelineTests()
        let started = Date()
        var failures: [(String, String)] = []

        for test in suite {
            do {
                try test.body()
                print("\(test.name) ... ok")
            } catch {
                print("\(test.name) ... FAIL")
                failures.append((test.name, "\(error)"))
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        if !failures.isEmpty {
            print("")
            for (name, reason) in failures {
                print("======================================================================")
                print("FAIL: \(name)")
                print(reason)
            }
        }
        print("----------------------------------------------------------------------")
        print(String(format: "Ran %d tests in %.3fs", suite.count, elapsed))
        print("")
        if failures.isEmpty {
            print("OK")
        } else {
            print("FAILED (failures=\(failures.count))")
            exit(1)
        }
    }
}
