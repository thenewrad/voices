import SwiftUI

struct AvatarView: View {
    let initials: String
    let username: String
    var size: CGFloat = 44
    var avatarURL: String? = nil

    var body: some View {
        ZStack {
            Circle().fill(gradient)

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
        .clipShape(Circle())
    }

    private var gradient: LinearGradient {
        let h = abs(username.hashValue)
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

#Preview {
    HStack(spacing: 12) {
        AvatarView(initials: "BJ", username: "brianjohnson")
        AvatarView(initials: "AM", username: "alice", size: 36)
        AvatarView(initials: "Z", username: "zzz", size: 52)
    }
    .padding()
}
