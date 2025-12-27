import SwiftUI

struct ContentView: View {
    @State private var transcriptionManager = TranscriptionManager()
    @State private var iptalkManager = IPtalkManager()
    @State private var showIPtalkPanel = false
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TranscriptView(transcriptionManager: transcriptionManager)
                Divider()
                ControlPanel(
                    transcriptionManager: transcriptionManager,
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
        .onChange(of: transcriptionManager.transcribedText) { _, newValue in
            if iptalkManager.isConnected && !newValue.isEmpty {
                // Auto-send to IPtalk when text changes (optional)
            }
        }
    }
}

#Preview {
    ContentView()
}
