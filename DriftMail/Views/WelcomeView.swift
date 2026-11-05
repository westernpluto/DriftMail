import SwiftUI

/// First launch. Built as an arrangement view: on the outer display the hero sits
/// above the sign-in choices; on the open inner display they sit side by side, and
/// when the device is partially folded each lands on its own half.
struct WelcomeView: View {
    @State private var provider: MailProvider?

    var body: some View {
        NavigationStack {
            ArrangementView {
                hero
            } secondary: {
                providerChooser
            }
            .arrangementViewStyle(.split)
            .background(Color(uiColor: .systemGroupedBackground))
            .sheet(item: $provider) { provider in
                AccountSetupView(provider: provider)
            }
        }
    }

    private var hero: some View {
        ZStack {
            Theme.drift
                .opacity(0.9)
                .ignoresSafeArea()
                .backgroundExtensionEffect()
            WaveBackdrop()
                .ignoresSafeArea()
            VStack(spacing: 18) {
                DriftLogo(size: 104)
                Text("DriftMail")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("All your inboxes in one calm place.\nNotified the moment mail lands.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(32)
        }
    }

    private var providerChooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Add an account")
                    .font(.title2.weight(.bold))
                Text("DriftMail connects straight to your provider. Your password never leaves your phone unless you turn on instant notifications with your own relay.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // Even column count so the grid splits cleanly at the fold.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(MailProvider.all) { provider in
                        Button {
                            self.provider = provider
                        } label: {
                            VStack(spacing: 10) {
                                Image(systemName: provider.symbol)
                                    .font(.system(size: 30))
                                    .foregroundStyle(Theme.color(for: provider.id))
                                Text(provider.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 92)
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: .rect(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Label("Free instant notifications can be set up after you add an account.", systemImage: "bell.badge")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Soft animated waves behind the hero.
struct WaveBackdrop: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for layer in 0..<3 {
                    let phase = t * (0.25 + Double(layer) * 0.12) + Double(layer)
                    let baseline = size.height * (0.72 + Double(layer) * 0.08)
                    let amplitude = size.height * 0.035
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    stride(from: 0.0, through: size.width, by: 6).forEach { x in
                        let y = baseline + sin(x / size.width * .pi * 2 + phase) * amplitude
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    context.fill(path, with: .color(.white.opacity(0.08 + Double(layer) * 0.04)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
