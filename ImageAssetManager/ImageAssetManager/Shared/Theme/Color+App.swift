import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    static let appBackground    = Color.adaptive(light: 0xF2F2F7, dark: 0x1C1C1E)
    static let appSurface       = Color.adaptive(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let appSurfaceRaised = Color.adaptive(light: 0xF2F2F7, dark: 0x3A3A3C)
    static let appBorder        = Color.adaptive(light: 0xC6C6C8, dark: 0x48484A)
    static let appTextPrimary   = Color.adaptive(light: 0x000000, dark: 0xFFFFFF)
    // Same value in both modes
    static let appTextSecondary = Color(red: 0.557, green: 0.557, blue: 0.576)
    static let appAccent        = Color.indigo
    static let imageMatte       = Color.adaptive(light: 0xE5E5EA, dark: 0x141414)

    #if os(macOS)
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(appHex: dark) : NSColor(appHex: light)
        })
    }
    #else
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(appHex: dark) : UIColor(appHex: light)
        })
    }
    #endif
}

#if os(macOS)
private extension NSColor {
    convenience init(appHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >> 8)  & 0xFF) / 255,
            blue:    CGFloat(hex & 0xFF) / 255,
            alpha:   1
        )
    }
}
#else
private extension UIColor {
    convenience init(appHex hex: UInt32) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8)  & 0xFF) / 255,
            blue:  CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
