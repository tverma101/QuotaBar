import AppKit
import Foundation
import SwiftUI

/// Stable per-provider brand tints for the Total Spend ring and legend — the one place the app maps
/// a provider to a color, so the chart, legend, and share card always agree. Colors are keyed by
/// provider ID only (never by rank or position), so a provider keeps its color across period
/// switches, re-sorts, and launches.
enum TotalSpendPalette {
    private static let brandHexByProviderID: [String: UInt32] = [
        "claude": 0xDE7356,                             // Claude terracotta
        "codex": 0x10A37F,                              // OpenAI green (#10A37F)
        "openrouter": 0x6467F2,                         // OpenRouter indigo
        "antigravity": 0x4285F4,                        // Google blue
        "freebuff": 0xF59E0B,                           // Freebuff warm amber / gold (#F59E0B)
        "copilot": 0xA855F7,                            // Copilot purple
        "amp": 0xF34E3F,
        "kimi": 0x0A66FF,
        "minimax": 0xF5433C,
        "zai": 0x06B6D4                                 // Z.ai / ZCode electric cyan (#06B6D4)
    ]

    private static let dynamicBrands: [String: (light: UInt32, dark: UInt32)] = [
        "cursor": (light: 0x13120A, dark: 0xF5F5F7),  // brand black (#13120A), flipped near-white in dark mode
        "grok": (light: 0x8E8E93, dark: 0x98989D),    // brand black, offset to gray next to Cursor
        "opencode": (light: 0x6E6E73, dark: 0xAEAEB2),  // OpenCode — grayscale brand, medium gray
        "factory": (light: 0x48484A, dark: 0xC7C7CC)
    ]

    /// Distinct contrasting variants for multi-account families (e.g. Codex, Claude).
    private static let familyVariantHexes: [String: [UInt32]] = [
        "codex": [
            0x10A37F, // primary: OpenAI green
            0x34D399, // secondary: mint green (#34D399)
            0x0D9488, // tertiary: deep teal (#0D9488)
            0x22C55E  // 4th: emerald (#22C55E)
        ],
        "claude": [
            0xDE7356, // primary: terracotta (#DE7356)
            0xF43F5E, // secondary: rose (#F43F5E)
            0xFB923C, // tertiary: peach (#FB923C)
            0xE11D48  // 4th: crimson (#E11D48)
        ]
    ]

    /// High-contrast fallback palette to avoid collisions when multiple slices are visible.
    private static let fallbackHexes: [UInt32] = [
        0x34D399, 0xEC4899, 0xF97316, 0x14B8A6, 0x84CC16,
        0xA855F7, 0x06B6D4, 0x4285F4, 0xF59E0B, 0x10A37F,
        0xDE7356, 0x6467F2, 0x3B82F6, 0xE11D48, 0x10B981
    ]

    /// Dynamically resolves contrasting, collision-free colors for all slices in a projection.
    static func palette(for providerIDs: [String]) -> [String: Color] {
        var usedHexes = Set<UInt32>()
        var usedDynamicKeys = Set<String>()
        var result: [String: Color] = [:]

        // First pass: assign specific accounts and brand colors avoiding duplicate colors
        for providerID in providerIDs {
            let family = ProviderAccountID.family(of: providerID)
            let isSecondary = providerID != family

            if let dyn = dynamicBrands[providerID], !usedDynamicKeys.contains(providerID) {
                usedDynamicKeys.insert(providerID)
                result[providerID] = dynamic(light: dyn.light, dark: dyn.dark)
                continue
            }

            if isSecondary, let variants = familyVariantHexes[family] {
                // Secondary account of multi-account family: choose first unused variant
                var allocated = false
                for hexVal in variants.dropFirst() {
                    if !usedHexes.contains(hexVal) {
                        usedHexes.insert(hexVal)
                        result[providerID] = hex(hexVal)
                        allocated = true
                        break
                    }
                }
                if allocated { continue }
            } else if let brandHex = brandHexByProviderID[providerID], !usedHexes.contains(brandHex) {
                usedHexes.insert(brandHex)
                result[providerID] = hex(brandHex)
                continue
            } else if let brandHex = brandHexByProviderID[family], !usedHexes.contains(brandHex) {
                usedHexes.insert(brandHex)
                result[providerID] = hex(brandHex)
                continue
            }

            // Fallback for collisions or unknown providers: pick first unused fallback hex
            var allocated = false
            for fallbackHex in fallbackHexes {
                if !usedHexes.contains(fallbackHex) {
                    usedHexes.insert(fallbackHex)
                    result[providerID] = hex(fallbackHex)
                    allocated = true
                    break
                }
            }
            if !allocated {
                result[providerID] = color(for: providerID)
            }
        }
        return result
    }

    static func color(for providerID: String) -> Color {
        if let dyn = dynamicBrands[providerID] {
            return dynamic(light: dyn.light, dark: dyn.dark)
        }
        if let brandHex = brandHexByProviderID[providerID] {
            return hex(brandHex)
        }
        let family = ProviderAccountID.family(of: providerID)
        if providerID != family, let variants = familyVariantHexes[family], variants.count > 1 {
            let stableHash = providerID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return hex(variants[1 + (stableHash % (variants.count - 1))])
        }
        if let brandHex = brandHexByProviderID[family] {
            return hex(brandHex)
        }
        let stableHash = providerID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return hex(fallbackHexes[stableHash % fallbackHexes.count])
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// A light/dark-adaptive color, for brands whose mark is pure black — invisible on a dark card
    /// unless flipped.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
