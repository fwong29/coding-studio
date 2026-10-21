import SwiftUI

/// The "what and where to shoot" card at the top of the viewfinder.
///
/// Collapsed it is one line, so it never fights the live frame. Tapped, it
/// opens into the full brief: where to find the shot, the ordered steps, and
/// why the shot works — which is the part that makes you better at this rather
/// than just obedient.
struct AssignmentCard: View {

    let assignment: ShotAssignment?
    let lightSummary: String
    let sceneLabel: String?
    @Binding var isExpanded: Bool
    let onShuffle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let assignment {
                header(assignment)

                if isExpanded {
                    expanded(assignment)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                Text("Finding you a shot…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(14)
            }
        }
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
    }

    private func header(_ assignment: ShotAssignment) -> some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(assignment.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(assignment.subject)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(isExpanded ? nil : 1)

                    HStack(spacing: 6) {
                        Label(lightSummary, systemImage: "sun.horizon")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                        if let sceneLabel {
                            Text("· \(sceneLabel)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .padding(.top, 1)
                }

                Spacer(minLength: 4)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func expanded(_ assignment: ShotAssignment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Color.white.opacity(0.12))

            section("Where to find it", icon: "map") {
                Text(assignment.findIt)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.78))
            }

            section("How to shoot it", icon: "list.number") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(assignment.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.black)
                                .frame(width: 16, height: 16)
                                .background(Color.white.opacity(0.85), in: Circle())
                            Text(step)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            section("Why it works", icon: "lightbulb") {
                Text(assignment.why)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                onShuffle()
            } label: {
                Label("Give me a different shot", systemImage: "shuffle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(.white.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 2)
    }

    private func section<Content: View>(_ title: String,
                                        icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
            content()
        }
    }
}
