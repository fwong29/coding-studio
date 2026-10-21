import SwiftUI

/// The single large instruction above the shutter.
///
/// One instruction at a time, by design. A list of everything wrong with the
/// frame is accurate and useless; the next single thing to do is actionable.
struct DirectiveBanner: View {

    let directive: Directive?
    let isReady: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let directive {
                HStack(spacing: 10) {
                    if directive.nudge != .none {
                        Image(systemName: directive.nudge.symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(directive.text)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)

                if let reason = directive.reason {
                    Text(reason)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if isReady {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                    Text("That's the shot")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.green)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            // A gradient scrim rather than a solid card: it keeps the text
            // readable over a bright frame without boxing off the preview.
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)],
                           startPoint: .top,
                           endPoint: .bottom)
        )
        .animation(.easeInOut(duration: 0.2), value: directive)
        .animation(.easeInOut(duration: 0.2), value: isReady)
    }
}

/// Transient message, e.g. "Saved to Photos".
struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.75), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
    }
}
