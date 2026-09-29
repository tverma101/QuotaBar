import Foundation

/// Decides whether two slugs naming the same priced model are the *same model* or two distinct ones.
///
/// The Codex router and FCC proxy stamp the upstream path onto their slugs, so one model arrives as both
/// `gpt-5.6-luna` and `anthropic/openai/gpt-5.6-luna`. That is the gateway's routing information, not
/// part of the model's name, and treating the two as separate rows split one model in two and counted it
/// twice in the same period total.
///
/// The narrowness matters. A `/` is the signal, and nothing else is. Codex's `gpt-reserve` and
/// `codex-auto-review` are single-segment slugs that are *priced* using a different model — a separate,
/// intentional identity that must keep its own row and its own name, and those tests pin that. Falling
/// back to "merge anything that resolves to the same catalog key" conflates *priced like* with *is*, and
/// breaks both.
enum GatewaySlug {
    /// Whether a slug carries a gateway routing path (`vendor/openai/model`) rather than being a model
    /// identity outright. Slugs that are already bare model names report false and are left alone.
    static func hasRoutingPath(_ slug: String) -> Bool {
        slug.contains("/")
    }

    /// The identity a slug should be grouped and displayed under.
    ///
    /// - Parameters:
    ///   - slug: exactly what the provider emitted.
    ///   - resolvedPricingModel: the catalog key that slug's suffix resolved to, when pricing could
    ///     resolve it. Ignored for bare slugs.
    /// - Returns: the routed-to model id for a slug carrying a routing path, otherwise `slug` unchanged.
    static func identity(of slug: String, resolvedPricingModel: String?) -> String {
        guard hasRoutingPath(slug) else { return slug }
        return resolvedPricingModel ?? slug
    }
}
