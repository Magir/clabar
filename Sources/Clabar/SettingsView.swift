import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageService

    @AppStorage(SettingsKeys.iconShowBars) private var showBars = true
    @AppStorage(SettingsKeys.iconShowUnread) private var showUnread = true
    @AppStorage(SettingsKeys.iconShowPct("five_hour")) private var pct5h = false
    @AppStorage(SettingsKeys.iconShowPct("seven_day")) private var pct7d = false
    @AppStorage(SettingsKeys.iconShowPct("fable")) private var pctFable = false
    @AppStorage(SettingsKeys.nudgeEnabled) private var nudgeEnabled = true
    @AppStorage(SettingsKeys.nudgeThresholdPct) private var nudgeThreshold = 50
    @AppStorage(SettingsKeys.nudgeWindowHours) private var nudgeWindow = 24
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
    }

    var body: some View {
        Form {
            Section("Иконка в меню-баре") {
                Toggle("Мини-полоски использования", isOn: $showBars)
                Toggle("Счётчик непрочитанных уведомлений", isOn: $showUnread)
                Text("Проценты текстом:")
                Toggle("5 часов", isOn: $pct5h)
                Toggle("Неделя", isOn: $pct7d)
                Toggle("Fable (и полоска в иконке)", isOn: $pctFable)
            }

            Section("Уведомления") {
                Toggle("Звук для запросов", isOn: $sound)
                Toggle("Баннеры: запросы", isOn: $bannersAsk)
                Toggle("Баннеры: завершение работы", isOn: $bannersDone)
                Toggle("Баннеры: сбои", isOn: $bannersError)
                Toggle("Баннеры: прочее", isOn: $bannersInfo)
                Toggle("Отвечать на запросы клавишами (⏎/⎋, экспериментально)", isOn: $sendKeystrokes)
                if sendKeystrokes {
                    Text("Нажатие уйдёт в активное окно после фокусировки сессии. Нужно разрешение «Универсальный доступ» (Accessibility) для Clabar.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Напоминание «сожги лимит»") {
                Toggle("Подсвечивать, когда лимит пропадает", isOn: $nudgeEnabled)
                if nudgeEnabled {
                    Stepper("Если использовано меньше \(nudgeThreshold)%", value: $nudgeThreshold, in: 5...95, step: 5)
                    Stepper("и до сброса меньше \(nudgeWindow) ч", value: $nudgeWindow, in: 3...48, step: 3)
                }
            }

            Section("Интеграция с Claude Code") {
                LabeledContent("Хуки") {
                    HStack {
                        Image(systemName: model.hooksInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(model.hooksInstalled ? .green : .red)
                        Text(model.hooksInstalled ? "установлены" : "не установлены")
                        Button(model.hooksInstalled ? "Переустановить" : "Установить") {
                            model.installHooks()
                        }
                    }
                }
                Text("Скрипт: ~/.claude/hooks/clabar-hook.sh, регистрация в ~/.claude/settings.json (бэкап: settings.json.clabar-backup).")
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Порт") {
                    HStack {
                        TextField("", value: $serverPort, format: .number.grouping(.never))
                            .frame(width: 70)
                        Button("Применить") { model.applyPort() }
                    }
                }

                LabeledContent("DevContainer") {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack {
                            Button("Настроить проект…") { pickDevcontainerProject() }
                            Button("Показать сниппет") { showSnippet = true }
                        }
                        if let devcontainerMessage {
                            Text(devcontainerMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Аккаунт") {
                LabeledContent("Пользователь", value: usage.accountEmail ?? "—")
                Picker("Опрос лимитов", selection: Binding(
                    get: { usage.pollingMinutes },
                    set: { usage.updatePollingInterval($0) }
                )) {
                    ForEach(UsageService.pollingOptions, id: \.self) { minutes in
                        Text("\(minutes) мин").tag(minutes)
                    }
                }
                if usage.isAuthenticated {
                    Button("Выйти из аккаунта", role: .destructive) { usage.signOut() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .sheet(isPresented: $showSnippet) { snippetSheet }
    }

    private var snippetSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Добавьте в devcontainer.json:").font(.headline)
            ScrollView(.horizontal) {
                Text(HookInstaller.devcontainerSnippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text("Монтирует ~/.claude в контейнер (настройки, хуки и логин Claude едут туда и обратно) и направляет уведомления на хост через host.docker.internal.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HookInstaller.devcontainerSnippet, forType: .string)
                }
                Spacer()
                Button("Закрыть") { showSnippet = false }
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
        panel.message = "Выберите папку проекта или сам devcontainer.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let file: URL?
        if url.hasDirectoryPath {
            file = HookInstaller.devcontainerFile(inProject: url)
        } else {
            file = url
        }
        guard let file else {
            devcontainerMessage = "devcontainer.json не найден в проекте"
            return
        }
        do {
            switch try HookInstaller.patchDevcontainer(file: file) {
            case .patched:
                devcontainerMessage = "Готово: \(file.lastPathComponent) обновлён (бэкап рядом). Пересоберите контейнер."
            case .alreadyPatched:
                devcontainerMessage = "Уже настроено."
            case .needsManualEdit:
                devcontainerMessage = "В файле комментарии — вставьте сниппет вручную."
                showSnippet = true
            }
        } catch {
            devcontainerMessage = "Ошибка: \(error.localizedDescription)"
        }
    }
}
