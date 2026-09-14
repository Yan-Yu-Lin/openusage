import Foundation

enum OMPPaths {
    private static let defaultConfigDirectory = ".omp"
    private static let profileCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
    private static let profileInitialCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789")
    private static let windowsReservedProfileBases = Set(
        ["con", "prn", "aux", "nul"] + (0...9).flatMap { ["com\($0)", "lpt\($0)"] }
    )

    static func agentDirectory(environment: EnvironmentReading, homeDirectory: URL) -> URL {
        let configRoot = homeDirectory.appendingPathComponent(configDirectoryName(environment: environment))
        if let profile = activeProfile(environment: environment) {
            return configRoot
                .appendingPathComponent("profiles")
                .appendingPathComponent(profile)
                .appendingPathComponent("agent")
                .standardizedFileURL
        }
        if let override = trimmed(environment.value(for: "PI_CODING_AGENT_DIR")) {
            return resolvedOverride(override, homeDirectory: homeDirectory)
        }
        return configRoot.appendingPathComponent("agent").standardizedFileURL
    }

    static func sessionsDirectory(environment: EnvironmentReading, homeDirectory: URL) -> URL {
        agentDirectory(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("sessions")
            .standardizedFileURL
    }

    private static func activeProfile(environment: EnvironmentReading) -> String? {
        let raw = environment.rawValue(for: "OMP_PROFILE") ?? environment.rawValue(for: "PI_PROFILE")
        guard let normalized = trimmed(raw), normalized != "default" else { return nil }
        let characters = Array(normalized)
        let base = normalized.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0].lowercased()
        guard characters.count <= 64,
              characters.first.map({ profileInitialCharacters.contains($0) }) == true,
              characters.allSatisfy({ profileCharacters.contains($0) }),
              !normalized.hasSuffix("."),
              !windowsReservedProfileBases.contains(base)
        else {
            return nil
        }
        return normalized
    }

    private static func configDirectoryName(environment: EnvironmentReading) -> String {
        trimmed(environment.value(for: "PI_CONFIG_DIR")) ?? defaultConfigDirectory
    }

    private static func resolvedOverride(_ value: String, homeDirectory: URL) -> URL {
        if value == "~" {
            return homeDirectory.standardizedFileURL
        }
        if value.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(value.dropFirst(2))).standardizedFileURL
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: value, relativeTo: homeDirectory).standardizedFileURL
    }


    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
