import AppKit
import SwiftUI

/// Unified design system for Sahba, aligned with macOS Sonoma / Sequoia glassmorphism.
enum Theme {
    // MARK: - AppKit Colors

    /// Vibrant Apple Cyan / Emerald gradient for active selections and hovered items.
    static let accentTop = NSColor(srgbRed: 0.18, green: 0.85, blue: 0.82, alpha: 1.0)
    static let accentBottom = NSColor(srgbRed: 0.05, green: 0.65, blue: 0.66, alpha: 1.0)
    static let accentGlow = NSColor(srgbRed: 0.15, green: 0.80, blue: 0.78, alpha: 0.40)

    /// High-contrast text on top of the accent fill.
    static let onAccent = NSColor(srgbRed: 0.01, green: 0.12, blue: 0.11, alpha: 1.0)

    /// Primary text (crisp white with slight warmth).
    static let labelPrimary = NSColor(srgbRed: 0.96, green: 0.97, blue: 1.0, alpha: 1.0)
    /// Secondary text (subtle translucent).
    static let labelSecondary = NSColor(srgbRed: 0.96, green: 0.97, blue: 1.0, alpha: 0.68)
    /// Tertiary / disabled text.
    static let labelTertiary = NSColor(srgbRed: 0.96, green: 0.97, blue: 1.0, alpha: 0.32)

    /// Translucent card fills.
    static let cardIdle = NSColor(white: 1.0, alpha: 0.08)
    static let cardHover = NSColor(white: 1.0, alpha: 0.16)
    static let cardDisabled = NSColor(white: 1.0, alpha: 0.03)

    /// Specular glass rim strokes.
    static let rimTop = NSColor(white: 1.0, alpha: 0.32)
    static let rimBottom = NSColor(white: 1.0, alpha: 0.08)
    static let cardBorder = NSColor(white: 1.0, alpha: 0.12)
    static let cardBorderHover = NSColor(white: 1.0, alpha: 0.28)

    /// Deep translucent obsidian glass backdrop.
    static let glassTintTop = NSColor(srgbRed: 0.08, green: 0.10, blue: 0.15, alpha: 0.72)
    static let glassTintBottom = NSColor(srgbRed: 0.04, green: 0.06, blue: 0.10, alpha: 0.78)

    // MARK: - SwiftUI Colors

    static let sahbaAccent = Color(red: 0.10, green: 0.74, blue: 0.72)
    static let sahbaAccentHover = Color(red: 0.18, green: 0.85, blue: 0.82)
    static let sahbaBackgroundDark = Color(red: 0.06, green: 0.08, blue: 0.12)

    // MARK: - Gradients

    static var accentGradient: NSGradient? = {
        NSGradient(starting: accentTop, ending: accentBottom)
    }()

    static var glassTintGradient: NSGradient? = {
        NSGradient(starting: glassTintTop, ending: glassTintBottom)
    }()

    static var rimGradient: NSGradient? = {
        NSGradient(starting: rimTop, ending: rimBottom)
    }()
}
