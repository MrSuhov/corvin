import SwiftUI

struct BorderedButtonCompat: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.buttonStyle(.bordered)
        } else {
            content
        }
    }
}

struct ProminentButtonCompat: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.buttonStyle(.borderedProminent)
        } else {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(6)
                .buttonStyle(.plain)
        }
    }
}

struct BlurBackgroundCompat: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.background(.ultraThinMaterial)
        } else {
            content.background(Color.black.opacity(0.6))
        }
    }
}
