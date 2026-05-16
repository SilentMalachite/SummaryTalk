import SwiftUI

struct IPtalkPanel: View {
    @Bindable var iptalkManager: IPtalkManager
    @Binding var textToSend: String

    @AppStorage("iptalkHandleName") private var handleName: String = ""
    @AppStorage("iptalkChannel") private var channel: Int = 1
    @AppStorage("iptalkAutoSend") private var autoSend: Bool = true

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
                Text("チャンネル:")
                    .foregroundStyle(.secondary)
                Picker("", selection: $channel) {
                    ForEach(1...9, id: \.self) { ch in
                        Text("\(ch)").tag(ch)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .disabled(iptalkManager.isConnected)

                Spacer()

                Button {
                    Task {
                        if iptalkManager.isConnected {
                            iptalkManager.stopListening()
                        } else {
                            iptalkManager.channel = channel
                            iptalkManager.handleName = resolvedHandleName
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

            HStack {
                Text("ハンドル名:")
                    .foregroundStyle(.secondary)
                TextField("自動 (\(autoHandleName))", text: $handleName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(iptalkManager.isConnected)
            }

            Toggle("認識結果を自動送信", isOn: $autoSend)
                .toggleStyle(.switch)

            if !iptalkManager.members.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("メンバー一覧:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(iptalkManager.members) { member in
                        HStack {
                            Text(member.name)
                                .font(.caption.bold())
                            Text(member.ip)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                        iptalkManager.sendDisplayLine(textToSend)
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
    }

    private var autoHandleName: String {
        let host = ProcessInfo.processInfo.hostName
        return host.components(separatedBy: ".").first ?? "SummaryTalk"
    }

    private var resolvedHandleName: String {
        handleName.trimmingCharacters(in: .whitespaces).isEmpty ? autoHandleName : handleName
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
