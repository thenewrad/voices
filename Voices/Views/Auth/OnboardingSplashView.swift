import SwiftUI

struct OnboardingSplashView: View {
    let onDone: () -> Void
    @State private var currentPage = 0

    private let cards: [(icon: String, title: String, body: String, detail: String)] = [
        (
            icon: "waveform.circle.fill",
            title: "ZeitVox",
            body: "Audio social media.",
            detail: "Record, share, listen, comment.\nThe ZeitFeed has the voices of those around you."
        ),
        (
            icon: "location.circle.fill",
            title: "Try Drive Mode",
            body: "Your feed, your location.",
            detail: "Turn on Drive Mode and your feed populates posts closest to you.\nExplore the map to hear what people are saying."
        )
    ]

    var body: some View {
        ZStack {
            Color(hex: "1A1210").ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    ForEach(0..<cards.count, id: \.self) { i in
                        cardView(cards[i]).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.35), value: currentPage)

                bottomBar
                    .padding(.bottom, 48)
            }
        }
    }

    private func cardView(_ card: (icon: String, title: String, body: String, detail: String)) -> some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: card.icon)
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(Color(hex: "C4622D"))
                .padding(.bottom, 32)

            Text(card.title)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 8)

            Text(card.body)
                .font(.title3)
                .foregroundStyle(Color(hex: "E8A84C"))
                .padding(.bottom, 20)

            Text(card.detail)
                .font(.body)
                .foregroundStyle(Color.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 40)

            Spacer()
            Spacer()
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                ForEach(0..<cards.count, id: \.self) { i in
                    Capsule()
                        .fill(i == currentPage ? Color(hex: "C4622D") : Color.white.opacity(0.25))
                        .frame(width: i == currentPage ? 20 : 8, height: 8)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
                }
            }

            Button {
                if currentPage < cards.count - 1 {
                    withAnimation { currentPage += 1 }
                } else {
                    onDone()
                }
            } label: {
                Text(currentPage < cards.count - 1 ? "Next" : "Get Started")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "C4622D"))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 32)
            }

            Button("Skip") { onDone() }
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.4))
        }
    }
}
