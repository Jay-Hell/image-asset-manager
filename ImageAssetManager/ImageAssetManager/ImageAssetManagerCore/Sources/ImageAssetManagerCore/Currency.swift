import Foundation

/// Cost conversion for provider prices published in USD.
///
/// Google's image-generation APIs quote prices in USD; the rest of the app
/// (generation panel, spend dashboard, DB rows) standardises on GBP. This is
/// the single place that owns the USD→GBP rate — bump `usdToGBP` when the FX
/// rate drifts materially.
public enum Currency {

    /// USD → GBP rate applied to provider prices.
    /// Last reviewed: 2026-04-18.
    public static let usdToGBP: Decimal = 0.79

    /// Convert a USD amount to GBP using the current rate.
    public static func gbp(fromUSD usd: Decimal) -> Decimal {
        usd * usdToGBP
    }
}
