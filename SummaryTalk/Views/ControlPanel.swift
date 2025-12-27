import SwiftUI

struct ControlPanel: View {
    @Bindable var transcriptionManager: TranscriptionManager
    @Binding var showIPtalkPanel: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            Picker("音声ソース", selection: $transcriptionManager.audioSource) {
                ForEach(AudioSource.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)
            .disabled(transcriptionManager.isRecording)
            
            Button {
                Task {
                    if transcriptionManager.isRecording {
                        transcriptionManager.stopRecording()
                    } else {
                        await transcriptionManager.startRecording()
                    }
                }
            } label: {
                Label(
                    transcriptionManager.isRecording ? "停止" : "録音開始",
                    systemImage: transcriptionManager.isRecording ? "stop.fill" : (transcriptionManager.audioSource == .microphone ? "mic.fill" : "speaker.wave.2.fill")
                )
                .frame(minWidth: 100)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(transcriptionManager.isRecording ? .red : .accentColor)
            
            Button {
                transcriptionManager.clearText()
            } label: {
                Label("クリア", systemImage: "trash")
            }
            .controlSize(.large)
            .disabled(transcriptionManager.transcribedText.isEmpty)
            
            Divider()
                .frame(height: 24)
            
            Button {
                withAnimation {
                    showIPtalkPanel.toggle()
                }
            } label: {
                Label("IPtalk", systemImage: "network")
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(showIPtalkPanel ? .blue : nil)
            
            Spacer()
            
            Text("\(transcriptionManager.transcribedText.count) 文字")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Button {
                Task {
                    await transcriptionManager.saveToFile()
                }
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .controlSize(.large)
            .disabled(transcriptionManager.transcribedText.isEmpty)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#Preview {
    ControlPanel(
        transcriptionManager: TranscriptionManager(),
        showIPtalkPanel: .constant(false)
    )
    .frame(width: 600)
}
