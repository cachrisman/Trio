import Foundation

/// Thin forwarder onto `WatchLogger.shared.log` that preserves `#fileID`,
/// `#line`, and `#function` from the syntactic caller. Using this helper
/// keeps BetterStack call-site attribution pointing at `G7DirectBLEObserver`
/// (or wherever the call happens) rather than at this forwarder.
enum G7BLELog {
    /// Formats an event line as `event=<name> <key=value …>` and forwards
    /// it to `WatchLogger`. `fields` are joined in the order provided —
    /// callers control field ordering for grep-friendliness on BetterStack.
    static func emit(
        _ event: String,
        fields: [(String, CustomStringConvertible)] = [],
        force: Bool = false,
        function: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) {
        var msg = "event=\(event)"
        for (k, v) in fields {
            let sanitized = sanitize(String(describing: v))
            msg += " \(k)=\(sanitized)"
        }
        let forwardMsg = msg
        Task {
            await WatchLogger.shared.log(
                forwardMsg,
                force: force,
                function: function,
                file: file,
                line: line
            )
        }
    }

    /// Convenience when a free-form message is enough.
    static func log(
        _ message: String,
        force: Bool = false,
        function: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) {
        Task {
            await WatchLogger.shared.log(
                message,
                force: force,
                function: function,
                file: file,
                line: line
            )
        }
    }

    /// Replace whitespace and `=`/newline in field values so the
    /// `k=v k=v …` format stays parseable. Values that happen to contain
    /// spaces (error localized descriptions, for example) get underscored.
    private static func sanitize(_ raw: String) -> String {
        var out = raw
        out = out.replacingOccurrences(of: "\n", with: "_")
        out = out.replacingOccurrences(of: "\r", with: "_")
        if out.contains(" ") || out.contains("=") {
            out = out.replacingOccurrences(of: " ", with: "_")
            out = out.replacingOccurrences(of: "=", with: "-")
        }
        return out
    }
}
