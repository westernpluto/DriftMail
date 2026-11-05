import SwiftUI

enum Theme {
    static let accent = Color(red: 0.24, green: 0.45, blue: 0.98)

    /// The DriftMail gradient: ocean blue drifting into violet and teal.
    static let drift = LinearGradient(
        colors: [Color(red: 0.12, green: 0.70, blue: 0.86),
                 Color(red: 0.24, green: 0.45, blue: 0.98),
                 Color(red: 0.52, green: 0.33, blue: 0.95)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let softDrift = LinearGradient(
        colors: [Color(red: 0.12, green: 0.70, blue: 0.86).opacity(0.18),
                 Color(red: 0.52, green: 0.33, blue: 0.95).opacity(0.10),
                 .clear],
        startPoint: .topLeading, endPoint: .bottom)

    static let palette: [Color] = [
        Color(red: 0.24, green: 0.45, blue: 0.98),
        Color(red: 0.55, green: 0.35, blue: 0.95),
        Color(red: 0.95, green: 0.38, blue: 0.55),
        Color(red: 0.98, green: 0.58, blue: 0.20),
        Color(red: 0.15, green: 0.72, blue: 0.62),
        Color(red: 0.10, green: 0.66, blue: 0.88),
        Color(red: 0.86, green: 0.30, blue: 0.86),
        Color(red: 0.40, green: 0.62, blue: 0.25),
    ]

    /// A stable colour for any string (sender address, account email…).
    static func color(for key: String) -> Color {
        var hash: UInt64 = 5381
        for byte in key.lowercased().utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }

    static func accountColor(_ account: MailAccount?) -> Color {
        guard let account else { return .secondary }
        return palette[account.colorIndex % palette.count]
    }
}

struct AvatarView: View {
    var address: EmailAddress
    var size: CGFloat = 40

    var body: some View {
        let color = Theme.color(for: address.address)
        ZStack {
            Circle().fill(
                LinearGradient(colors: [color.opacity(0.95), color.opacity(0.65)],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(address.initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct AccountDot: View {
    var account: MailAccount?
    var body: some View {
        Circle()
            .fill(Theme.accountColor(account))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

struct DriftLogo: View {
    var size: CGFloat = 96
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.drift)
            Image(systemName: "envelope.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .offset(y: -size * 0.04)
            Image(systemName: "water.waves")
                .font(.system(size: size * 0.22, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .offset(y: size * 0.26)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.accent.opacity(0.35), radius: size * 0.15, y: size * 0.08)
        .accessibilityHidden(true)
    }
}

extension Date {
    /// "9:41", "Yesterday", "Tue", or "3 Mar" like Mail.
    var mailListLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.day().month(.abbreviated))
        }
        return formatted(date: .numeric, time: .omitted)
    }
}
