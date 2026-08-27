import SwiftUI

struct PhotoGridView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var library: PhotoLibrary
    @Bindable var uploads: UploadCoordinator
    @State private var selection = PhotoSelection(assetIDs: [])
    @State private var showingSettings = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            content
            Button("A") { showingSettings = true }
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .padding()
                .accessibilityLabel("設定")
        }
        .safeAreaInset(edge: .bottom) { sendBar }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .task {
            library.refreshAuthorizationAndPhotos()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.refreshAuthorizationAndPhotos()
            }
        }
        .onChange(of: library.photos.map(\.id)) { _, identifiers in
            selection = PhotoSelection(assetIDs: identifiers)
        }
    }

    @ViewBuilder private var content: some View {
        if library.canRead {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(library.photos) { photo in
                        PhotoCell(
                            photo: photo,
                            library: library,
                            selected: selection.selectedIDs.contains(photo.id)
                        ) { selection.toggle(photo.id) }
                    }
                }
            }
        } else {
            Button("写真へのアクセスを許可") { Task { await library.requestAccess() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var sendBar: some View {
        HStack {
            Text("\(selection.selectedIDs.count)枚")
                .font(.headline.monospacedDigit())
            Spacer()
            Button(uploads.isSending ? "送信中" : "すべて送る") {
                let selected = library.photos.filter { selection.selectedIDs.contains($0.id) }
                Task { await uploads.enqueue(selected) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.selectedIDs.isEmpty || uploads.isSending)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

private struct PhotoCell: View {
    let photo: LibraryPhoto
    let library: PhotoLibrary
    let selected: Bool
    let toggle: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: toggle) {
            GeometryReader { geometry in
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color.secondary.opacity(0.25)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .opacity(selected ? 1 : 0.55)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .blue)
                            .padding(6)
                    } else {
                        Image(systemName: "circle")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.7), radius: 2)
                            .padding(6)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(photo.capturedAt.formatted(date: .omitted, time: .shortened))の写真")
        .accessibilityValue(selected ? "選択中" : "除外")
        .task {
            let scale = UIScreen.main.scale
            image = await library.thumbnail(for: photo, size: CGSize(width: 240 * scale, height: 240 * scale))
        }
    }
}
