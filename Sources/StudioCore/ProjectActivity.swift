import Foundation
import Observation

/// Which projects are being processed right now, by the queue or by the open episode. A
/// project runs one long operation at a time: two runs on the same episode would race on its
/// working files and its output.
@MainActor
@Observable
public final class ProjectActivity {
    public private(set) var busy: [String: String] = [:]

    public init() {}

    /// Claims the project; returns `false` (and changes nothing) when it is already busy.
    public func begin(_ projectID: String, _ description: String) -> Bool {
        guard busy[projectID] == nil else { return false }
        busy[projectID] = description
        return true
    }

    public func end(_ projectID: String) { busy[projectID] = nil }

    public func activity(for projectID: String) -> String? { busy[projectID] }
}
