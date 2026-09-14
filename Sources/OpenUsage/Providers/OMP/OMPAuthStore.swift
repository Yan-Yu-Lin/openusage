import Foundation

enum OMPOAuthProvider: String, Sendable {
    case anthropic
    case openAICodex = "openai-codex"
}

struct OMPOAuthCredential: Hashable, Sendable {
    var id: Int
    var accessToken: String
    var expiresAt: Double
    var accountID: String?
    var email: String?
    var databasePath: String
}

struct OMPAuthStore: Sendable {
    private struct Row: Decodable {
        var id: Int
        var access: String?
        var expires: Double?
        var accountId: String?
        var email: String?
    }

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var sqlite: SQLiteAccessing
    var homeDirectory: @Sendable () -> URL
    var now: @Sendable () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.sqlite = sqlite
        self.homeDirectory = homeDirectory
        self.now = now
    }

    func loadOAuthCredentials(provider: OMPOAuthProvider) -> [OMPOAuthCredential] {
        let path = databasePath()
        return loadOAuthCredentials(provider: provider, path: path, id: nil)
    }

    func loadOAuthCredential(
        provider: OMPOAuthProvider,
        path: String,
        id: Int
    ) -> OMPOAuthCredential? {
        loadOAuthCredentials(provider: provider, path: path, id: id).first
    }

    private func loadOAuthCredentials(
        provider: OMPOAuthProvider,
        path: String,
        id: Int?
    ) -> [OMPOAuthCredential] {
        guard files.exists(path) else { return [] }
        let idPredicate = id.map { " AND id = \($0)" } ?? ""
        let sql = """
        SELECT json_group_array(json_object(
            'id', id,
            'access', access,
            'expires', expires,
            'accountId', account_id,
            'email', email
        ))
        FROM (
            SELECT
                id,
                CASE WHEN json_type(data, '$.access') = 'text' THEN json_extract(data, '$.access') END AS access,
                CASE WHEN json_type(data, '$.expires') IN ('integer', 'real') THEN json_extract(data, '$.expires') END AS expires,
                CASE WHEN json_type(data, '$.accountId') = 'text' THEN json_extract(data, '$.accountId') END AS account_id,
                CASE WHEN json_type(data, '$.email') = 'text' THEN json_extract(data, '$.email') END AS email
            FROM auth_credentials
            WHERE provider = '\(provider.rawValue)'
              AND credential_type = 'oauth'
              AND disabled_cause IS NULL
              AND json_valid(data)\(idPredicate)
            ORDER BY id
        );
        """
        guard let value = try? sqlite.queryValue(path: path, sql: sql),
              let data = value.data(using: .utf8),
              let rows = try? JSONDecoder().decode([Row].self, from: data)
        else {
            return []
        }

        let nowMilliseconds = now().timeIntervalSince1970 * 1000
        return rows.compactMap { row in
            guard let token = row.access?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty,
                  let expiresAt = row.expires,
                  expiresAt.isFinite,
                  expiresAt > nowMilliseconds
            else {
                return nil
            }
            return OMPOAuthCredential(
                id: row.id,
                accessToken: token,
                expiresAt: expiresAt,
                accountID: normalized(row.accountId),
                email: normalized(row.email)?.lowercased(),
                databasePath: path
            )
        }
    }

    private func databasePath() -> String {
        OMPPaths.agentDirectory(environment: environment, homeDirectory: homeDirectory())
            .appendingPathComponent("agent.db")
            .path
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
