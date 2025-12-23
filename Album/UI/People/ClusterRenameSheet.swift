import SwiftUI

struct ClusterRenameSheet: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.dismiss) private var dismiss

    let faceID: String
    let initialName: String?

    @State private var name: String
    @FocusState private var focused: Bool

    init(faceID: String, initialName: String?) {
        self.faceID = faceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialName = initialName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self._name = State(initialValue: initialName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Sydney"))
                        .focused($focused)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()

                    Text(faceID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Cluster")
                }

                Section {
                    Button(role: .destructive) {
                        Task { @MainActor in
                            await model.clearFaceLabel(faceID: faceID)
                            dismiss()
                        }
                    } label: {
                        Text("Clear Name")
                    }
                }
            }
            .navigationTitle("Rename")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { @MainActor in
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            await model.setManualFaceLabel(faceID: faceID, name: trimmed)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            focused = true
        }
    }
}

