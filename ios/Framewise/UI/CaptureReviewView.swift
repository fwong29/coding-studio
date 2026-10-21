import SwiftUI

/// Before/after of the last shot, with the edit decisions spelled out.
///
/// Showing the recipe is a deliberate choice. An auto-editor that works
/// invisibly is impossible to trust or to argue with; one that tells you it
/// added half a stop and warmed the white balance is something you can learn
/// from and override.
struct CaptureReviewView: View {

    let capture: EditedCapture
    let onDismiss: () -> Void

    @State private var showingOriginal = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    imageComparison

                    Text(showingOriginal ? "Straight out of the camera" : "After auto-edit")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    recipeCard

                    Label("Saved to your Photos library",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.green)
                }
                .padding(20)
            }
            .navigationTitle("Last shot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }

    private var imageComparison: some View {
        ZStack {
            if let after = capture.afterThumbnail, let before = capture.beforeThumbnail {
                Image(uiImage: showingOriginal ? before : after)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.quaternary)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay(Text("No preview").foregroundStyle(.secondary))
            }
        }
        // Press and hold is the natural gesture for a before/after peek.
        .onLongPressGesture(minimumDuration: 0.01, maximumDistance: 40, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.15)) { showingOriginal = pressing }
        }, perform: {})
        .overlay(alignment: .bottomTrailing) {
            Text("Hold to compare")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(10)
        }
    }

    private var recipeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What was changed")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if capture.recipe.sceneKind != .unknown {
                    Text(capture.recipe.sceneKind.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
            }

            ForEach(capture.recipe.summary, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(.tint)
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                    Text(line)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
