import Darwin
import Foundation

public struct CommandOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public init(status: Int32 = 0, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
    public var text: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public protocol CommandExecuting: Sendable {
    func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandOutput
}

public struct ProcessExecutor: CommandExecuting {
    public init() {}

    public func execute(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 300
    ) throws -> CommandOutput {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-sweeper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = directory.appendingPathComponent("stdout")
        let err = directory.appendingPathComponent("stderr")
        try Data().write(to: out)
        try Data().write(to: err)
        let outHandle = try FileHandle(forWritingTo: out)
        let errHandle = try FileHandle(forWritingTo: err)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw SweeperError("Command timed out after \(Int(timeout))s: \(executable) \(arguments.joined(separator: " "))")
        }
        process.waitUntilExit()
        return CommandOutput(
            status: process.terminationStatus, stdout: try readOutput(out), stderr: try readOutput(err)
        )
    }

    private func readOutput(_ url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4_194_304 else {
            throw SweeperError("Command output exceeded the 4 MiB limit; cleanup was stopped.")
        }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}

public struct CleanupService: Sendable {
    public let executor: any CommandExecuting
    public init(executor: any CommandExecuting = ProcessExecutor()) { self.executor = executor }

    public func check(_ path: String, profiles: [CleanupProfile]) throws -> String {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw SweeperError("Apple container executable not found or not executable: \(path)")
        }
        let version = try checked(path, ["--version"], timeout: 15)
        var probes: [[String]] = []
        if profiles.contains(where: \.clean) {
            probes += [["list", "--help"], ["clean", "--help"]]
        }
        if profiles.contains(where: \.prune) { probes.append(["prune", "--help"]) }
        if profiles.contains(where: { $0.images != .none }) { probes.append(["image", "prune", "--help"]) }
        for arguments in probes {
            let output = try executor.execute(path, arguments, timeout: 15)
            guard output.status == 0 else {
                throw SweeperError(
                    "\(version.text)\nUnsupported command: container \(arguments.dropLast().joined(separator: " "))\n"
                    + "Update Apple Container or deselect this action.\n\(output.text)"
                )
            }
            if arguments == ["image", "prune", "--help"],
               profiles.contains(where: { $0.images == .all }), !output.text.contains("--all") {
                throw SweeperError("This Apple Container version does not support image prune --all.")
            }
        }
        return version.text
    }

    public func perform(
        _ profile: CleanupProfile, path: String, log: (String) throws -> Void
    ) throws {
        try profile.validate()
        try log(check(path, profiles: [profile]))
        // Fail before modifying anything if the user's container service is stopped.
        try log(checked(path, ["system", "status"], timeout: 15).text)
        if profile.clean {
            let listing = try checked(path, ["list", "--quiet"], timeout: 30)
            if !listing.stderr.isEmpty { try log(listing.stderr) }
            let ids = listing.stdout.split(whereSeparator: \.isWhitespace).map(String.init)
            guard ids.allSatisfy({ !$0.hasPrefix("-") && !$0.contains("\0") }) else {
                throw SweeperError("Unexpected container ID in container list output.")
            }
            if ids.isEmpty { try log("No running containers to clean.") }
            for id in ids { try run(path, ["clean", id], log: log) }
        }
        if profile.prune { try run(path, ["prune"], log: log) }
        switch profile.images {
        case .none: break
        case .dangling: try run(path, ["image", "prune"], log: log)
        case .all: try run(path, ["image", "prune", "--all"], log: log)
        }
    }

    private func run(_ path: String, _ arguments: [String], log: (String) throws -> Void) throws {
        try log("$ container \(arguments.joined(separator: " "))")
        let output = try checked(path, arguments, timeout: 600)
        if !output.text.isEmpty { try log(output.text) }
    }

    private func checked(_ path: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        let output = try executor.execute(path, arguments, timeout: timeout)
        guard output.status == 0 else {
            throw SweeperError(
                "container \(arguments.joined(separator: " ")) exited with \(output.status).\n\(output.text)"
            )
        }
        return output
    }
}
