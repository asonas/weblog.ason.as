import BackgroundTasks
import SwiftUI

@main
struct PhotoInboxApp: App {
  @State private var library: PhotoLibrary
  @State private var uploads: UploadCoordinator
  @State private var selection: PhotoSelectionStore

  init() {
    let library = PhotoLibrary()
    let selection = PhotoSelectionStore()
    let coordinator = UploadCoordinator(library: library, selection: selection)
    _library = State(initialValue: library)
    _uploads = State(initialValue: coordinator)
    _selection = State(initialValue: selection)
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: "com.asonas.weblog.PhotoInbox.retry-uploads",
      // The launch handler inherits MainActor isolation from App.init.
      using: .main
    ) { task in
      guard let processingTask = task as? BGProcessingTask else { return }
      let operation = Task { @MainActor in
        await coordinator.processQueue()
        processingTask.setTaskCompleted(success: true)
      }
      let expire: @MainActor @Sendable () -> Void = {
        processingTask.setTaskCompleted(success: false)
      }
      processingTask.expirationHandler = { @Sendable in
        operation.cancel()
        Task { @MainActor in expire() }
      }
    }
  }

  var body: some Scene {
    WindowGroup {
      PhotoGridView(library: library, uploads: uploads, selection: selection)
        .task { await uploads.restoreAndRetry() }
    }
  }
}
