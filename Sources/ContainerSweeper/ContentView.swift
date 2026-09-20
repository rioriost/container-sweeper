import SweeperCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var confirmation: Confirmation?

    private enum Confirmation: String, Identifiable {
        case save, run, remove
        var id: String { rawValue }
    }

    private var l: Localizer { model.localizer }
    private func t(_ key: String) -> String { l.text(key) }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $model.selection) {
                    ForEach(model.configuration.profiles) { profile in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(l.profileName(profile)).font(.headline)
                            Text(l.schedule(profile)).font(.caption).foregroundStyle(.secondary)
                            Label(t(profile.enabled ? "enabled" : "disabled"),
                                  systemImage: profile.enabled ? "clock.badge.checkmark" : "pause.circle")
                                .font(.caption)
                        }
                        .padding(.vertical, 6)
                        .tag(profile.id)
                    }
                }
                HStack {
                    Button(action: model.addProfile) { Label(t("add"), systemImage: "plus") }
                        .disabled(model.configuration.profiles.count >= 32)
                    Spacer()
                    Button(role: .destructive) { confirmation = .remove } label: {
                        Image(systemName: "minus")
                    }
                    .help(t("remove"))
                    .accessibilityLabel(t("remove"))
                    .disabled(model.selection == nil)
                }
                .padding()
                Text(t("sidebarHint")).font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom])
            }
            .navigationTitle(t("profiles"))
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                Form {
                    if let index = model.configuration.profiles.firstIndex(where: { $0.id == model.selection }) {
                        ProfileEditor(profile: $model.configuration.profiles[index], localizer: l)
                        Section(t("preview")) {
                            Text(model.configuration.profiles[index].commandPreview.joined(separator: "\n"))
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Text(t("orderHint")).font(.caption).foregroundStyle(.secondary)
                        }
                        if model.configuration.profiles[index].enabled { groupedPreview }
                    } else {
                        Section { Text(t("selectProfile")).foregroundStyle(.secondary) }
                    }
                    Section(t("cli")) {
                        HStack {
                            TextField(t("executable"), text: $model.configuration.containerPath)
                                .textFieldStyle(.roundedBorder)
                            Button(t("browse"), action: model.browse)
                        }
                        HStack {
                            Button(t("checkCLI"), action: model.checkCLI).disabled(model.selection == nil)
                            Text(t("cliHint")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Text(t("launchdHint")).font(.caption).foregroundStyle(.secondary)
                        Text(t("safetyHint")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                Divider()
                footer
            }
        }
        .frame(minWidth: 900, minHeight: 740)
        .disabled(model.busy || model.loadFailed)
        .alert(t("errorTitle"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(t("close"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(t(model.loadFailed ? "loadErrorHint" : "errorHint") + "\n\n" + (model.errorMessage ?? ""))
        }
        .sheet(item: $confirmation) { value in
            confirmationSheet(value)
        }
        .sheet(isPresented: Binding(
            get: { model.output != nil },
            set: { if !$0 { model.output = nil } }
        )) {
            VStack(alignment: .leading, spacing: 16) {
                Text(t("details")).font(.title2)
                ScrollView {
                    Text(model.output ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(t("openLogs"), action: model.openLogs)
                    Spacer()
                    Button(t("close")) { model.output = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 720, height: 480)
        }
    }

    @ViewBuilder
    private var groupedPreview: some View {
        switch Result(catching: {
            try ScheduleGroup.compile(model.configuration).filter { group in
                group.profiles.contains { $0.id == model.selection }
            }
        }) {
        case .success(let groups):
            if groups.contains(where: { $0.profiles.count > 1 }) {
                Section(t("mergedPreview")) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(l.schedule(group)).font(.headline)
                            Text(group.profiles.map { l.profileName($0) }.joined(separator: " + "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(group.mergedProfile.commandPreview.joined(separator: "\n"))
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    Text(t("mergedHint")).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failure(let error):
            Section(t("mergedPreview")) {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(t(model.statusKey)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(t(model.dirty ? "unsaved" : "upToDate"))
                    .font(.caption).foregroundStyle(model.dirty ? Color.orange : Color.secondary)
            }
            HStack {
                Button(t("showLog")) {
                    if let id = model.selection { model.showLog(id: id) }
                }.disabled(model.selection == nil)
                Button(t("scheduleStatus"), action: model.showScheduleStatus).disabled(model.selection == nil)
                Spacer()
                Button(t("runNow")) { confirmation = .run }.disabled(model.selection == nil)
                Button(t("save")) {
                    if model.configuration.profiles.contains(where: { $0.enabled && $0.isDestructive }) {
                        confirmation = .save
                    } else {
                        model.save()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding()
    }

    private func confirmationSheet(_ value: Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t(value == .remove ? "removeTitle" : "confirmTitle")).font(.title2.bold())
            Text(t(value == .save ? "saveConfirmation" : value == .run ? "runConfirmation" : "removeConfirmation"))
            if value != .remove {
                if value == .save {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.configuration.profiles.filter { $0.enabled && $0.isDestructive }) { profile in
                                Text(l.profileName(profile) + " — " + l.schedule(profile)).bold()
                                Text(profile.commandPreview.joined(separator: "\n"))
                                    .font(.system(.callout, design: .monospaced))
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                } else if let profile = model.selectedProfile {
                    Text(profile.commandPreview.joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                }
                if value == .save || model.selectedProfile?.isDestructive == true {
                    Text(t("destructiveWarning")).foregroundStyle(.orange)
                }
            }
            HStack {
                Spacer()
                Button(t("cancel")) { confirmation = nil }.keyboardShortcut(.cancelAction)
                Button(t(value == .save ? "save" : value == .run ? "runNow" : "remove")) {
                    confirmation = nil
                    switch value {
                    case .save: model.save()
                    case .run: model.runNow()
                    case .remove: model.removeSelectedProfile()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct ProfileEditor: View {
    @Binding var profile: CleanupProfile
    let localizer: Localizer
    private func t(_ key: String) -> String { localizer.text(key) }

    var body: some View {
        Section(t("schedule")) {
            TextField(t("profileName"), text: $profile.name, prompt: Text(localizer.profileName(profile)))
            Toggle(t("enableSchedule"), isOn: $profile.enabled)
            Picker(t("frequency"), selection: $profile.frequency) {
                Text(t("daily")).tag(Frequency.daily)
                Text(t("weekly")).tag(Frequency.weekly)
            }
            .pickerStyle(.segmented)
            if profile.frequency == .weekly {
                Picker(t("weekday"), selection: $profile.weekday) {
                    ForEach(0..<7) { day in Text(t("weekday\(day)")).tag(day) }
                }
            }
            HStack {
                Text(t("time"))
                Spacer()
                Picker(t("hour"), selection: $profile.hour) {
                    ForEach(0..<24) { hour in Text(String(format: "%02d", hour)).tag(hour) }
                }.frame(width: 120)
                Picker(t("minute"), selection: $profile.minute) {
                    ForEach(0..<60) { minute in Text(String(format: "%02d", minute)).tag(minute) }
                }.frame(width: 130)
            }
            Text(t("timeHint")).font(.caption).foregroundStyle(.secondary)
        }
        Section(t("actions")) {
            Toggle(t("clean"), isOn: $profile.clean)
            Text(t("cleanHint")).font(.caption).foregroundStyle(.secondary)
            Picker(t("imageCleanup"), selection: $profile.images) {
                Text(t("imageNone")).tag(ImageCleanup.none)
                Text(t("imageDangling")).tag(ImageCleanup.dangling)
                Text(t("imageAll")).tag(ImageCleanup.all)
            }
            Toggle(t("prune"), isOn: $profile.prune)
            if profile.isDestructive {
                Label(t("destructiveWarning"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !profile.hasActions {
                Text(t("noActions")).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
