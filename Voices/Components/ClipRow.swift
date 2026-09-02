import SwiftUI
import MapKit

struct ClipRow: View {
    let clip: Clip
    let allClips: [Clip]
    var onDelete: (() -> Void)? = nil

    @EnvironmentObject private var authService: AuthService
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var likeService = LikeService.shared
    @ObservedObject private var relationships = UserRelationshipService.shared
    @State private var countScale: CGFloat = 1.0
    @State private var showOwnerActions = false
    @State private var showPostActions = false
    @State private var showLikers = false
    @State private var showListeners = false
    @State private var locationRemoved = false
    @State private var showDMSheet = false
    @State private var showMapLocation = false
    @State private var showShareSheet = false

    private var hasLocation: Bool { !locationRemoved && clip.lat != nil }

    private var isCurrent: Bool { player.currentClip?.id == clip.id }

    private var isOwner: Bool {
        guard let clipUserId = clip.user_id,
              case .authenticated(let profile) = authService.appState else { return false }
        return clipUserId == profile.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            userProfileLink {
                AvatarView(initials: clip.initials, username: clip.username, avatarURL: clip.profiles?.avatar_url)
            }

            VStack(alignment: .leading, spacing: 4) {
                headerRow
                if let title = clip.title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                waveformBar
                controlsRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if !player.listenedClipIDs.contains(clip.id) {
                Capsule()
                    .fill(AppTheme.gradient)
                    .frame(width: 3)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.4), value: player.listenedClipIDs.contains(clip.id))
            }
        }
        .onTapGesture { playThis() }
        .confirmationDialog("", isPresented: $showPostActions) {
            if let userId = clip.user_id {
                if hasLocation {
                    Button("Show Map Location") { showMapLocation = true }
                }
                Button("Share Post") { showShareSheet = true }
                Button("Send Message") { showDMSheet = true }
                Button("Hide @\(clip.username)") {
                    Task { try? await relationships.hideUser(userId: userId, username: clip.username) }
                }
                Button("Block @\(clip.username)", role: .destructive) {
                    Task { try? await relationships.blockUser(userId: userId, username: clip.username) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showMapLocation) {
            if #available(iOS 17.0, *), let lat = clip.lat, let lng = clip.lng {
                PostLocationMapView(
                    lat: lat,
                    lng: lng,
                    username: clip.username,
                    locationDisplay: clip.locationDisplay
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showDMSheet) {
            if let userId = clip.user_id {
                DirectMessageRecordingView(
                    recipientId: userId,
                    recipientUsername: clip.username
                ) { showDMSheet = false }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showLikers) {
            ClipStatsSheet(clipId: clip.id, mode: .likes)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showListeners) {
            ClipStatsSheet(clipId: clip.id, mode: .listeners)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("", isPresented: $showOwnerActions) {
            if onDelete != nil {
                Button("Delete Post", role: .destructive) { onDelete?() }
            }
            Button("Share Post") { showShareSheet = true }
            if hasLocation {
                Button("Show Map Location") { showMapLocation = true }
                Button("Remove Geolocation") {
                    Task { await removeFromMap() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showShareSheet) {
            SharePostSheet(clip: clip)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func userProfileLink<V: View>(@ViewBuilder content: () -> V) -> some View {
        if let uid = clip.user_id {
            NavigationLink(destination: UserProfileView(userId: uid, username: clip.username)) {
                content()
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }

    // MARK: - Sub-views

    private var headerRow: some View {
        HStack(spacing: 6) {
            // Username — single line, truncates cleanly
            userProfileLink {
                Text(clip.username)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            // Timestamp only — no location icon clutter
            Text(clip.timeDisplay)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var waveformBar: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 14)

            if isCurrent {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.gradient)
                    .frame(width: nil)
                    .mask(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle()
                                .frame(width: geo.size.width * CGFloat(player.progress))
                        }
                    }
                    .animation(.linear(duration: 0.25), value: player.progress)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.gradient.opacity(0.25))
                    .frame(height: 14)
            }

            if isCurrent && player.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.leading, 8)
            }
        }
        .frame(height: 14)
        .frame(maxWidth: .infinity)
    }

    // Controls: play/pause · play count · like · thread
    private var controlsRow: some View {
        HStack(spacing: 16) {
            // Play / Pause
            Button {
                if isCurrent { player.togglePlayPause() }
                else { playThis() }
            } label: {
                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            // Play count — tappable for owner to see listener list
            Button {
                if isOwner { showListeners = true }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "ear.fill")
                        .font(.system(size: 13))
                    Text("\(clip.play_count)")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isOwner)
            .scaleEffect(countScale)
            .onChange(of: clip.play_count, perform: { _ in
                withAnimation(.spring(response: 0.2, dampingFraction: 0.35)) { countScale = 1.45 }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.65).delay(0.13)) { countScale = 1.0 }
            })

            // Like button
            likeButton

            // Thread button
            threadButton

            Spacer(minLength: 0)

            if isOwner {
                Button { showOwnerActions = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            } else if clip.user_id != nil {
                Button { showPostActions = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func removeFromMap() async {
        struct LocationClear: Encodable {
            let lat: Double? = nil
            let lng: Double? = nil
            let location_display: String? = nil
        }
        do {
            try await SupabaseService.shared.client
                .from("clips")
                .update(LocationClear())
                .eq("id", value: clip.id.uuidString)
                .execute()
            locationRemoved = true
        } catch {
            print("ClipRow: removeFromMap error: \(error)")
        }
    }

    private var likeButton: some View {
        let isLiked = likeService.likedClipIDs.contains(clip.id)
        let offset = likeService.pendingLikeOffsets[clip.id] ?? 0
        return Button {
            if isOwner { showLikers = true }
            else { Task { await likeService.toggleLike(clip: clip) } }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isLiked ? Color.red : Color.secondary)
                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: isLiked)
                Text("\(max(0, clip.like_count + offset))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: offset)
            }
        }
        .buttonStyle(.plain)
    }

    private var threadButton: some View {
        NavigationLink(destination: ThreadView(clip: clip)) {
            HStack(spacing: 3) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Text("\(clip.reply_count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func playThis() {
        player.play(clip: clip, in: allClips)
    }
}

// MARK: - Post location map sheet

@available(iOS 17.0, *)
struct PostLocationMapView: View {
    let lat: Double
    let lng: Double
    let username: String
    let locationDisplay: String?

    @Environment(\.dismiss) private var dismiss

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private var cameraPosition: MapCameraPosition {
        .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        ))
    }

    var body: some View {
        NavigationStack {
            Map(position: .constant(cameraPosition)) {
                Annotation("", coordinate: coordinate, anchor: .bottom) {
                    VStack(spacing: 2) {
                        Text("@\(username)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(AppTheme.rust)
                            .clipShape(Capsule())
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(AppTheme.rust)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(locationDisplay ?? "Post Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppTheme.gold)
                }
            }
        }
    }
}

// MARK: - Clip stats sheet (likers / listeners)

private struct ClipStatsSheet: View {
    enum Mode { case likes, listeners }

    let clipId: UUID
    let mode: Mode

    @State private var entries: [(id: UUID, username: String)] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil
    @State private var displayTitle: String = ""
    @Environment(\.dismiss) private var dismiss

    private var baseTitle: String { mode == .likes ? "Likes" : "Listeners" }
    private var emptyIcon: String  { mode == .likes ? "heart.slash" : "ear" }
    private var emptyLabel: String { mode == .likes ? "No likes yet" : "No listeners yet" }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: emptyIcon)
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text(emptyLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(entries, id: \.id) { entry in
                        HStack(spacing: 12) {
                            AvatarView(
                                initials: String(entry.username.prefix(1)).uppercased(),
                                username: entry.username,
                                size: 36
                            )
                            Text("@\(entry.username)")
                                .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(AppTheme.cardDark)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AppTheme.canvasBlack.ignoresSafeArea())
            .navigationTitle(displayTitle.isEmpty ? baseTitle : displayTitle)
            .onAppear { displayTitle = baseTitle }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(AppTheme.gold)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            var loaded: [(id: UUID, username: String)] = []

            switch mode {
            case .likes:
                struct LikeRow: Decodable {
                    let user_id: UUID
                    struct Prof: Decodable { let username: String? }
                    let profiles: Prof?
                }
                let rows: [LikeRow] = try await SupabaseService.shared.client
                    .from("likes")
                    .select("user_id, profiles!likes_user_id_fkey(username)")
                    .eq("clip_id", value: clipId.uuidString)
                    .order("created_at", ascending: false)
                    .execute()
                    .value
                loaded = rows.compactMap { row in
                    guard let name = row.profiles?.username else { return nil }
                    return (id: row.user_id, username: name)
                }

            case .listeners:
                struct PlayRow: Decodable { let user_id: UUID }
                let playRows: [PlayRow] = try await SupabaseService.shared.client
                    .from("clip_plays")
                    .select("user_id")
                    .eq("clip_id", value: clipId.uuidString)
                    .order("played_at", ascending: false)
                    .execute()
                    .value
                print("[ClipStatsSheet] clip_plays rows: \(playRows.count)")

                guard !playRows.isEmpty else { entries = []; return }

                struct ProfileRow: Decodable { let id: UUID; let username: String? }
                let profileRows: [ProfileRow] = try await SupabaseService.shared.client
                    .from("profiles")
                    .select("id, username")
                    .in("id", values: playRows.map { $0.user_id.uuidString })
                    .execute()
                    .value

                let profileMap = Dictionary(
                    uniqueKeysWithValues: profileRows.compactMap { row -> (UUID, String)? in
                        guard let name = row.username else { return nil }
                        return (row.id, name)
                    }
                )
                loaded = playRows.compactMap { row in
                    guard let name = profileMap[row.user_id] else { return nil }
                    return (id: row.user_id, username: name)
                }
            }

            // Sort: people the current user follows appear first
            let followingSet = await fetchFollowingSet()
            entries = loaded.sorted { a, b in
                let aFollowed = followingSet.contains(a.id)
                let bFollowed = followingSet.contains(b.id)
                if aFollowed != bFollowed { return aFollowed }
                return false
            }

            displayTitle = "\(baseTitle) (\(entries.count))"

        } catch {
            print("[ClipStatsSheet] load error (\(mode)): \(error)")
            loadError = error.localizedDescription
        }
    }

    private func fetchFollowingSet() async -> Set<UUID> {
        guard let uid = try? await SupabaseService.shared.client.auth.session.user.id else {
            return []
        }
        struct FollowRow: Decodable { let following_id: UUID }
        let rows: [FollowRow] = (try? await SupabaseService.shared.client
            .from("follows")
            .select("following_id")
            .eq("follower_id", value: uid.uuidString)
            .execute()
            .value) ?? []
        return Set(rows.map { $0.following_id })
    }
}
