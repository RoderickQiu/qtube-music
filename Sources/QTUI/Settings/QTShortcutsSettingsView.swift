import QTCore
import SwiftUI

// Owner: builder "desktop". Settings › Shortcuts: a shortcut field per global action, with what gets in its way
// underneath (another app has it, macOS uses it, an installed launcher's default, our own menus). None is set until
// the user records one or picks the suggested set.

struct QTShortcutsSettingsPane: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let store = model.settings
        let suggested = QTKeyboardLayout.shared.suggested()
        Form {
            Section {
                ForEach(QTGlobalHotKeyAction.allCases, id: \.self) { action in
                    QTShortcutRow(action: action)
                }
            } footer: {
                HStack(alignment: .top, spacing: QTTheme.Spacing.l) {
                    Text(QTLoc.tr("These work in any app, even with QTube Music in the background. Media keys and the Shortcuts app control playback without them.", table: .desktop))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(QTLoc.tr("Use Suggested Shortcuts", table: .desktop)) {
                        store.update { $0.globalHotKeys.applySuggested(suggested) }
                    }
                    .disabled(!store.settings.globalHotKeys.canApplySuggested(suggested))
                    .help(QTLoc.tr("Fills in the empty ones with ⌃⌥⌘ shortcuts", table: .desktop))
                    .accessibilityIdentifier("qt.settings.shortcuts.suggested")
                }
                .padding(.leading, 10)
            }
        }
        .formStyle(.grouped)
        .onAppear { QTGlobalHotKeys.shared.refreshEnvironment() }
    }
}

private struct QTShortcutRow: View {
    let action: QTGlobalHotKeyAction
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let store = model.settings
        let combo = store.settings.globalHotKeys[action]
        let title = QTGlobalHotKeys.title(for: action)
        LabeledContent {
            QTShortcutRecorder(title: title, combo: combo, display: combo.map(QTKeyboardLayout.shared.display)) { new in
                store.update { $0.globalHotKeys[action] = new }
            }
            .frame(width: QTShortcutRecorderField.width, height: 22)
            .alignmentGuide(.firstTextBaseline) { _ in QTShortcutRecorderField.baselineFromTop }
            .alignmentGuide(.lastTextBaseline) { _ in QTShortcutRecorderField.baselineFromTop }
            .accessibilityIdentifier("qt.settings.shortcuts.\(action.rawValue)")
        } label: {
            Text(title)
            if let conflict = QTGlobalHotKeys.shared.conflict(for: action) {
                Text("\(Image(systemName: "exclamationmark.triangle.fill").renderingMode(.original)) \(conflict.message)")
            }
        }
    }
}
