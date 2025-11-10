import Foundation
import Combine

struct LogEntry: Identifiable {
    let id = UUID()
    let ts = Date()
    let level: LogLevel
    let message: String
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var timestampString: String {
        LogEntry.dateFormatter.string(from: ts)
    }
}

final class LogStore: ObservableObject, @unchecked Sendable {
    static let cap: Int = 5000 // Maximum number of log entries kept in memory (ring buffer cap)
    @Published private(set) var entries: [LogEntry] = [] {
        didSet {
            let overflow = entries.count - LogStore.cap
            if overflow > 0 { entries.removeFirst(overflow) }
        }
    }
    @Published var minimumLevel: LogLevel = .info
    @Published var needsFullDiskAccess: Bool = false

    let errorSignal = PassthroughSubject<String, Never>()
    let warningSignal = PassthroughSubject<String, Never>()

    func clear() {
        entries.removeAll()
    }
    
    func log(_ level: LogLevel, _ msg: @autoclosure () -> String) {
        // Fast level check before doing any string work
        guard level.rawValue <= minimumLevel.rawValue else { return }

        let message = msg()

        DispatchQueue.main.async {
            self.entries.append(LogEntry(level: level, message: message))
            if level == .error {
                self.errorSignal.send(message)
            } else if level == .warn {
                self.warningSignal.send(message)
            }
        }

        #if DEBUG
        print("[\(level.display)] \(message)")
        #endif
    }

    // Convenience shorthands
    func error(_ msg: @autoclosure () -> String) { log(.error, msg()) }
    func warn(_ msg: @autoclosure () -> String)  { log(.warn,  msg()) }
    func info(_ msg: @autoclosure () -> String)  { log(.info,  msg()) }
    func debug(_ msg: @autoclosure () -> String) { log(.debug, msg()) }
}

