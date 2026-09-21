import Foundation
import NorthpaneProtocol

/// Why an attempt to read one agent's subscription produced no Reading. It maps one to one on
/// the `AgentUsageState` a client sees, minus the two states that are not failures.
public enum AgentUsageFailure: Error, Equatable, Sendable {
    /// The CLI holds no session.
    case signedOut
    /// The session is an API key or a cloud provider: there is no plan to meter.
    case noPlan
    /// The CLI answered in a form this reader does not know. It stops instead of guessing.
    case unreadable
    /// Anything that may pass: a timeout, the network, a process that died.
    case unreachable

    public var state: AgentUsageState {
        switch self { case .signedOut: .signedOut; case .noPlan: .noPlan; case .unreadable: .unreadable; case .unreachable: .unreachable }
    }
}

/// Reads the text `claude -p "/usage"` prints for a person:
///
///     Current session: 14% used · resets Aug 20 at 4:39pm (UTC)
///     Current week (all models): 96% used · resets Aug 21 at 5:59pm (UTC)
///     Current week (Fable): 88% used · resets Aug 21 at 5:59pm (UTC)
///
/// The text has no contract, so the reader is strict where being lenient would lie. It knows a
/// closed list of lines and ignores the rest — the same text carries `72% of your usage came
/// from…`, which is a percentage and not a meter — and a Reading is whole or absent: a meter
/// line it cannot finish, or a required one that is missing, fails the Reading rather than
/// leaving a plan that looks complete with a meter short. The rest of the text describes what
/// the Host user has been doing and never leaves this function.
public enum ClaudeUsageProse {
    /// The zone the invocation imposes with `TZ`, and so the one the text must name. Another
    /// zone means the invocation is no longer what this reader believes: it is not converted.
    public static let imposedZone = "UTC"
    static let subscriptionScope = "subscription"
    private static let required = ["Current session", "Current week (all models)"]
    private static let resetSeparator = " · resets "
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `now` only restores the year, which the text does not carry.
    public static func meters(in prose: String, now: Date) throws -> [AgentUsageMeter] {
        var meters: [AgentUsageMeter] = []
        var seen = Set<String>()
        for rawLine in prose.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.range(of: ": ") else { continue }
            let what = String(line[..<colon.lowerBound])
            guard let descriptor = descriptor(what) else { continue }
            let (usedPercent, resetsAt) = try quantity(String(line[colon.upperBound...]), now: now)
            // Two lines for one meter would overwrite each other; choosing one would be a guess.
            guard !meters.contains(where: { $0.scopeID == descriptor.scopeID && $0.kind == descriptor.kind }) else { throw AgentUsageFailure.unreadable }
            seen.insert(what)
            // The text does not say how long a window lasts, so the duration stays unknown
            // rather than being filled in from the documentation.
            meters.append(.init(scopeID: descriptor.scopeID, scopeLabel: descriptor.label, kind: descriptor.kind, usedPercent: usedPercent,
                                resetsAt: resetsAt, inForce: descriptor.scopeID == subscriptionScope))
        }
        guard required.allSatisfy(seen.contains) else { throw AgentUsageFailure.unreadable }
        return meters
    }

    private static func descriptor(_ what: String) -> (scopeID: String, label: String, kind: AgentUsageMeterKind)? {
        switch what {
        case "Current session": return (subscriptionScope, "All models", .shortWindow)
        case "Current week (all models)": return (subscriptionScope, "All models", .longWindow)
        default:
            // `Current week (Fable)`: one scope per model. It is the one place a meter may
            // appear without this reader being updated, because a new model is the CLI doing
            // its job, while an unknown line is the CLI having changed.
            guard what.hasPrefix("Current week ("), what.hasSuffix(")") else { return nil }
            let model = String(what.dropFirst("Current week (".count).dropLast())
            guard !model.isEmpty else { return nil }
            return ("model:" + model.lowercased().replacingOccurrences(of: " ", with: "-"), model, .longWindow)
        }
    }

    private static func quantity(_ tail: String, now: Date) throws -> (Int, Date?) {
        // At `0% used` the line ends there: a window nothing was spent on has no reset armed.
        let used: String, when: String?
        if let separator = tail.range(of: resetSeparator) {
            used = String(tail[..<separator.lowerBound]); when = String(tail[separator.upperBound...])
        } else { used = tail; when = nil }
        guard used.hasSuffix("% used"), let percent = Int(used.dropLast("% used".count)), (0...100).contains(percent) else { throw AgentUsageFailure.unreadable }
        return (percent, try when.map { try resetInstant($0, now: now) })
    }

    /// `Aug 20 at 4:39pm (UTC)`, also `Sep 25 at 4pm (UTC)` and `Aug 24, 1:50pm (UTC)`.
    private static func resetInstant(_ when: String, now: Date) throws -> Date {
        guard let open = when.range(of: " (", options: .backwards), when.hasSuffix(")") else { throw AgentUsageFailure.unreadable }
        guard when[open.upperBound...].dropLast() == imposedZone else { throw AgentUsageFailure.unreadable }
        var words = when[..<open.lowerBound].split(separator: " ").map(String.init)
        // The time is the last word and must carry `am` or `pm`: a bare `1:50` is one or
        // thirteen, and being twelve hours wrong in silence is worse than not reading.
        guard words.count >= 3, let seconds = secondsOfDay(words.removeLast()),
              let month = months.firstIndex(of: words[0]).map({ $0 + 1 }),
              let day = Int(words[1].filter(\.isNumber)), (1...31).contains(day),
              // What is left is the joint — `at`, nothing, a dash. With a digit in it, it is
              // something this reader has not read.
              !words.dropFirst(2).contains(where: { $0.contains(where: \.isNumber) })
        else { throw AgentUsageFailure.unreadable }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: now)
        let candidates = [year - 1, year, year + 1].compactMap { candidate -> Date? in
            let components = DateComponents(year: candidate, month: month, day: day)
            // `date(from:)` rolls 30 February into March; a day that does not exist is not read.
            guard let start = calendar.date(from: components), calendar.component(.day, from: start) == day else { return nil }
            return start.addingTimeInterval(TimeInterval(seconds))
        }
        guard let nearest = candidates.min(by: { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }) else { throw AgentUsageFailure.unreadable }
        return nearest
    }

    private static func secondsOfDay(_ time: String) -> Int? {
        let half: Int
        if time.hasSuffix("am") { half = 0 } else if time.hasSuffix("pm") { half = 12 } else { return nil }
        let clock = time.dropLast(2).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(clock.count), let hour = Int(clock[0]), (1...12).contains(hour) else { return nil }
        let minute: Int
        if clock.count == 2 { guard let parsed = Int(clock[1]), (0...59).contains(parsed) else { return nil }; minute = parsed } else { minute = 0 }
        // `12am` is hour zero and `12pm` the twelfth: the two a twelve-hour clock gets wrong.
        return ((hour == 12 ? 0 : hour) + half) * 3_600 + minute * 60
    }
}

/// Reads what `codex app-server` answers to `account/rateLimits/read`, which is documented JSON.
public enum CodexRateLimits {
    /// Scopes whose id says nothing to a reader, and what the product calls them. It decides a
    /// label and nothing else: an unknown scope is rendered exactly like a known one.
    private static let knownScopeLabels = ["codex": "Codex and Work"]

    public static func meters(in result: Any) throws -> [AgentUsageMeter] {
        guard let root = result as? [String: Any], let scopes = root["rateLimitsByLimitId"] as? [String: Any] else { throw AgentUsageFailure.unreadable }
        // Beside the map of every scope the CLI names the one it is consuming against now.
        let inForce = (root["rateLimits"] as? [String: Any])?["limitId"] as? String
        var meters: [AgentUsageMeter] = []
        for scopeID in scopes.keys.sorted() {
            guard let scope = scopes[scopeID] as? [String: Any] else { continue }
            let named = (scope["limitName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let label = named ?? knownScopeLabels[scopeID] ?? scopeID
            for (field, position) in [("primary", AgentUsageMeterKind.shortWindow), ("secondary", .longWindow)] {
                guard let window = scope[field] as? [String: Any], let used = percent(window["usedPercent"]) else { continue }
                let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
                // A plan with only a weekly limit sends it in `primary`, so the duration the
                // window declares decides what it is; the position is the fallback.
                let kind: AgentUsageMeterKind = switch minutes { case 300: .shortWindow; case 10_080: .longWindow; default: position }
                meters.append(.init(scopeID: scopeID, scopeLabel: label, kind: kind, usedPercent: used,
                                    resetsAt: instant(window["resetsAt"]), windowMinutes: minutes, inForce: scopeID == inForce))
            }
            // The allowance arrives as what is left, so it is read from the other side.
            if let credits = scope["individualLimit"] as? [String: Any], let remaining = percent(credits["remainingPercent"]) {
                meters.append(.init(scopeID: scopeID, scopeLabel: label, kind: .credits, usedPercent: 100 - remaining,
                                    used: scalarText(credits["used"]), limit: scalarText(credits["limit"]),
                                    resetsAt: instant(credits["resetsAt"]), inForce: scopeID == inForce))
            }
        }
        return meters
    }

    /// What `account/read` says of the session, as the failure it imposes on a Reading, if any.
    public static func sessionFailure(in result: Any) -> AgentUsageFailure? {
        guard let account = (result as? [String: Any])?["account"] as? [String: Any] else { return .signedOut }
        // An API key and every other kind of session meter nothing a plan would.
        return account["type"] as? String == "chatgpt" ? nil : .noPlan
    }

    private static func percent(_ value: Any?) -> Int? {
        // JSON's true and false arrive as numbers too, and on macOS a 0 or a 1 also answers
        // `is Bool`: asked that way, an untouched window vanished. The stored type decides.
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return nil }
        return min(100, max(0, Int(number.doubleValue.rounded())))
    }
    private static func instant(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, number.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }
    /// An amount as the CLI wrote it: it is fractional, and picking a number type here would be
    /// picking it for whoever wrote it.
    private static func scalarText(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        return (value as? NSNumber)?.stringValue
    }
}
