import Foundation

/// Session roots consumed by the pi usage fold-in. `sessionsDirectory` preserves pi's native path
/// resolution; `sessionDirectories` adds OMP's compatible session ledger and canonicalizes exact
/// aliases so a shared override or symlink is scanned only once.
enum PiPaths {
    static func sessionsDirectory(environment: EnvironmentReading, homeDirectory: URL) -> URL {
        if let override = environment.value(for: "PI_CODING_AGENT_SESSION_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return URL(fileURLWithPath: expandHome(override))
        }
        if let configDir = environment.value(for: "PI_CODING_AGENT_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return URL(fileURLWithPath: expandHome(configDir)).appendingPathComponent("sessions")
        }
        return homeDirectory.appendingPathComponent(".pi/agent/sessions")
    }

    static func sessionDirectories(environment: EnvironmentReading, homeDirectory: URL) -> [URL] {
        let candidates = [
            sessionsDirectory(environment: environment, homeDirectory: homeDirectory),
            OMPPaths.sessionsDirectory(environment: environment, homeDirectory: homeDirectory),
        ]
        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            return seen.insert(resolved.path).inserted ? resolved : nil
        }
    }
}
