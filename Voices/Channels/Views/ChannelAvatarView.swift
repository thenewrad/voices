import SwiftUI

/// Square channel icon (rounded corners): an uploaded image when set,
/// otherwise a gradient + initials — the channel equivalent of AvatarView.
struct ChannelAvatarView: View {
    let name: String
    var size: CGFloat = 44
    var avatarURL: String? = nil

    private var initials: String {
        name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
            .joined()
    }

    var body: some View {
        ZStack {
            gradient

            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            if let urlString = avatarURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }

    private var gradient: LinearGradient {
        let h = abs(name.hashValue)
        let hue1 = Double(h % 1000) / 1000.0
        let hue2 = Double((h / 1000) % 1000) / 1000.0
        return LinearGradient(
            colors: [
                Color(hue: hue1, saturation: 0.65, brightness: 0.82),
                Color(hue: hue2, saturation: 0.75, brightness: 0.72)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
