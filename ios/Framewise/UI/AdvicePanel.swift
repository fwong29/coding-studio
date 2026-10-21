import SwiftUI

/// The top-of-viewfinder panel: what the app makes of the scene, and where to
/// stand to shoot it better.
///
/// Collapsed it shows the scene read plus the single most important move, so
/// it costs one glance. Tapped, it opens into the full set with the reasoning,
/// which is where the actual learning happens.
struct AdvicePanel: View {

    let brief: SceneBrief
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded, !brief.advice.isEmpty {
                expanded
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
        .animation(.easeInOut(duration: 0.3), value: brief)
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    // The scene read, so you can tell instantly whether the
                    // advice below is based on a correct guess.
                    Text(brief.read)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(2)

                    if let top = brief.advice.first {
                        HStack(spacing: 7) {
                            Image(systemName: top.axis.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                            Text(top.headline)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(isExpanded ? nil : 2)
                                .multilineTextAlignment(.leading)
                        }
                    } else {
                        Text("Nothing to change — shoot it")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.green)
                    }

                    if !isExpanded, brief.advice.count > 1 {
                        Text("\(brief.advice.count - 1) more")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 11) {
            Divider().overlay(Color.white.opacity(0.12))

            ForEach(brief.advice) { advice in
                AdviceRow(advice: advice,
                          isPrimary: advice.id == brief.advice.first?.id)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 2)
    }
}

/// One line of advice with its reasoning.
struct AdviceRow: View {

    let advice: ShotAdvice
    let isPrimary: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: advice.axis.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(isPrimary ? 0.9 : 0.55), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(advice.headline)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(advice.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
