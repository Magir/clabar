import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageService
    @ObservedObject var notifier: Notifier
    @ObservedObject var updater: AppUpdater
    @ObservedObject private var lang = LangObserver.shared

    @AppStorage(SettingsKeys.iconShowBars) private var showBars = true
    @AppStorage(SettingsKeys.iconShowUnread) private var showUnread = true
    @AppStorage(SettingsKeys.iconShowPct("five_hour")) private var pct5h = false
    @AppStorage(SettingsKeys.iconShowPct("seven_day")) private var pct7d = false
    @AppStorage(SettingsKeys.iconShowPct("fable")) private var pctFable = false
    @AppStorage(SettingsKeys.nudgeEnabled) private var nudgeEnabled = true
    @AppStorage(SettingsKeys.nudgeThresholdPct) private var nudgeThreshold = 50
    @AppStorage(SettingsKeys.nudgeWindowHours) private var nudgeWindow = 24
    @AppStorage(SettingsKeys.lowWarnEnabled) private var lowWarnEnabled = true
    @AppStorage(SettingsKeys.lowWarnThresholdPct) private var lowWarnThreshold = 85
    @AppStorage(SettingsKeys.serverPort) private var serverPort = Int(HookInstaller.defaultPort)
    @AppStorage(SessionFocus.keystrokesDefaultsKey) private var sendKeystrokes = false
    @AppStorage(Notifier.soundDefaultsKey) private var sound = true
    @AppStorage("\(Notifier.bannersForKindKey).ask") private var bannersAsk = true
    @AppStorage("\(Notifier.bannersForKindKey).done") private var bannersDone = true
    @AppStorage("\(Notifier.bannersForKindKey).error") private var bannersError = true
    @AppStorage("\(Notifier.bannersForKindKey).info") private var bannersInfo = false

    @State private var devcontainerMessage: String?
    @State private var showSnippet = false

    init(model: AppModel) {
        self.model = model
        self.usage = model.usage
        self.notifier = model.notifier
        self.updater = model.updater
    }

    var body: some View {
        Form {
            Section(L("Язык / Language", "Language / Язык")) {
                Picker(L("Язык интерфейса", "Interface language"), selection: $lang.language) {
                    Text(L("Авто (как в системе)", "Auto (system)")).tag(AppLanguage.auto)
                    Text("Русский").tag(AppLanguage.ru)
                    Text("English").tag(AppLanguage.en)
                }
            }

            Section(L("Иконка в меню-баре", "Menu bar icon")) {
                Toggle(L("Мини-полоски использования", "Mini usage bars"), isOn: $showBars)
                Toggle(L("Счётчик непрочитанных уведомлений", "Unread notifications counter"), isOn: $showUnread)
                Text(L("Проценты текстом:", "Percentages as text:"))
                Toggle(L("5 часов", "5-hour"), isOn: $pct5h)
                Toggle(L("Неделя", "Weekly"), isOn: $pct7d)
                Toggle(L("Fable (и полоска в иконке)", "Fable (adds an icon bar too)"), isOn: $pctFable)
            }

            Section(L("Уведомления", "Notifications")) {
                notificationStatusRow
                Toggle(L("Звук для запросов", "Sound for asks"), isOn: $sound)
                Toggle(L("Баннеры: запросы", "Banners: asks"), isOn: $bannersAsk)
                Toggle(L("Баннеры: завершение работы", "Banners: task completion"), isOn: $bannersDone)
                Toggle(L("Баннеры: сбои", "Banners: failures"), isOn: $bannersError)
                Toggle(L("Баннеры: прочее", "Banners: other"), isOn: $bannersInfo)
                Toggle(L("Отвечать на запросы клавишами (⏎/⎋, экспериментально)",
                         "Answer prompts with keystrokes (⏎/⎋, experimental)"), isOn: $sendKeystrokes)
                if sendKeystrokes {
                    Text(L("Нажатие уйдёт в активное окно после фокусировки сессии. Нужно разрешение «Универсальный доступ» (Accessibility) для Clabar.",
                           "The keystroke goes to the active window after focusing the session. Clabar needs the Accessibility permission."))
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section(L("Напоминание «сожги лимит»", "“Burn the limit” reminder")) {
                Toggle(L("Подсвечивать, когда недельный лимит пропадает", "Highlight when the weekly limit is about to expire unused"), isOn: $nudgeEnabled)
                if nudgeEnabled {
                    Stepper(L("Если использовано меньше \(nudgeThreshold)%", "If less than \(nudgeThreshold)% used"),
                            value: $nudgeThreshold, in: 5...95, step: 5)
                    Stepper(L("и до сброса меньше \(nudgeWindow) ч", "and reset is under \(nudgeWindow) h away"),
                            value: $nudgeWindow, in: 3...48, step: 3)
                }
            }

            Section(L("Предупреждение «лимит кончается»", "“Running low” warning")) {
                Toggle(L("Подсвечивать, когда лимит почти исчерпан", "Highlight when a limit is almost used up"), isOn: $lowWarnEnabled)
                if lowWarnEnabled {
                    Stepper(L("Если использовано больше \(lowWarnThreshold)%", "If more than \(lowWarnThreshold)% used"),
                            value: $lowWarnThreshold, in: 50...95, step: 5)
                }
            }

            Section(L("Интеграция с Claude Code", "Claude Code integration")) {
                LabeledContent(L("Хуки", "Hooks")) {
                    HStack {
                        Image(systemName: model.hooksInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(model.hooksInstalled ? .green : .red)
                        Text(model.hooksInstalled ? L("установлены", "installed") : L("не установлены", "not installed"))
                        Button(model.hooksInstalled ? L("Переустановить", "Reinstall") : L("Установить", "Install")) {
                            model.installHooks()
                        }
                    }
                }
                Text(L("Скрипт: ~/.claude/hooks/clabar-hook.sh, регистрация в ~/.claude/settings.json (бэкап: settings.json.clabar-backup).",
                       "Script: ~/.claude/hooks/clabar-hook.sh, registered in ~/.claude/settings.json (backup: settings.json.clabar-backup)."))
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent(L("Порт", "Port")) {
                    HStack {
                        TextField("", value: $serverPort, format: .number.grouping(.never))
                            .frame(width: 70)
                        Button(L("Применить", "Apply")) { model.applyPort() }
                    }
                }

                LabeledContent("DevContainer") {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack {
                            Button(L("Настроить проект…", "Set up a project…")) { pickDevcontainerProject() }
                            Button(L("Показать сниппет", "Show snippet")) { showSnippet = true }
                        }
                        if let devcontainerMessage {
                            Text(devcontainerMessage)
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: 260, alignment: .trailing)
                        }
                    }
                }
            }

            Section(L("Аккаунт", "Account")) {
                LabeledContent(L("Пользователь", "User"), value: usage.accountEmail ?? "—")
                Picker(L("Опрос лимитов", "Usage polling"), selection: Binding(
                    get: { usage.pollingMinutes },
                    set: { usage.updatePollingInterval($0) }
                )) {
                    ForEach(UsageService.pollingOptions, id: \.self) { minutes in
                        Text(L("\(minutes) мин", "\(minutes) min")).tag(minutes)
                    }
                }
                if usage.isAuthenticated {
                    Button(L("Выйти из аккаунта", "Sign out"), role: .destructive) { usage.signOut() }
                }
            }

            Section(L("Обновления", "Updates")) {
                LabeledContent(L("Версия", "Version"), value: updater.version)
                if updater.isConfigured {
                    Button(L("Проверить обновления…", "Check for updates…")) { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                } else {
                    Text(L("Локальная сборка — автообновления выключены. Релизы: GitHub.",
                           "Local build — auto-updates disabled. Releases: GitHub."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button(L("Завершить Clabar", "Quit Clabar")) { NSApplication.shared.terminate(nil) }
            }
        }
        .onAppear { notifier.refreshAuthorizationStatus() }
        .formStyle(.grouped)
        .frame(width: 460, height: 660)
        .environment(\.locale, Lang.locale)
        .sheet(isPresented: $showSnippet) { snippetSheet }
        .onAppear { DockPolicy.windowShown() }
        .onDisappear { DockPolicy.windowHidden() }
    }

    @ViewBuilder
    private var notificationStatusRow: some View {
        LabeledContent(L("Системные уведомления", "System notifications")) {
            HStack {
                switch notifier.authorizationStatus {
                case .authorized, .provisional:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L("включены", "enabled"))
                case .denied:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(L("выключены", "disabled"))
                    Button(L("Открыть настройки macOS", "Open macOS settings")) {
                        openNotificationSystemSettings()
                    }
                case .notDetermined:
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                    Text(L("не запрошены", "not requested"))
                default:
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    Text("—")
                }
            }
        }
    }

    private func openNotificationSystemSettings() {
        // Deep link to this app's notification pane; falls back to the list.
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)")
            ?? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    private var snippetSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Добавьте в devcontainer.json:", "Add to devcontainer.json:")).font(.headline)
            ScrollView(.horizontal) {
                Text(HookInstaller.devcontainerSnippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text(L("Монтирует ~/.claude в контейнер (настройки, хуки и логин Claude едут туда и обратно) и направляет уведомления на хост через host.docker.internal.",
                   "Mounts ~/.claude into the container (Claude settings, hooks and login travel both ways) and routes notifications to the host via host.docker.internal."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Скопировать", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HookInstaller.devcontainerSnippet, forType: .string)
                }
                Spacer()
                Button(L("Закрыть", "Close")) { showSnippet = false }
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func pickDevcontainerProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json, .folder]
        panel.message = L("Выберите папку проекта или сам devcontainer.json",
                          "Pick the project folder or the devcontainer.json itself")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let file: URL?
        let projectURL: URL
        if url.hasDirectoryPath {
            projectURL = url
            file = HookInstaller.devcontainerFile(inProject: url)
        } else {
            file = url
            var dir = url.deletingLastPathComponent()
            if dir.lastPathComponent == ".devcontainer" { dir.deleteLastPathComponent() }
            projectURL = dir
        }
        guard let file else {
            devcontainerMessage = L("devcontainer.json не найден в проекте", "No devcontainer.json found in the project")
            return
        }
        do {
            let port = UInt16(clamping: serverPort)
            switch try HookInstaller.patchDevcontainer(file: file, projectURL: projectURL, port: port) {
            case .patched:
                devcontainerMessage = L("Готово: \(file.lastPathComponent) обновлён (бэкап рядом). Пересоберите контейнер.",
                                        "Done: \(file.lastPathComponent) updated (backup next to it). Rebuild the container.")
            case .alreadyPatched:
                devcontainerMessage = L("Уже настроено.", "Already set up.")
            case .patchedExistingConfig(let hooksInstalledAt):
                if let hooksInstalledAt {
                    devcontainerMessage = L("У проекта свой CLAUDE_CONFIG_DIR — оставлен как есть, хуки Clabar установлены в \(hooksInstalledAt). Пересоберите контейнер.",
                                            "Project has its own CLAUDE_CONFIG_DIR — kept as is; Clabar hooks installed into \(hooksInstalledAt). Rebuild the container.")
                } else {
                    devcontainerMessage = L("У проекта свой CLAUDE_CONFIG_DIR, но его хостовый путь не разрешился. Добавлен только CLABAR_HOST; поставьте хуки в тот конфиг кнопкой «Установить», указав его через CLAUDE_CONFIG_DIR, или вручную.",
                                            "Project has its own CLAUDE_CONFIG_DIR but its host path couldn't be resolved. Only CLABAR_HOST was added; install hooks into that config manually.")
                }
            case .needsManualEdit:
                devcontainerMessage = L("В файле комментарии — вставьте сниппет вручную.",
                                        "The file has comments — paste the snippet manually.")
                showSnippet = true
            }
        } catch {
            devcontainerMessage = L("Ошибка: ", "Error: ") + error.localizedDescription
        }
    }
}
