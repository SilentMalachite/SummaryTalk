import SwiftUI

struct IPtalkPanel: View {
    @Bindable var iptalkManager: IPtalkManager
    @Binding var textToSend: String
    
    @State private var portText: String = "15000"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("IPtalk接続")
                    .font(.headline)
                
                Spacer()
                
                Circle()
                    .fill(iptalkManager.isConnected ? .green : .gray)
                    .frame(width: 10, height: 10)
                
                Text(iptalkManager.isConnected ? "接続中" : "未接続")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            HStack {
                Text("ポート:")
                    .foregroundStyle(.secondary)
                
                TextField("15000", text: $portText)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .disabled(iptalkManager.isConnected)
                
                Spacer()
                
                Button {
                    Task {
                        if iptalkManager.isConnected {
                            iptalkManager.stopListening()
                        } else {
                            guard let portValue = UInt16(portText), portValue > 0 else {
                                iptalkManager.errorMessage = "1〜65535のポート番号を入力してください"
                                return
                            }
                            iptalkManager.updatePort(portValue)
                            await iptalkManager.startListening()
                        }
                    }
                } label: {
                    Text(iptalkManager.isConnected ? "切断" : "接続")
                        .frame(width: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(iptalkManager.isConnected ? .red : .blue)
            }
            
            if !iptalkManager.connectedPartners.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("接続パートナー:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    ForEach(iptalkManager.connectedPartners, id: \.self) { partner in
                        Text(partner)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            
            if let error = iptalkManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            
            Divider()
            
            HStack {
                Button {
                    if !textToSend.isEmpty {
                        iptalkManager.sendText(textToSend)
                    }
                } label: {
                    Label("IPtalkに送信", systemImage: "paperplane.fill")
                }
                .disabled(!iptalkManager.isConnected || textToSend.isEmpty)
                
                Spacer()
                
                Button {
                    iptalkManager.clearReceivedText()
                } label: {
                    Label("受信クリア", systemImage: "trash")
                }
                .disabled(iptalkManager.receivedText.isEmpty)
            }
            
            if !iptalkManager.receivedText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("受信テキスト:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    ScrollView {
                        Text(iptalkManager.receivedText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            portText = String(iptalkManager.port)
        }
    }
}

#Preview {
    IPtalkPanel(
        iptalkManager: IPtalkManager(),
        textToSend: .constant("テストテキスト")
    )
    .frame(width: 400)
    .padding()
}
