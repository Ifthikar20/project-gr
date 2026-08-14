import CoreModels
import SwiftUI
import UIKit

// The Daybreak Pulse button kit (docs/03): one shared press feel — a spring
// give under the finger plus the app's first tap haptic — and one component
// per recurring recipe, so screens stop hand-rolling the same capsules at
// three different heights.

/// Shared press physics for every custom button: scale to 0.96 on press
/// (response 0.3 / damping 0.65 — the app's existing motion vocabulary)
/// with a light impact tick the moment the press begins.
public struct PressableStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.65),
                       value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}

// MARK: - CTA label chrome (usable outside Button, e.g. ShareLink)

/// The two CTA skins as label-only modifiers, so non-Button hosts
/// (ShareLink, NavigationLink) can wear the exact same chrome.
public extension View {
    /// Hero CTA: the website's primary button, verbatim — ink capsule,
    /// snow label, a small volt dot leading in, bevel highlight, soft pop.
    func pulseCTALabel(fullWidth: Bool = true) -> some View {
        modifier(CTALabelChrome(skin: .pulse, fullWidth: fullWidth))
    }

    /// Quiet sibling: the website's ghost button — snow-card capsule, ink
    /// label, hairline stroke, whisper of shadow.
    func ghostCTALabel(fullWidth: Bool = true) -> some View {
        modifier(CTALabelChrome(skin: .ghost, fullWidth: fullWidth))
    }
}

struct CTALabelChrome: ViewModifier {
    enum Skin { case pulse, ghost }
    let skin: Skin
    let fullWidth: Bool

    func body(content: Content) -> some View {
        HStack(spacing: 8) {
            if skin == .pulse {
                // The site's signature leading dot, gone monochrome: a
                // 7 px snow dot before the label on the ink capsule.
                Circle()
                    .fill(DS.Colors.snowCard)
                    .frame(width: 7, height: 7)
            }
            content
        }
        .font(DS.Typography.heading)
        .foregroundStyle(skin == .pulse ? DS.Colors.snowCard : DS.Colors.ink)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .padding(.horizontal, 24)
        .frame(height: 52)
        .background(skin == .pulse ? DS.Colors.ink : DS.Colors.snowCard,
                    in: Capsule())
        // Bevel: a faint top-light on ink, the hairline on ghost.
        .overlay(Capsule().stroke(
            skin == .pulse ? Color.white.opacity(0.14) : DS.Colors.hairline,
            lineWidth: 1))
        .shadow(color: DS.Colors.ink.opacity(skin == .pulse ? 0.22 : 0.06),
                radius: skin == .pulse ? 12 : 8, y: skin == .pulse ? 5 : 3)
    }
}

// MARK: - PulseButton

/// The hero CTA — one height (52), one skin, optional leading symbol, and a
/// built-in in-flight spinner. Replaces the drifting hand-rolled pulse
/// capsules (46/50/52) across the app.
public struct PulseButton: View {
    let title: String
    let icon: String?
    let isLoading: Bool
    let fullWidth: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, icon: String? = nil, isLoading: Bool = false,
                fullWidth: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.fullWidth = fullWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(DS.Colors.snowCard)
                        .scaleEffect(0.85)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.headline.bold())
                }
                Text(title)
            }
            .pulseCTALabel(fullWidth: fullWidth)
            .opacity(isEnabled && !isLoading ? 1 : 0.5)
        }
        .buttonStyle(PressableStyle())
        .disabled(isLoading)
    }
}

// MARK: - GhostButton

/// The secondary CTA: same geometry as PulseButton, quiet skin.
public struct GhostButton: View {
    let title: String
    let icon: String?
    let fullWidth: Bool
    let action: () -> Void

    public init(_ title: String, icon: String? = nil, fullWidth: Bool = true,
                action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.fullWidth = fullWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.headline.bold())
                }
                Text(title)
            }
            .ghostCTALabel(fullWidth: fullWidth)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - IconOrbButton

/// Floating circular map action (Explore's FABs, the in-run pause control):
/// snow orb with hairline ring, flipping to a pulse fill when active.
public struct IconOrbButton: View {
    let systemImage: String
    let size: CGFloat
    let isActive: Bool
    let action: () -> Void

    public init(systemImage: String, size: CGFloat = 48, isActive: Bool = false,
                action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.size = size
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(size >= 56 ? .title2.bold() : .title3.bold())
                .foregroundStyle(isActive ? DS.Colors.snowCard : DS.Colors.ink)
                .frame(width: size, height: size)
                // Black buttons everywhere — active is an ink orb with a
                // snow glyph, and a light stroke so it stays visible when
                // floating over the dark map tiles.
                .background(isActive ? DS.Colors.ink : DS.Colors.snowCard,
                            in: Circle())
                .overlay(Circle().stroke(
                    isActive ? Color.white.opacity(0.35) : DS.Colors.hairline,
                    lineWidth: 1))
                .shadow(color: DS.Colors.ink.opacity(isActive ? 0.2 : 0.15),
                        radius: size >= 56 ? 8 : 6, y: size >= 56 ? 3 : 2)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - HoldToConfirmButton

/// Deliberate friction with visible progress (docs/03's hold-to-stop, now
/// with the feedback it never had): press and hold — a snow fill sweeps
/// across the capsule for the duration, a light tick marks the press, a
/// success haptic marks the commit, and letting go early springs the fill
/// back to zero. Tap does nothing, by design.
public struct HoldToConfirmButton: View {
    let title: String
    let systemImage: String?
    let duration: Double
    let onConfirm: () -> Void

    @State private var progress: CGFloat = 0
    @State private var isHolding = false

    public init(_ title: String, systemImage: String? = nil,
                duration: Double = 1.0, onConfirm: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.duration = duration
        self.onConfirm = onConfirm
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.headline.bold())
            }
            Text(title)
        }
        .font(DS.Typography.heading)
        .foregroundStyle(DS.Colors.snowCard)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(DS.Colors.pulse, in: Capsule())
        .overlay(alignment: .leading) {
            GeometryReader { geo in
                Capsule()
                    .fill(DS.Colors.snowCard.opacity(0.35))
                    .frame(width: geo.size.width * progress)
            }
            .allowsHitTesting(false)
        }
        .clipShape(Capsule())
        .scaleEffect(isHolding ? 0.97 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isHolding)
        .onLongPressGesture(minimumDuration: duration) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onConfirm()
        } onPressingChanged: { pressing in
            isHolding = pressing
            if pressing {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.linear(duration: duration)) { progress = 1 }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    progress = 0
                }
            }
        }
    }
}

// MARK: - RarityButton

/// Gem CTA tinted from the rarity ramp with the tier glyph leading — the
/// same double encoding (step + glyph) the rest of the system uses, so the
/// button reads correctly in grayscale too. Light tiers keep ink text;
/// rare and up flip to snow.
public struct RarityButton: View {
    let title: String
    let rarity: Rarity
    let isLoading: Bool
    let action: () -> Void

    public init(_ title: String, rarity: Rarity, isLoading: Bool = false,
                action: @escaping () -> Void) {
        self.title = title
        self.rarity = rarity
        self.isLoading = isLoading
        self.action = action
    }

    private var label: Color {
        DS.Colors.rarityStep(rarity) >= 0.7 ? DS.Colors.snowCard : DS.Colors.ink
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(label)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: DS.rarityGlyph(rarity))
                        .font(.footnote.bold())
                }
                Text(title)
                    .font(.footnote.bold())
            }
            .foregroundStyle(label)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(DS.Colors.rarity(rarity), in: Capsule())
            .overlay(Capsule().stroke(DS.Colors.hairline, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .disabled(isLoading)
    }
}
