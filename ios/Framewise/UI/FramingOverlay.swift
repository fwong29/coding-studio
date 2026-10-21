import SwiftUI

/// Everything drawn on top of the live preview: thirds grid, horizon line,
/// subject box, and the aim marker.
///
/// The aim marker is the core interaction. A ring sits where the subject
/// *should* be and a dot rides the subject itself; bringing them together is
/// the whole job, and it works without reading a word of text.
struct FramingOverlay: View {

    let state: CoachingState
    let videoAspect: CGFloat
    let showGrid: Bool
    let showHorizon: Bool

    var body: some View {
        GeometryReader { proxy in
            let mapper = PreviewMapper(viewSize: proxy.size, contentAspect: videoAspect)

            ZStack {
                if showGrid {
                    thirdsGrid(in: proxy.size)
                }
                if showHorizon {
                    horizonIndicator(mapper: mapper, size: proxy.size)
                }
                // One thing to look at, not two. There used to be an aim
                // marker here as well — a ring on a thirds intersection and a
                // dot on the subject, to be brought together. It could not
                // work: moving the phone moves the subject, which moves the
                // dot, and the ring then re-picked whichever third was now
                // nearest, so the target fled from the thing chasing it.
                if !state.crop.isFullFrame {
                    cropBox(mapper.rect(state.crop.rect), in: proxy.size)
                }
            }
            // Slow and soft: the box is the most prominent thing on screen, so
            // any twitch in it reads as the app being unsure of itself.
            .animation(.easeInOut(duration: 0.45), value: state.crop.rect)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Grid

    private func thirdsGrid(in size: CGSize) -> some View {
        Canvas { canvasContext, canvasSize in
            var path = Path()
            for fraction in Thirds.lines {
                let x = canvasSize.width * fraction
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))

                let y = canvasSize.height * fraction
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y))
            }
            canvasContext.stroke(path,
                                 with: .color(.white.opacity(0.18)),
                                 lineWidth: 0.5)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Horizon and level

    /// Draws the true horizon as computed from device attitude, plus a short
    /// level bar at the centre that turns green when the frame is square.
    private func horizonIndicator(mapper: PreviewMapper, size: CGSize) -> some View {
        let isLevel = state.levelErrorDegrees < 1.2
        let tilt = state.rollDegrees - (state.rollDegrees / 90).rounded() * 90

        return ZStack {
            // Projected horizon line, drawn only when it falls on screen.
            if let horizonY = state.horizonY, horizonY > 0.02, horizonY < 0.98 {
                let y = mapper.point(CGPoint(x: 0.5, y: horizonY)).y
                Rectangle()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: size.width * 1.6, height: 1)
                    // Rotating the phone clockwise makes the world appear to
                    // rotate counter-clockwise inside the frame, and SwiftUI's
                    // positive rotation is clockwise — so the drawn horizon
                    // takes the negated tilt.
                    .rotationEffect(.degrees(Double(-tilt)))
                    .position(x: size.width / 2, y: y)
            }

            // Level bar: a fixed reference and a bar that rotates with the
            // phone, so the mismatch between them is the error.
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 54, height: 2)
                // The live bar tracks true horizontal, so it rotates against
                // the phone; the gap between it and the fixed reference above
                // is the error.
                Capsule()
                    .fill(isLevel ? Color.green : Color.yellow)
                    .frame(width: 54, height: 2)
                    .rotationEffect(.degrees(Double(-tilt)))
                    .opacity(isLevel ? 1 : 0.9)
            }
            .position(x: size.width / 2, y: size.height / 2)
            .opacity(isLevel && state.levelErrorDegrees < 0.4 ? 0.35 : 1)
        }
    }

    // MARK: - Suggested crop

    /// The photo inside the photo: everything outside the box is dimmed, so
    /// the rectangle reads as the frame you'd actually keep rather than as
    /// one more piece of overlay furniture.
    private func cropBox(_ rect: CGRect, in size: CGSize) -> some View {
        ZStack {
            // Dim the surround by filling the whole view and punching the
            // crop out of it with the even-odd rule.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 10, height: 10))
            }
            .fill(Color.black.opacity(0.34), style: FillStyle(eoFill: true))

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.yellow, lineWidth: 2.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            if let label = state.crop.label {
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.yellow, in: Capsule())
                    .fixedSize()
                    // Sits under the box, or above it when the box runs close
                    // to the bottom of the screen.
                    .position(x: rect.midX,
                              y: rect.maxY + 16 > size.height - 24 ? rect.minY - 16 : rect.maxY + 16)
            }
        }
    }

}
