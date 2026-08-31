import SwiftUI

struct PhotoGridView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Bindable var library: PhotoLibrary
  @Bindable var uploads: UploadCoordinator
  @Bindable var selection: PhotoSelectionStore
  @State private var showingSettings = false
  @State private var presentedFailure: PresentedUploadFailure?

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
    .alert(
      "写真を送信できませんでした",
      isPresented: Binding(
        get: { presentedFailure != nil },
        set: { if !$0 { presentedFailure = nil } }
      ),
      presenting: presentedFailure
    ) { presented in
      Button("再送") {
        Task { await uploads.retryFailed(assetID: presented.assetID) }
      }
      Button("送信対象から外す", role: .destructive) {
        Task { await uploads.excludeFailed(assetID: presented.assetID) }
      }
      Button("キャンセル", role: .cancel) {}
    } message: { presented in
      Text(presented.message)
    }
    .task {
      library.refreshAuthorizationAndPhotos()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        library.refreshAuthorizationAndPhotos()
      }
    }
    .onChange(of: library.photos.map(\.id)) { _, identifiers in
      selection.updatePhotos(identifiers)
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
              status: selection.status(of: photo.id),
              failure: uploads.failuresByAssetID[photo.id],
              failureActionsDisabled: uploads.isSending
            ) {
              if let failure = uploads.failuresByAssetID[photo.id] {
                presentedFailure = PresentedUploadFailure(assetID: photo.id, failure: failure)
              } else {
                selection.toggle(photo.id)
              }
            }
          }
        }
      }
    } else {
      Button("写真へのアクセスを許可") { Task { await library.requestAccess() } }
        .buttonStyle(.borderedProminent)
    }
  }

  private var sendBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("送信済み \(visibleUploadedCount)件・待機 \(waitingCount)件")
        if !uploads.failuresByAssetID.isEmpty {
          Menu("失敗 \(uploads.failuresByAssetID.count)件") {
            ForEach(Array(presentedFailures.enumerated()), id: \.element.id) { index, presented in
              Button("失敗 \(index + 1): \(presented.failure.message)") {
                presentedFailure = presented
              }
            }
          }
          .disabled(uploads.isSending)
        } else {
          Text("失敗 0件")
        }
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
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
    }
    .padding()
    .background(.ultraThinMaterial)
  }

  private var waitingCount: Int {
    max(uploads.pendingCount - uploads.failuresByAssetID.count, 0)
  }

  private var visibleUploadedCount: Int {
    selection.uploadedCount(in: library.photos.map(\.id))
  }

  private var presentedFailures: [PresentedUploadFailure] {
    uploads.failuresByAssetID.keys.sorted().compactMap { assetID in
      uploads.failuresByAssetID[assetID].map {
        PresentedUploadFailure(assetID: assetID, failure: $0)
      }
    }
  }
}

private struct PresentedUploadFailure: Identifiable {
  let assetID: String
  let failure: UploadFailure

  var id: String { assetID }
  var message: String {
    guard let requestID = failure.requestID else { return failure.message }
    return "\(failure.message)\n問い合わせID: \(requestID)"
  }
}

private struct PhotoCell: View {
  let photo: LibraryPhoto
  let library: PhotoLibrary
  let status: PhotoSelectionStatus
  let failure: UploadFailure?
  let failureActionsDisabled: Bool
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
          .opacity(status == .selected ? 1 : 0.55)
          if failure != nil {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.title3)
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, .orange)
              .padding(6)
          } else if status == .selected {
            Image(systemName: "checkmark.circle.fill")
              .font(.title3)
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, .blue)
              .padding(6)
          } else if status == .uploaded {
            Image(systemName: "arrow.up.circle.fill")
              .font(.title3)
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, .green)
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
    .disabled(status == .uploaded || (failure != nil && failureActionsDisabled))
    .accessibilityLabel("\(photo.capturedAt.formatted(date: .omitted, time: .shortened))の写真")
    .accessibilityValue(accessibilityValue)
    .task {
      let scale = UIScreen.main.scale
      image = await library.thumbnail(
        for: photo, size: CGSize(width: 240 * scale, height: 240 * scale))
    }
  }

  private var accessibilityValue: String {
    if let failure { return "送信失敗。\(failure.message)" }
    return switch status {
    case .selected: "選択中"
    case .excluded: "除外"
    case .uploaded: "アップロード済み"
    }
  }
}
