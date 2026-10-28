import Foundation
import Observation

/// Which projects are being processed right now. A project runs one long operation at a time
/// (two runs on the same video would race on its working files and its output), and Ajustes ›
/// Armazenamento does not clear the files of a project in use.
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
