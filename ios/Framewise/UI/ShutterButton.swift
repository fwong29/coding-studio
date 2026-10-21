import SwiftUI

/// Shutter with a readiness ring.
///
/// The ring fills as the composition improves, which turns an abstract score
/// into something you can watch out of the corner of your eye while you move.
struct ShutterButton: View {

    let readiness: CGFloat
    let isReady: Bool
    let isCapturing: Bool
    let autoShutterOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.22), lineWidth: 3)
                    .frame(width: 74, height: 74)

                Circle()
                    .trim(from: 0, to: max(0.001, min(1, readiness)))
                    .stroke(isReady ? Color.green : Color.white.opacity(0.85),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 74, height: 74)
                    // Start the ring at twelve o'clock.
                    .rotationEffect(.degrees(-90))

                Circle()
                    .fill(.white)
                    .frame(width: 58, height: 58)
                    .scaleEffect(isCapturing ? 0.86 : 1)

                if autoShutterOn {
                    // Marks that the shutter will fire by itself, so a photo
                    // appearing unprompted isn't a surprise.
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isReady ? Color.green : Color.black.opacity(0.35))
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.25), value: readiness)
        .animation(.easeOut(duration: 0.15), value: isCapturing)
        .animation(.easeInOut(duration: 0.2), value: isReady)
    }
}
