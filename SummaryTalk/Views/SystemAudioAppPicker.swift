import SwiftUI
import AppKit
import ScreenCaptureKit

struct SystemAudioAppPicker: View {
    @Bindable var manager: SystemAudioManager
    var isDisabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("対象アプリ", selection: choiceBinding) {
                    ForEach(makeChoices(from: manager.availableApps), id: \.choice) { label in
                        Text(label.displayName).tag(label.choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180, maxWidth: 240)
                .disabled(isDisabled || manager.isRefreshing)

                Button {
                    Task { await manager.refreshAvailableApps() }
                } label: {
                    if manager.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isDisabled || manager.isRefreshing)
                .help("対象アプリ一覧を更新")
            }

            if let kind = manager.lastErrorKind, kind != .captureFailed,
               let message = manager.errorMessage {
                errorView(kind: kind, message: message)
            }
        }
        .task {
            guard manager.availableApps.isEmpty, manager.lastErrorKind == nil else { return }
            await manager.refreshAvailableApps()
        }
    }

    private var choiceBinding: Binding<AppChoice> {
        Binding(
            get: {
                if let app = manager.selectedApp {
                    return .app(processID: app.processID)
                }
                return .wholeDisplay
            },
            set: { newValue in
                switch newValue {
                case .wholeDisplay:
                    manager.selectedApp = nil
                case .app(let pid):
                    manager.selectedApp = manager.availableApps.first { $0.processID == pid }
                }
            }
        )
    }

    @ViewBuilder
    private func errorView(kind: SystemAudioErrorKind, message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            if kind == .permissionDenied {
                Button("システム設定を開く") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

#Preview {
    SystemAudioAppPicker(manager: SystemAudioManager())
        .padding()
}
