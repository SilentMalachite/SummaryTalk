import SwiftUI

struct TranscriptView: View {
    @Bindable var transcriptionManager: TranscriptionManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("文字起こし")
                    .font(.headline)
                
                Spacer()
                
                if transcriptionManager.isRecording {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("録音中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top)
            
            TextEditor(text: $transcriptionManager.transcribedText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal)
                .padding(.bottom)
            
            if let error = transcriptionManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }
}

#Preview {
    TranscriptView(transcriptionManager: TranscriptionManager())
        .frame(width: 600, height: 400)
}
