import XCTest
@testable import OpenUsage

final class OMPPathsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

    func testResolvesDefaultOverrideAndProfilePaths() {
        XCTAssertEqual(
            OMPPaths.agentDirectory(environment: FakeEnvironment(), homeDirectory: home).path,
            "/Users/test/.omp/agent"
        )
        XCTAssertEqual(
            OMPPaths.agentDirectory(
                environment: FakeEnvironment(["PI_CODING_AGENT_DIR": "~/custom-agent"]),
                homeDirectory: home
            ).path,
            "/Users/test/custom-agent"
        )
        XCTAssertEqual(
            OMPPaths.agentDirectory(
                environment: FakeEnvironment([
                    "PI_CONFIG_DIR": ".config/omp",
                    "OMP_PROFILE": "work.1",
                    "PI_CODING_AGENT_DIR": "/ignored-for-profile"
                ]),
                homeDirectory: home
            ).path,
            "/Users/test/.config/omp/profiles/work.1/agent"
        )
    }

    func testOMPProfilePrecedenceAndUnsafeProfilesFallBackWithoutJoiningThem() {
        XCTAssertEqual(
            OMPPaths.agentDirectory(
                environment: FakeEnvironment([
                    "OMP_PROFILE": "",
                    "PI_PROFILE": "legacy",
                    "PI_CODING_AGENT_DIR": "/default-override"
                ]),
                homeDirectory: home
            ).path,
            "/default-override"
        )
        XCTAssertEqual(
            OMPPaths.agentDirectory(
                environment: FakeEnvironment([
                    "OMP_PROFILE": "../escape",
                    "PI_CODING_AGENT_DIR": "/safe-override"
                ]),
                homeDirectory: home
            ).path,
            "/safe-override"
        )
    }
}

final class OMPAuthStoreTests: XCTestCase {
    func testLoadsOnlyActiveUnexpiredOAuthRowsInStorageOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let agent = root.appendingPathComponent(".omp/agent", isDirectory: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = agent.appendingPathComponent("agent.db").path
        let sqlite = SQLiteCLIAccessor()
        try sqlite.execute(path: database, sql: """
        CREATE TABLE auth_credentials (
            id INTEGER PRIMARY KEY,
            provider TEXT NOT NULL,
            credential_type TEXT NOT NULL,
            data TEXT NOT NULL,
            disabled_cause TEXT
        );
        INSERT INTO auth_credentials VALUES
            (20, 'anthropic', 'oauth', '{"access":"second","expires":2000000,"accountId":" ACCOUNT-2 ","email":"SECOND@EXAMPLE.COM"}', NULL),
            (10, 'anthropic', 'oauth', '{"access":" first ","expires":2000000}', NULL),
            (30, 'anthropic', 'oauth', '{"access":"expired","expires":999999}', NULL),
            (40, 'anthropic', 'oauth', '{"access":"disabled","expires":2000000}', 'manual'),
            (50, 'anthropic', 'oauth', '{"access":"   ","expires":2000000}', NULL),
            (60, 'anthropic', 'oauth', 'not-json', NULL),
            (70, 'anthropic', 'api_key', '{"key":"not-oauth"}', NULL),
            (80, 'openai-codex', 'oauth', '{"access":"other-provider","expires":2000000}', NULL);
        """)
        let home = root
        let store = OMPAuthStore(
            environment: FakeEnvironment(),
            files: LocalTextFileAccessor(),
            sqlite: sqlite,
            homeDirectory: { home },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let credentials = store.loadOAuthCredentials(provider: .anthropic)

        XCTAssertEqual(credentials.map(\.id), [10, 20])
        XCTAssertEqual(credentials.map(\.accessToken), ["first", "second"])
        XCTAssertEqual(credentials[1].accountID, "ACCOUNT-2")
        XCTAssertEqual(credentials[1].email, "second@example.com")
        XCTAssertEqual(credentials[0].databasePath, database)
    }

    func testMissingDatabaseDoesNotQueryOrCreateIt() {
        let sqlite = OMPRecordingSQLite(payload: "[]")
        let store = OMPAuthStore(
            environment: FakeEnvironment(),
            files: OMPRecordingFiles(),
            sqlite: sqlite,
            homeDirectory: { URL(fileURLWithPath: "/missing-home") }
        )

        XCTAssertTrue(store.loadOAuthCredentials(provider: .anthropic).isEmpty)
        XCTAssertTrue(sqlite.queries.isEmpty)
        XCTAssertEqual(sqlite.executeCount, 0)
    }

    func testNativeClaudeSourcesPrecedeOMPAndOMPCredentialIsReadonly() throws {
        let database = "/Users/test/.omp/agent/agent.db"
        let files = OMPRecordingFiles([
            database: "present",
            "/native/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token"}}"#
        ])
        let sqlite = OMPRecordingSQLite(payload: ompRows([
            (7, "omp-token", 2_000_000, "omp-account", "omp@example.com")
        ]))
        let now = Date(timeIntervalSince1970: 1_000)
        let omp = OMPAuthStore(
            environment: FakeEnvironment(), files: files, sqlite: sqlite,
            homeDirectory: { URL(fileURLWithPath: "/Users/test") }, now: { now }
        )
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/native"]),
            files: files,
            keychain: FakeKeychain(#"{"claudeAiOauth":{"accessToken":"keychain-token"}}"#),
            omp: omp,
            now: { now }
        )

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "file-token", "omp-token"])
        guard case .omp(let path, let id) = candidates[2].source else {
            return XCTFail("expected OMP source")
        }
        XCTAssertEqual(path, database)
        XCTAssertEqual(id, 7)
        XCTAssertFalse(try store.save(candidates[2], ifUnchanged: ClaudeCredentialGeneration(candidates)))
        XCTAssertTrue(files.writes.isEmpty)
        XCTAssertEqual(sqlite.executeCount, 0)
    }

    @MainActor
    func testCodexOMPOnlyDetectionReloadAndExpiryNeverRefreshesOrWrites() async throws {
        let database = "/Users/test/.omp/agent/agent.db"
        let files = OMPRecordingFiles([database: "present"])
        let sqlite = OMPRecordingSQLite(payload: ompRows([
            (9, "old-token", 2_000_000, "account-9", "codex@example.com")
        ]))
        let now = Date(timeIntervalSince1970: 1_000)
        let omp = OMPAuthStore(
            environment: FakeEnvironment(), files: files, sqlite: sqlite,
            homeDirectory: { URL(fileURLWithPath: "/Users/test") }, now: { now }
        )
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(), omp: omp, now: { now }
        )
        let provider = CodexProvider(authStore: store)

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let original = try XCTUnwrap(store.loadOMPAuthCandidates().first)
        guard case .omp(let path, let id) = original.source else {
            return XCTFail("expected OMP source")
        }
        sqlite.payload = ompRows([(9, "reloaded-token", 2_000_000, "account-9", "codex@example.com")])
        let reloaded = try XCTUnwrap(store.loadOMPAuth(path: path, id: id))
        XCTAssertEqual(reloaded.auth.tokens?.accessToken, "reloaded-token")
        try store.save(reloaded)
        XCTAssertTrue(files.writes.isEmpty)
        XCTAssertEqual(sqlite.executeCount, 0)

        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
        let expiredProvider = CodexProvider(authStore: store, usageClient: CodexUsageClient(http: http))
        let snapshot = await expiredProvider.refresh()

        XCTAssertEqual(http.requests.count, 1, "OMP access must not be sent to the native refresh endpoint")
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(errorBadge(snapshot.lines), CodexAuthError.ompTokenExpired.localizedDescription)
        XCTAssertTrue(files.writes.isEmpty)
        XCTAssertEqual(sqlite.executeCount, 0)
    }

    @MainActor
    func testCodexNativeFilePrecedesKeychainAndOMP() async {
        let database = "/Users/test/.omp/agent/agent.db"
        let files = OMPRecordingFiles([
            database: "present",
            "/native/auth.json": #"{"tokens":{"access_token":"native-token"}}"#
        ])
        let sqlite = OMPRecordingSQLite(payload: ompRows([
            (10, "omp-token", 2_000_000, "omp-account", "omp@example.com")
        ]))
        let now = Date(timeIntervalSince1970: 1_000)
        let omp = OMPAuthStore(
            environment: FakeEnvironment(), files: files, sqlite: sqlite,
            homeDirectory: { URL(fileURLWithPath: "/Users/test") }, now: { now }
        )
        let store = CodexAuthStore(
            environment: FakeEnvironment(["CODEX_HOME": "/native"]),
            files: files,
            keychain: FakeKeychain(#"{"tokens":{"access_token":"keychain-token"}}"#),
            omp: omp,
            now: { now }
        )
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))
        let provider = CodexProvider(authStore: store, usageClient: CodexUsageClient(http: http))

        _ = await provider.refresh()

        XCTAssertEqual(Set(http.requests.compactMap { $0.headers["Authorization"] }), ["Bearer native-token"])
    }

    @MainActor
    func testScopedClaudeRejectsAnUnrelatedOMPAccountBeforeUsage() async {
        let database = "/Users/test/.omp/agent/agent.db"
        let files = OMPRecordingFiles([database: "present"])
        let sqlite = OMPRecordingSQLite(payload: ompRows([
            (10, "omp-claude-token", 2_000_000, "other-account", "other@example.com")
        ]))
        let now = Date(timeIntervalSince1970: 1_000)
        let omp = OMPAuthStore(
            environment: FakeEnvironment(), files: files, sqlite: sqlite,
            homeDirectory: { URL(fileURLWithPath: "/Users/test") }, now: { now }
        )
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(), omp: omp,
            expectedIdentityKey: "expected-account|expected-org", now: { now }
        )
        let http = RoutingHTTPClient { request in
            XCTAssertTrue(request.url.path.hasSuffix("/api/oauth/profile"))
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"account":{"uuid":"other-account"},"organization":{"uuid":"other-org"}}"#.utf8)
            )
        }
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: http),
            allowsUnattributedPiUsage: false,
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(errorBadge(snapshot.lines), ClaudeAuthError.sessionExpired.localizedDescription)
    }

    func testObserversUseOMPCredentialIdentityOnlyWhenNativeSourcesAreEmpty() {
        let database = "/Users/test/.omp/agent/agent.db"
        let files = OMPRecordingFiles([database: "present"])
        let sqlite = OMPRecordingSQLite(payload: ompRows([
            (11, "token", 2_000_000, "CODEX-ACCOUNT", "person@example.com")
        ]))
        let now = Date(timeIntervalSince1970: 1_000)
        let omp = OMPAuthStore(
            environment: FakeEnvironment(), files: files, sqlite: sqlite,
            homeDirectory: { URL(fileURLWithPath: "/Users/test") }, now: { now }
        )
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(), files: files, keychain: AbsentOMPKeychain(), omp: omp,
            homeDirectory: { URL(fileURLWithPath: "/Users/test") }
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(
                identityKey: "codex-account",
                label: "person@example.com",
                anchor: "\(database)#credential:11"
            )
        )

        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "omp-email:person@example.com", label: "person@example.com",
                      anchor: "\(database)#credential:11")
        )
        var ambiguousClaude = observer
        ambiguousClaude.keychain = FakeKeychain(#"{"claudeAiOauth":{"accessToken":"native-token"}}"#)
        guard case .unresolved = ambiguousClaude.observeClaude() else {
            return XCTFail("A higher-priority native Keychain login must not inherit OMP's account stamp")
        }

        files.files["/Users/test/.codex/auth.json"] = #"{"tokens":{"access_token":"native-without-identity"}}"#
        XCTAssertEqual(
            observer.observeCodex(),
            .unresolved(reason: "credentials present but no account identity")
        )
    }

    private func ompRows(_ rows: [(Int, String, Double, String?, String?)]) -> String {
        let values: [[String: Any]] = rows.map { row in
            let (id, access, expires, accountID, email) = row
            var value: [String: Any] = ["id": id, "access": access, "expires": expires]
            if let accountID { value["accountId"] = accountID }
            if let email { value["email"] = email }
            return value
        }
        let data = try! JSONSerialization.data(withJSONObject: values)
        return String(decoding: data, as: UTF8.self)
    }

    private func errorBadge(_ lines: [MetricLine]) -> String? {
        guard case .badge(_, let text, _, _) = lines.first(where: { $0.label == MetricLine.errorBadgeLabel }) else {
            return nil
        }
        return text
    }
}

private final class OMPRecordingSQLite: SQLiteAccessing, @unchecked Sendable {
    var payload: String?
    var queries: [(path: String, sql: String)] = []
    var executeCount = 0

    init(payload: String?) {
        self.payload = payload
    }

    func queryValue(path: String, sql: String) throws -> String? {
        queries.append((path, sql))
        return payload
    }

    func execute(path: String, sql: String) throws {
        executeCount += 1
    }
}

private final class OMPRecordingFiles: TextFileAccessing, @unchecked Sendable {
    var files: [String: String]
    var writes: [(path: String, text: String)] = []

    init(_ files: [String: String] = [:]) {
        self.files = files
    }

    func exists(_ path: String) -> Bool { files[path] != nil }
    func readText(_ path: String) throws -> String { files[path] ?? "" }

    func writeText(_ path: String, _ text: String) throws {
        writes.append((path, text))
        files[path] = text
    }

    func remove(_ path: String) throws {
        files.removeValue(forKey: path)
    }
}

private struct AbsentOMPKeychain: KeychainAccessing {
    func readGenericPassword(service: String) throws -> String? { nil }
    func writeGenericPassword(service: String, value: String) throws {}
    func genericPasswordExists(service: String) -> Bool? { false }
}
