import AppKit
import Darwin
import Foundation
import SwiftUI
// Translation's SDK classes predate Sendable; this host uses every session sequentially.
@preconcurrency import Translation

enum EvaluationError: LocalizedError {
    case invalidArguments(String)
    case invalidFixture(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message), .invalidFixture(let message): message
        }
    }
}

struct Options {
    var prepare = false
    var status = false
    var append = false
    var fixture: String?
    var split = "dev"
    var strategy = "lowLatency"
    var output: String?

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--prepare": prepare = true
            case "--status": status = true
            case "--append": append = true
            case "--fixture", "--split", "--strategy", "--output":
                index += 1
                guard index < arguments.count else {
                    throw EvaluationError.invalidArguments("Missing value for \(flag)")
                }
                let value = arguments[index]
                switch flag {
                case "--fixture": fixture = value
                case "--split": split = value
                case "--strategy": strategy = value
                default: output = value
                }
            default: throw EvaluationError.invalidArguments("Unknown argument: \(flag)")
            }
            index += 1
        }
        guard ["dev", "heldout", "control"].contains(split),
              ["lowLatency", "highFidelity"].contains(strategy), !(prepare && status) else {
            throw EvaluationError.invalidArguments("Use one mode, a valid split, and lowLatency or highFidelity")
        }
        guard prepare || status || fixture != nil else {
            throw EvaluationError.invalidArguments("Supply --fixture PATH, --status, or --prepare")
        }
    }

    var translationStrategy: TranslationSession.Strategy {
        strategy == "lowLatency" ? .lowLatency : .highFidelity
    }
}

@MainActor
final class JSONLines {
    private let handle: FileHandle

    init(path: String?, append: Bool) throws {
        guard let path else {
            handle = .standardOutput
            return
        }
        let url = URL(fileURLWithPath: path)
        if !append || !FileManager.default.fileExists(atPath: path) {
            try Data().write(to: url)
        }
        handle = try FileHandle(forWritingTo: url)
        if append { try handle.seekToEnd() }
    }

    func write(_ row: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .fragmentsAllowed])
        bytes.append(0x0A)
        try handle.write(contentsOf: bytes)
    }
}

struct Sample: Decodable {
    let id: String
    let split: String
    let source: String
    let direction: String

    var toEnglish: Bool {
        direction == "ja_to_en" || (direction == "auto" && source.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x31F0...0x31FF).contains($0.value) ||
            (0xFF66...0xFF9F).contains($0.value) || (0x3400...0x4DBF).contains($0.value) ||
            (0x4E00...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) ||
            (0x20000...0x323AF).contains($0.value) || (0x3005...0x3007).contains($0.value)
        })
    }
}

struct MemorySample {
    let rss: UInt64?
    let footprint: UInt64?

    init() {
        var basic = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: basic) / MemoryLayout<integer_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        rss = basicResult == KERN_SUCCESS ? basic.resident_size : nil
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        footprint = vmResult == KERN_SUCCESS ? vm.phys_footprint : nil
    }
}

@MainActor
@discardableResult
func recordAvailability(_ writer: JSONLines, phase: String) async throws -> [String: String] {
    var statuses: [String: String] = [:]
    for (name, strategy): (String, TranslationSession.Strategy) in [
        ("lowLatency", .lowLatency), ("highFidelity", .highFidelity)
    ] {
        let availability = LanguageAvailability(preferredStrategy: strategy)
        let status = await availability.status(from: .init(identifier: "en"), to: .init(identifier: "ja"))
        let statusName = switch status {
        case .installed: "installed"
        case .supported: "supported"
        case .unsupported: "unsupported"
        @unknown default: "unknown"
        }
        statuses[name] = statusName
        try writer.write([
            "record_type": "availability", "phase": phase, "strategy_requested": name,
            "status": statusName, "source_language": "en", "target_language": "ja",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "pid": ProcessInfo.processInfo.processIdentifier
        ])
    }
    return statuses
}

@MainActor
func evaluate(_ options: Options, writer: JSONLines) async throws {
    guard let fixture = options.fixture else { return }
    let allSamples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: fixture)))
    let samples = allSamples.filter { $0.split == options.split }
    guard !samples.isEmpty else { throw EvaluationError.invalidFixture("No cases in split \(options.split)") }
    var sessions: [Bool: TranslationSession] = [:]
    for sample in samples {
        guard ["en_to_ja", "ja_to_en", "auto"].contains(sample.direction) else {
            throw EvaluationError.invalidFixture("Unknown direction in \(sample.id)")
        }
        let before = MemorySample()
        let start = ContinuousClock.now
        var row: [String: Any] = [
            "record_type": "translation", "id": sample.id, "split": sample.split,
            "variant": "apple_\(options.strategy)", "strategy_requested": options.strategy,
            "direction": sample.direction, "output": "", "complete": false,
            "truncated": false, "first_text_ms": NSNull(),
            "before_rss_bytes": before.rss as Any? ?? NSNull(),
            "before_physical_footprint_bytes": before.footprint as Any? ?? NSNull(),
            "pid": ProcessInfo.processInfo.processIdentifier
        ]
        do {
            let source = Locale.Language(identifier: sample.toEnglish ? "ja" : "en")
            let target = Locale.Language(identifier: sample.toEnglish ? "en" : "ja")
            if sessions[sample.toEnglish] == nil {
                let availability = LanguageAvailability(preferredStrategy: options.translationStrategy)
                guard await availability.status(from: source, to: target) == .installed else {
                    throw TranslationError.notInstalled
                }
                sessions[sample.toEnglish] = TranslationSession(
                    installedSource: source, target: target, preferredStrategy: options.translationStrategy)
            }
            guard let session = sessions[sample.toEnglish] else {
                throw EvaluationError.invalidFixture("No translation session")
            }
            let response = try await session.translate(sample.source)
            row["output"] = response.targetText
            row["complete"] = true
            row["source_language"] = response.sourceLanguage.minimalIdentifier
            row["target_language"] = response.targetLanguage.minimalIdentifier
        } catch {
            row["error"] = String(describing: error)
            row["error_description"] = error.localizedDescription
        }
        let elapsed = start.duration(to: .now).components
        row["completion_ms"] = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let after = MemorySample()
        row["after_rss_bytes"] = after.rss as Any? ?? NSNull()
        row["after_physical_footprint_bytes"] = after.footprint as Any? ?? NSNull()
        try writer.write(row)
    }
}

struct PreparationView: View {
    let writer: JSONLines
    @State private var message = "Waiting for the system language download prompt…"
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Apple Translation Evaluation").font(.title2)
            Text("Prepare English → Japanese language data for evaluation.")
            Text(message).textSelection(.enabled)
            if !finished { ProgressView() }
            Button("Close evaluation host") { NSApplication.shared.terminate(nil) }
        }
        .padding(28)
        .frame(width: 490, height: 230)
        .translationTask(source: .init(identifier: "en"), target: .init(identifier: "ja"),
                         preferredStrategy: .lowLatency) { session in
            do {
                try await recordAvailability(writer, phase: "prepare_before")
                try await session.prepareTranslation()
                let statuses = try await recordAvailability(writer, phase: "prepare_after")
                message = statuses["lowLatency"] == "installed"
                    ? "Ready. English and Japanese language data are installed."
                    : "Download approved. macOS is still preparing language data. Use --status to verify installed before evaluation."
                finished = true
            } catch {
                message = "Preparation failed: \(error.localizedDescription)"
                finished = true
                try? writer.write(["record_type": "preparation_error", "error": String(describing: error)])
            }
        }
    }
}

@main
struct AppleTranslationEval {
    @MainActor
    static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            let writer = try JSONLines(path: options.output, append: options.append)
            if options.prepare {
                let application = NSApplication.shared
                application.setActivationPolicy(.regular)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 290),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Apple Translation Evaluation"
                window.contentView = NSHostingView(rootView: PreparationView(writer: writer))
                window.center()
                window.makeKeyAndOrderFront(nil)
                application.activate(ignoringOtherApps: true)
                application.run()
            } else {
                Task { @MainActor in
                    do {
                        if options.status { try await recordAvailability(writer, phase: "status") }
                        else { try await evaluate(options, writer: writer) }
                        exit(EXIT_SUCCESS)
                    } catch {
                        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                        exit(EXIT_FAILURE)
                    }
                }
                dispatchMain()
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
