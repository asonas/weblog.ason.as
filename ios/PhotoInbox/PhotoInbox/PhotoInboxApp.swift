import BackgroundTasks
import SwiftUI

@main
struct PhotoInboxApp: App {
    @State private var library: PhotoLibrary
    @State private var uploads: UploadCoordinator

    init() {
        let library = PhotoLibrary()
        let coordinator = UploadCoordinator(library: library)
        _library = State(initialValue: library)
        _uploads = State(initialValue: coordinator)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.asonas.weblog.PhotoInbox.retry-uploads",
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            let operation = Task { @MainActor in
                await coordinator.processQueue()
                processingTask.setTaskCompleted(success: true)
            }
            processingTask.expirationHandler = {
                operation.cancel()
                processingTask.setTaskCompleted(success: false)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            PhotoGridView(library: library, uploads: uploads)
                .task { await uploads.restoreAndRetry() }
        }
    }
}
