import Foundation

/// Maps a pi-compatible session log's provider/model route to the OpenUsage card that owns it.
/// Native pi providers keep their existing direct mapping. OMP's known `cliproxy` route is model-
/// dispatched because it carries both Claude and GPT-family traffic; model inference is deliberately
/// not applied to generic OpenAI or unknown providers.
///
/// Only providers OpenUsage already has a card for are listed. Pi providers with no OpenUsage
/// equivalent are intentionally absent and left for future work:
/// - `nvidia-nim` — no OpenUsage card.
///
/// Mapped here but not yet consumed (only Claude and Codex read the pi slice today; the rest have no
/// local usage-trend card to fold into, or use a different spend path): `cursor` (Cursor's trend is
/// built from its CSV export), `zai`/`zhipu`, `google-antigravity`, `github-copilot`.
enum PiProviderMapping {
    /// pi `provider` value → OpenUsage `Provider.id`.
    static let providerToCard: [String: String] = [
        "anthropic": "claude",
        "claude-agent-sdk": "claude",
        "openai-codex": "codex",
        "cursor": "cursor",
        "zai": "zai",
        "zhipu": "zai",
        "google-antigravity": "antigravity",
        "github-copilot": "copilot"
    ]

    /// The OpenUsage card id for a pi-compatible route, or nil when the route is not narrowly known.
    static func cardID(forPiProvider provider: String, model: String? = nil) -> String? {
        if let native = providerToCard[provider] { return native }
        guard provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cliproxy",
              let model = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
        else { return nil }

        if model.hasPrefix("claude-") { return "claude" }
        if model.hasPrefix("gpt-") || model.hasPrefix("codex-") || model.hasPrefix("chatgpt-") {
            return "codex"
        }
        if model == "o1" || model.hasPrefix("o1-")
            || model == "o3" || model.hasPrefix("o3-")
            || model == "o4" || model.hasPrefix("o4-") {
            return "codex"
        }
        return nil
    }
}
