import Foundation
import ScreenCaptureKit

protocol RunningApplicationLike {
    var processID: pid_t { get }
    var applicationName: String { get }
    var bundleIdentifier: String { get }
}

extension SCRunningApplication: RunningApplicationLike {}

enum AppChoice: Hashable {
    case wholeDisplay
    case app(processID: pid_t)
}

struct AppChoiceLabel: Hashable {
    let choice: AppChoice
    let displayName: String
}

func makeChoices(from apps: [RunningApplicationLike]) -> [AppChoiceLabel] {
    var labels: [AppChoiceLabel] = [
        AppChoiceLabel(choice: .wholeDisplay,
                       displayName: "ディスプレイ全体（すべてのシステム音声）")
    ]
    var seen = Set<pid_t>()
    for app in apps {
        guard !seen.contains(app.processID) else { continue }
        seen.insert(app.processID)

        let name: String
        if !app.applicationName.isEmpty {
            name = app.applicationName
        } else if !app.bundleIdentifier.isEmpty {
            name = app.bundleIdentifier
        } else {
            name = "不明なアプリ (PID \(app.processID))"
        }
        labels.append(AppChoiceLabel(choice: .app(processID: app.processID),
                                     displayName: name))
    }
    return labels
}
