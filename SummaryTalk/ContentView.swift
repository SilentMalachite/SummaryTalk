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
    }
}

#Preview {
    ContentView()
}
