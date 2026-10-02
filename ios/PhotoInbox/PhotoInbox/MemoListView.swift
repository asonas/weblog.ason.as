import SwiftUI

struct MemoListView: View {
  @State private var store = MemoStore()
  @State private var showingSettings = false
  @State private var selected: String?
  @State private var deleting: String?
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      List {
        if !store.error.isEmpty { Text(store.error).foregroundStyle(.red) }
        if !store.notice.isEmpty { Text(store.notice) }
        ForEach(store.memos) { memo in
          NavigationLink(value: memo.id) {
            VStack(alignment: .leading, spacing: 8) {
              Text(memo.body.isEmpty ? "空のメモ" : memo.body).lineLimit(4)
              Text(memo.needsSave || memo.flight != nil ? "端末に保存済み・送信待ち" : "保存済み")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .swipeActions { Button("削除", role: .destructive) { deleting = memo.id } }
        }
        if store.memos.isEmpty { Text("思いついたことをメモできます。") }
      }
      .navigationTitle("メモ")
      .refreshable { await store.sync() }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button("設定") { showingSettings = true } }
        ToolbarItem(placement: .primaryAction) {
          Button("メモを追加", systemImage: "square.and.pencil") { selected = store.add() }.disabled(
            !store.isAvailable)
        }
      }
      .navigationDestination(for: String.self) { id in MemoEditorView(store: store, id: id) }
      .navigationDestination(item: $selected) { id in MemoEditorView(store: store, id: id) }
      .sheet(isPresented: $showingSettings) { SettingsView() }
      .alert(
        "このメモを削除しますか？",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
      ) {
        Button("削除", role: .destructive) {
          if let id = deleting { Task { await store.delete(id: id) } }
          deleting = nil
        }
        Button("キャンセル", role: .cancel) { deleting = nil }
      }
      .task {
        while !Task.isCancelled {
          if scenePhase == .active { await store.sync() }
          do { try await Task.sleep(for: .seconds(10)) } catch { return }
        }
      }
    }
  }
}

private struct MemoEditorView: View {
  let store: MemoStore
  @State private var bodyText: String
  @State private var localID: String
  @FocusState private var bodyFocused: Bool

  init(store: MemoStore, id: String) {
    self.store = store
    _bodyText = State(initialValue: store.memos.first(where: { $0.id == id })?.body ?? "")
    _localID = State(initialValue: id)
  }

  var body: some View {
    VStack(alignment: .leading) {
      TextEditor(text: $bodyText).accessibilityLabel("メモ本文")
        .focused($bodyFocused)
        .onChange(of: bodyText) { previous, value in
          localID = store.edit(id: localID, body: value, previousBody: previous)
        }
      Text(store.error.isEmpty ? "変更は自動保存されます" : store.error)
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding()
    .navigationTitle("メモ")
    .task { bodyFocused = true }
  }
}
