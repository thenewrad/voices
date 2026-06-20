import SwiftUI
import MapKit
import CoreLocation

@available(iOS 17.0, *)
struct LocalView: View {
    @EnvironmentObject private var authService: AuthService
    @StateObject private var vm = LocalViewModel()
    @StateObject private var activityVM = ActivityViewModel()
    @ObservedObject private var player = AudioPlayerService.shared
    @ObservedObject private var pushService = PushNotificationService.shared
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isNowPlayingPresented = false
    @State private var hasInitialLocation = false
    @State private var showSearch = false
    @State private var showActivity = false
    @State private var activityInitialFilter: ActivityFilter = .likes

    var body: some View {
        NavigationStack {
            Group {
                if let error = vm.error, vm.userLocation == nil {
                    locationErrorView(error)
                } else {
                    mainContent
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .toolbarBackground(AppTheme.canvasBlack, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear {
                hasInitialLocation = false
                if let loc = vm.userLocation {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: loc.coordinate,
                        span: mapSpan
                    ))
                    hasInitialLocation = true
                }
            }
            .task {
                vm.requestLocationAndFetch()
                if case .authenticated(let profile) = authService.appState {
                    await activityVM.fetch(userId: profile.id)
                }
                if let filter = pushService.pendingActivityFilter {
                    pushService.pendingActivityFilter = nil
                    activityInitialFilter = filter
                    activityVM.markRead()
                    showActivity = true
                }
            }
            .onChange(of: pushService.pendingActivityFilter) { _, newValue in
                guard let filter = newValue else { return }
                pushService.pendingActivityFilter = nil
                activityInitialFilter = filter
                activityVM.markRead()
                showActivity = true
            }
            .refreshable { await vm.fetchNearbyClips() }
            .onChange(of: vm.userLocation) { _, location in
                guard let loc = location else { return }
                let isFirst = !hasInitialLocation
                hasInitialLocation = true
                guard isFirst || vm.isDriveMode else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: loc.coordinate,
                        span: mapSpan
                    ))
                }
            }
            .onChange(of: vm.isDriveMode) { _, driveOn in
                guard driveOn, let loc = vm.userLocation else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: loc.coordinate,
                        span: mapSpan
                    ))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.currentClip != nil {
                    MiniPlayerBar(isExpanded: $isNowPlayingPresented)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .sheet(isPresented: $isNowPlayingPresented) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // Span that shows ~3.5× the radius so the circle is comfortably visible
    private var mapSpan: MKCoordinateSpan {
        let deg = max(0.02, vm.radiusMiles * 3.5 / 69.0)
        return MKCoordinateSpan(latitudeDelta: deg, longitudeDelta: deg)
    }

    // MARK: - Header

    private var localHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title + subtitle
            VStack(alignment: .leading, spacing: 4) {
                Text("ZeitMap")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Explore the map to hear what people are saying around town.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.gold)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Divider().overlay(Color(hex: "3A2820"))

            // Drive mode card
            Button(action: { vm.toggleDriveMode() }) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(vm.isDriveMode ? AppTheme.gold : Color.white.opacity(0.1))
                            .frame(width: 52, height: 52)
                        Image(systemName: "car.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(vm.isDriveMode ? AppTheme.canvasBlack : .secondary)
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.65), value: vm.isDriveMode)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(vm.isDriveMode ? "Drive Mode On" : "Drive Mode")
                            .font(.subheadline.bold())
                            .foregroundStyle(vm.isDriveMode ? AppTheme.gold : .white)
                        Text("Turn on drive mode to hear posts made around you while moving.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: vm.isDriveMode ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(vm.isDriveMode ? AppTheme.gold : .secondary)
                        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: vm.isDriveMode)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            Divider().overlay(Color(hex: "3A2820"))
        }
        .background(AppTheme.canvasBlack)
    }

    // MARK: - Main content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                localHeader

                mapSection
                    .frame(height: 300)

                radiusControl

                if vm.isDriveMode {
                    driveModeBar
                }

                Divider().overlay(Color(hex: "3A2820"))

                filterTabBar

                if vm.isLoading && vm.clips.isEmpty {
                    ProgressView()
                        .padding(.top, 48)
                } else if vm.filteredClips.isEmpty && vm.userLocation != nil {
                    if vm.clips.isEmpty {
                        emptyState
                    } else {
                        filteredEmptyState
                    }
                } else {
                    clipList
                }
            }
        }
        .background(AppTheme.canvasBlack)
        .animation(.default, value: vm.isDriveMode)
        .animation(.easeInOut(duration: 0.2), value: vm.filter)
    }

    // MARK: - Map

    private var mapSection: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()

            // Single radius circle centered on the search area
            if let center = vm.radiusCenter {
                MapCircle(center: center, radius: vm.radiusMiles * LocalViewModel.metersPerMile)
                    .foregroundStyle(AppTheme.gold.opacity(0.08))
                    .stroke(AppTheme.gold.opacity(0.55), lineWidth: 1.5)
            }

            // Outside-radius clips — plain pin drops
            ForEach(vm.outerClips) { clip in
                if let lat = clip.lat, let lng = clip.lng {
                    let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                    Annotation("", coordinate: coord, anchor: .bottom) {
                        Image(systemName: "mappin")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color(.systemGray3))
                    }
                }
            }

            // Inside-radius clips — full summary labels
            ForEach(vm.filteredClips) { clip in
                if let lat = clip.lat, let lng = clip.lng {
                    let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                    let isListened = vm.listenedClipIDs.contains(clip.id)

                    Annotation("", coordinate: coord, anchor: .center) {
                        let label = (clip.title?.isEmpty == false) ? clip.title! : clip.username
                        Button {
                            player.play(clip: clip, in: vm.filteredClips)
                        } label: {
                            Text(label)
                                .font(.caption2.bold())
                                .foregroundStyle(isListened ? .secondary : AppTheme.rust)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.thinMaterial)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        // When drive mode is off, panning the map moves the radius center
        .onMapCameraChange(frequency: .onEnd) { context in
            guard !vm.isDriveMode else { return }
            Task { await vm.updateRadiusCenter(context.camera.centerCoordinate) }
        }
    }

    // MARK: - Radius slider

    private var radiusControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.gold)

            Slider(value: $vm.radiusMiles, in: 0.5...20, step: 0.5)
                .tint(AppTheme.gold)
                .onChange(of: vm.radiusMiles) { _, _ in
                    vm.onRadiusChanged()
                }

            Text(vm.radiusMilesLabel)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.canvasBlack)
        .overlay(alignment: .bottom) {
            Divider().overlay(Color(hex: "3A2820"))
        }
    }

    // MARK: - Drive Mode bar

    private var driveModeBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "car.fill")
                .foregroundStyle(.white)
            Text("Drive Mode On — playing nearest clips")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            if vm.isLoading {
                ProgressView().tint(.white).scaleEffect(0.8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.gradient)
    }

    // MARK: - Filter tab bar

    private var filterTabBar: some View {
        HStack(spacing: 0) {
            ForEach(LocalFilter.allCases, id: \.self) { tab in
                Button {
                    vm.filter = tab
                } label: {
                    HStack(spacing: 6) {
                        Text(tab.label)
                            .font(.subheadline.weight(.semibold))
                        if tab == .new && vm.newClipCount > 0 {
                            Text("\(vm.newClipCount)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(AppTheme.rust)
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundStyle(vm.filter == tab ? AppTheme.gold : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(vm.filter == tab ? AppTheme.gold : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .background(AppTheme.canvasBlack)
        .overlay(alignment: .bottom) {
            Divider().overlay(Color(hex: "3A2820"))
        }
    }

    // MARK: - Clip list

    private var clipList: some View {
        LazyVStack(spacing: 0) {
            ForEach(vm.filteredClips) { clip in
                ClipRow(clip: clip, allClips: vm.filteredClips)
                    .background(AppTheme.canvasBlack)
                Divider()
                    .overlay(Color(hex: "3A2820"))
            }
        }
    }

    // MARK: - Empty / error states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No clips within \(vm.radiusMilesLabel) of this location")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Try expanding the radius or pan to a different area")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 56)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: vm.filter == .new ? "checkmark.circle" : "ear")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(vm.filter == .new ? "All caught up!" : "No listened clips nearby")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(vm.filter == .new
                 ? "You've listened to all nearby clips."
                 : "Start playing clips to build your history.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 56)
    }

    private func locationErrorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "location.slash")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.purple)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: { showSearch = true }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white)
                        .font(.system(size: 15))
                }
            }
            .buttonStyle(PlainButtonStyle())
            .sheet(isPresented: $showSearch) { SearchView() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: {
                showActivity = true
                activityVM.markRead()
            }) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "bell")
                            .foregroundColor(.white)
                            .font(.system(size: 15))
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                    if activityVM.unreadCount > 0 {
                        Text("\(min(activityVM.unreadCount, 99))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .clipShape(Capsule())
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .sheet(isPresented: $showActivity) {
                ActivityView(initialFilter: activityInitialFilter)
                    .environmentObject(authService)
            }
        }
    }
}

#Preview {
    if #available(iOS 17.0, *) {
        LocalView()
    }
}
