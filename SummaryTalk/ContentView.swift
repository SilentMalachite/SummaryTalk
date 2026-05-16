import SwiftUI

struct ContentView: View {
    @State private var transcriptionManager = TranscriptionManager()
    @State private var systemAudioManager = SystemAudioManager()
    @State private var iptalkManager = IPtalkManager()
    @State private var showIPtalkPanel = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TranscriptView(transcriptionManager: transcriptionManager)
                Divider()
                ControlPanel(
                    transcriptionManager: transcriptionManager,
                    systemAudioManager: systemAudioManager,
                    showIPtalkPanel: $showIPtalkPanel
                )
            }

            if showIPtalkPanel {
                Divider()
                IPtalkPanel(
                    iptalkManager: iptalkManager,
                    textToSend: $transcriptionManager.transcribedText
                )
                .frame(width: 300)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            transcriptionManager.onFinalizedLine = { [weak iptalkManager] line in
                let autoSend = UserDefaults.standard.object(forKey: "iptalkAutoSend") as? Bool ?? true
                guard autoSend, let manager = iptalkManager, manager.isConnected else { return }
                manager.sendDisplayLine(line)
            }
        }
    }
}

#Preview {
    ContentView()
}
