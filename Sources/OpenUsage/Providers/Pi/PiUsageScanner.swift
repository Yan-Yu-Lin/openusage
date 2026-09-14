import Foundation

/// Builds a per-day token/cost series from compatible pi and OMP session logs for one OpenUsage card,
/// so usage that happened inside either agent folds into that card's Usage Trend and spend tiles
/// alongside its native source.
///
/// The logs record an authoritative per-message `usage.cost.total` (like OpenCode), so that carried
/// cost is used when present; when a log records `$0` (subscription usage it doesn't impute), tokens
/// are priced through the shared engine. Unknown models retain their measured tokens with nil cost and
/// surface the existing unknown-model warning; no price is invented.
///
/// Pi and OMP share the same message/usage JSONL shape, so one parser and incremental cache scans the
/// union of both roots. Canonical root and file paths prevent shared overrides, symlinks, and nested
/// roots from counting one file twice.
///
/// An actor holds the versioned incremental parse cache (keyed path + size + mtime) in memory and
/// Application Support, so refreshes and relaunches parse only changed session files. A single shared
/// instance is used by every consuming provider, so compatible logs are parsed once rather than once
/// per card.
actor PiUsageScanner {
    /// How a card prices a pi request that carries no cost of its own. Providers with their own
    /// request rules (Codex's long-context and priority tiers) supply their estimator; the rest use
    /// the shared pricing engine.
    typealias CostEstimator = @Sendable (String, TokenBreakdown) -> Double?

    static let shared = PiUsageScanner()

    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("pi"),
        persistence: JSONLScanCachePersistence(namespace: "pi", schemaVersion: 2)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    /// One parsed assistant-message usage line. Raw timestamp is kept so a cached parse stays valid as
    /// the window slides; `cardID` is resolved at parse time so aggregation is a cheap filter.
    struct Entry: Codable, Sendable, Equatable {
        var id: String?
        var timestamp: Date
        var cardID: String
        var model: String
        /// Raw route metadata keeps replay identity narrower than the destination card alone.
        var provider: String
        var api: String
        /// pi's own `usage.cost.total`, used directly when > 0; nil/0 falls through to engine pricing.
        var carriedCost: Double?
        /// The token buckets, for pricing the fall-through case.
        var tokens: TokenBreakdown
        /// pi's reported `usage.totalTokens`, shown as the row's token count (matches pi's own footer).
        var reportedTotalTokens: Int
    }

    /// Scan the last `daysBack` days of pi and OMP logs for one card. Returns nil when neither session
    /// root has log files, so a provider with no compatible usage folds in nothing.
    func scan(
        cardID: String, daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing,
        estimateCost: CostEstimator? = nil
    ) async -> LogUsageScan? {
        let directories = PiPaths.sessionDirectories(environment: environment, homeDirectory: homeDirectory())
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cacheIdentity = "roots=\n" + directories.map(\.path).sorted().joined(separator: "\n")
        let files = Self.sessionFiles(under: directories)
        guard !files.isEmpty else {
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parse: Self.parseFile
            )
            return nil
        }

        guard let entries = await scanner.items(
            from: files,
            since: since,
            cacheIdentity: cacheIdentity,
            parse: Self.parseFile
        ), !Task.isCancelled else { return nil }
        return Self.aggregate(
            entries: Self.dedup(entries), cardID: cardID, since: since, pricing: pricing,
            estimateCost: estimateCost
        )
    }

    private static func sessionFiles(under directories: [URL]) -> [JSONLScanning.DiscoveredFile] {
        var filesByCanonicalPath: [String: JSONLScanning.DiscoveredFile] = [:]
        for directory in directories {
            for var file in JSONLScanning.jsonlFiles(under: directory) {
                let canonicalPath = URL(fileURLWithPath: file.path)
                    .resolvingSymlinksInPath().standardizedFileURL.path
                guard filesByCanonicalPath[canonicalPath] == nil else { continue }
                file.path = canonicalPath
                filesByCanonicalPath[canonicalPath] = file
            }
        }
        return filesByCanonicalPath.values.sorted { $0.path < $1.path }
    }

    // MARK: - Parsing

    /// Parse every mapped assistant usage line of one session file. Lines for pi providers OpenUsage
    /// doesn't track are dropped here so they never reach aggregation.
    static func parseFile(_ data: Data) -> [Entry] {
        let marker = Data(#""usage":{"#.utf8)
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: marker) != nil, let entry = parseLine(Data(line)) else { continue }
            entries.append(entry)
        }
        return entries
    }

    static func parseLine(_ data: Data) -> Entry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "message",
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let providerID = message["provider"] as? String,
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let model = (message["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let cardID = PiProviderMapping.cardID(forPiProvider: providerID, model: model) else { return nil }

        let cacheWrite = Int(ProviderParse.number(usage["cacheWrite"]) ?? 0)
        let cacheWrite1h = Int(ProviderParse.number(usage["cacheWrite1h"]) ?? 0)
        let tokens = TokenBreakdown(
            input: Int(ProviderParse.number(usage["input"]) ?? 0),
            cacheWrite5m: max(cacheWrite - cacheWrite1h, 0),
            cacheWrite1h: cacheWrite1h,
            cacheRead: Int(ProviderParse.number(usage["cacheRead"]) ?? 0),
            output: Int(ProviderParse.number(usage["output"]) ?? 0)
        )

        let carriedCost = (usage["cost"] as? [String: Any]).flatMap { ProviderParse.number($0["total"]) }
        return Entry(
            id: object["id"] as? String,
            timestamp: timestamp,
            cardID: cardID,
            model: model,
            provider: providerID,
            api: (message["api"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            carriedCost: carriedCost,
            tokens: tokens,
            reportedTotalTokens: Int(ProviderParse.number(usage["totalTokens"]) ?? 0)
        )
    }

    // MARK: - Dedup and aggregation

    /// Drop exact replayed assistant entries from cloned/forked session ledgers. The message id is only
    /// one part of the identity because short ids can legitimately recur in unrelated sessions.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        var seen: Set<ReplayKey> = []
        var out: [Entry] = []
        out.reserveCapacity(entries.count)
        for entry in entries {
            guard let id = entry.id else {
                out.append(entry)
                continue
            }
            if seen.insert(ReplayKey(entry, id: id)).inserted { out.append(entry) }
        }
        return out
    }

    private struct ReplayKey: Hashable {
        var id: String
        var timestamp: Date
        var cardID: String
        var model: String
        var provider: String
        var api: String
        var carriedCost: Double?
        var input: Int
        var cacheWrite5m: Int
        var cacheWrite1h: Int
        var cacheRead: Int
        var output: Int
        var reportedTotalTokens: Int

        init(_ entry: Entry, id: String) {
            self.id = id
            self.timestamp = entry.timestamp
            self.cardID = entry.cardID
            self.model = entry.model
            self.provider = entry.provider
            self.api = entry.api
            self.carriedCost = entry.carriedCost
            self.input = entry.tokens.input
            self.cacheWrite5m = entry.tokens.cacheWrite5m
            self.cacheWrite1h = entry.tokens.cacheWrite1h
            self.cacheRead = entry.tokens.cacheRead
            self.output = entry.tokens.output
            self.reportedTotalTokens = entry.reportedTotalTokens
        }
    }

    /// Bucket the card's entries into local calendar days. Carried cost wins, otherwise the shared
    /// pricing engine estimates it. Unknown models retain measured token totals with nil cost and are
    /// surfaced through the accumulator's unknown-model warning.
    static func aggregate(
        entries: [Entry], cardID: String, since: Date, pricing: ModelPricing,
        estimateCost: CostEstimator? = nil
    ) -> LogUsageScan {
        let estimate = estimateCost ?? { pricing.estimatedCostDollars(model: $0, tokens: $1) }
        var accumulator = DailyUsageAccumulator()
        for entry in entries where entry.cardID == cardID && entry.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            let trimmedModel = entry.model.nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName

            let cost: Double
            if let carried = entry.carriedCost, carried > 0 {
                cost = carried
            } else if let model = trimmedModel, let estimated = estimate(model, entry.tokens) {
                cost = estimated
            } else {
                if let model = trimmedModel, entry.reportedTotalTokens > 0 {
                    accumulator.addUnpriced(day: day, tokens: entry.reportedTotalTokens, model: model)
                }
                continue
            }
            accumulator.add(day: day, tokens: entry.reportedTotalTokens, cost: cost, model: modelName)
        }
        return accumulator.build()
    }
}
