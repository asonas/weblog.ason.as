import SwiftUI
import UIKit

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var pairingCode = ""
  @State private var paired = (try? Credentials.loadToken()) != nil
  @State private var isPairing = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("weblog.ason.as") {
          if paired {
            Label("接続済み", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          } else {
            TextField("12文字のペアリングコード", text: $pairingCode)
              .textInputAutocapitalization(.characters)
              .autocorrectionDisabled()
              .font(.body.monospaced())
              .accessibilityLabel("ペアリングコード")
            Button(isPairing ? "接続中" : "接続") { Task { await pair() } }
              .disabled(
                pairingCode.filter(\.isLetter).count + pairingCode.filter(\.isNumber).count != 12
                  || isPairing)
          }
          if let errorMessage {
            Text(errorMessage).foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("設定")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完了") { dismiss() }
        }
      }
    }
  }

  private func pair() async {
    isPairing = true
    defer { isPairing = false }
    do {
      let response = try await MobileAPIClient(
        baseURL: URL(string: "https://weblog.ason.as")!
      ).exchangePairing(code: pairingCode, deviceName: UIDevice.current.name)
      try Credentials.saveToken(response.token)
      paired = true
      errorMessage = nil
    } catch {
      errorMessage = "接続できませんでした。コードを確認してください。"
    }
  }
}
