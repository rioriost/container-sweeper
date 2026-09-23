import SweeperCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showCommands = false
    @State private var showCLI = false
    @State private var showHelp = false

    private var l: Localizer { model.localizer }
    private func t(_ key: String) -> String { l.text(key) }

    var body: some View {
        GeometryReader { geometry in
            // Bound both native split columns to the window, including short localized forms.
            NavigationSplitView {
                sidebar
                    .frame(height: geometry.size.height)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            } detail: {
                VStack(spacing: 0) {
                    if model.loadFailed {
                        ContentUnavailableView {
                            Label(t("loadErrorTitle"), systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(t("loadErrorHint"))
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    } else if let index = model.configuration.profiles.firstIndex(where: { $0.id == model.selection }) {
                        profileHeader(model.configuration.profiles[index])
                            .fixedSize(horizontal: false, vertical: true)
                        Form {
                            ProfileEditor(profile: $model.configuration.profiles[index], localizer: l)
                            if model.configuration.profiles[index].enabled { groupedPreview }
                            Section {
                                DisclosureGroup(t("preview"), isExpanded: $showCommands) {
                                    commandList(model.configuration.profiles[index])
                                    hint("orderHint")
                                }
                            }
                            connectionSection
                            Section {
                                DisclosureGroup(t("automationHelp"), isExpanded: $showHelp) {
                                    hint("launchdHint")
                                    hint("safetyHint")
                                }
                            }
                        }
                        .formStyle(.grouped)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .id(model.selection)
                        .disabled(!model.canEdit)
                    } else {
                        ContentUnavailableView {
                            Label(t(model.configuration.profiles.isEmpty ? "emptyTitle" : "profiles"), systemImage: "calendar.badge.clock")
                        } description: {
                            Text(t("selectProfile"))
                        } actions: {
                            Button(t("addProfile"), action: model.addProfile)
                                .disabled(!model.canEdit || model.configuration.profiles.count >= 32)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    }
                    Divider()
                    footer
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .frame(height: geometry.size.height)
                .navigationTitle(model.loadFailed ? t("loadErrorTitle") : model.selectedProfile.map(l.profileName) ?? t("profiles"))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 860, minHeight: 640)
        .toolbar {
            ToolbarItemGroup {
                Button(action: model.addProfile) { Label(t("addProfile"), systemImage: "plus") }
                    .help(t("addProfile"))
                    .disabled(!model.canEdit || model.configuration.profiles.count >= 32)
                Menu {
                    Button(t("showLog")) {
                        if let id = model.selection { model.showLog(id: id) }
                    }
                    Button(t("scheduleStatus"), action: model.showScheduleStatus)
                    Divider()
                    Button(t("removeProfile"), role: .destructive) { model.confirmation = .remove }
                } label: {
                    Label(t("profileActions"), systemImage: "ellipsis.circle")
                }
                .accessibilityLabel(t("profileActions"))
                .help(t("profileActions"))
                .disabled(!model.canEdit || model.selection == nil)
            }
        }
        .alert(t("errorTitle"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(t("close"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(t(model.loadFailed ? "loadErrorHint" : "errorHint") + "\n\n" + (model.errorMessage ?? ""))
        }
        .sheet(item: $model.confirmation) { confirmationSheet($0) }
        .sheet(isPresented: Binding(
            get: { model.output != nil },
            set: { if !$0 { model.output = nil } }
        )) {
            VStack(alignment: .leading, spacing: 16) {
                Text(t(model.outputTitleKey)).font(.title2.bold())
                ScrollView {
                    Text(model.output ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if model.outputTitleKey == "showLog" {
                        Button(t("openLogs"), action: model.openLogs)
                    }
                    Spacer()
                    Button(t("close")) { model.output = nil }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
            .frame(width: 660, height: 440)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $model.selection) {
                Section(t("profiles")) {
                    ForEach(model.loadFailed ? [] : model.configuration.profiles) { profile in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: profile.enabled ? "calendar" : "pause.circle")
                                .foregroundStyle(.tint)
                                .font(.title3)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(l.profileName(profile)).font(.headline).lineLimit(2)
                                Text(l.schedule(profile)).font(.subheadline)
                                Text(t(profile.enabled ? "enabled" : "disabled"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .tag(profile.id)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .disabled(!model.canEdit)
            Divider()
            Label(t("sidebarHint"), systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
    }

    private func profileHeader(_ profile: CleanupProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l.profileName(profile)).font(.title2.bold()).textSelection(.enabled)
            HStack(spacing: 16) {
                Label(t(profile.enabled ? "enabled" : "disabled"),
                      systemImage: profile.enabled ? "clock.badge.checkmark" : "pause.circle")
                if profile.enabled { Text(l.schedule(profile)).monospacedDigit() }
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var connectionSection: some View {
        Section {
            DisclosureGroup(t("cli"), isExpanded: $showCLI) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("executable")).font(.subheadline)
                    HStack {
                        TextField(t("executable"), text: $model.configuration.containerPath)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .accessibilityLabel(t("executable"))
                        Button(t("browse"), action: model.browse)
                    }
                }
                Button(t("checkCLI"), action: model.checkCLI)
                    .disabled(model.selectedProfile?.hasActions != true)
                hint("cliHint")
            }
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
                            Label(l.schedule(group), systemImage: "calendar.badge.clock").font(.headline)
                            Text(group.profiles.map { l.profileName($0) }.joined(separator: " + "))
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(l.actions(group.mergedProfile)).font(.subheadline)
                            DisclosureGroup(t("commands")) { commandList(group.mergedProfile) }
                        }
                        .padding(.vertical, 4)
                    }
                    hint("mergedHint")
                }
            }
        case .failure:
            Section(t("mergedPreview")) {
                Label(t("invalidProfiles"), systemImage: "exclamationmark.circle")
                    .font(.subheadline)
            }
        }
    }

    private func hint(_ key: String) -> some View {
        Text(t(key)).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func commandList(_ profile: CleanupProfile) -> some View {
        if profile.hasActions {
            Text(profile.commandPreview.joined(separator: "\n"))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Label(t("noActions"), systemImage: "exclamationmark.circle")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel(t(model.statusKey)) }
                Label(t(model.loadFailed ? "loadErrorTitle" : model.dirty ? "unsaved" : "upToDate"),
                      systemImage: model.loadFailed ? "exclamationmark.triangle" : model.dirty ? "pencil.circle" : "checkmark.circle")
                Spacer()
                if model.statusKey != "ready" {
                    Text(t(model.statusKey)).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            if !model.canSave && model.canEdit {
                Label(t("invalidProfiles"), systemImage: "exclamationmark.circle")
                    .font(.caption)
            }
            HStack {
                Button(t("showLog")) {
                    if let id = model.selection { model.showLog(id: id) }
                }.disabled(!model.canEdit || model.selection == nil)
                Spacer()
                Button(t("runNow"), action: model.requestRun).disabled(!model.canRun)
                Button(t("save"), action: model.requestSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave)
            }
        }
        .padding(16)
    }

    private func confirmationSheet(_ value: AppModel.Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t(value == .remove ? "removeTitle" : value == .save ? "saveTitle" : "runTitle"))
                .font(.title2.bold())
            Text(t(value == .save ? "saveConfirmation" : value == .run ? "runConfirmation" : "removeConfirmation"))
                .fixedSize(horizontal: false, vertical: true)
            if value == .save {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.configuration.profiles.filter { $0.enabled && $0.isDestructive }) { profile in
                            confirmationProfile(profile)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
            } else if let profile = model.selectedProfile {
                if value == .remove {
                    Text(l.profileName(profile)).font(.headline)
                } else {
                    confirmationProfile(profile)
                }
            }
            if value == .save || (value == .run && model.selectedProfile?.isDestructive == true) {
                Label(t("destructiveWarning"), systemImage: "exclamationmark.triangle")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(t("cancel")) { model.confirmation = nil }.keyboardShortcut(.cancelAction)
                Button(t(value == .save ? "save" : value == .run ? "runNow" : "removeProfile")) {
                    model.confirmation = nil
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

    private func confirmationProfile(_ profile: CleanupProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l.profileName(profile)).font(.headline)
            Text(l.actions(profile)).font(.subheadline)
            if model.confirmation == .save { Text(l.schedule(profile)).foregroundStyle(.secondary) }
            commandList(profile)
        }
    }
}

private struct ProfileEditor: View {
    @Binding var profile: CleanupProfile
    let localizer: Localizer
    private func t(_ key: String) -> String { localizer.text(key) }

    private var time: Binding<Date> {
        Binding(get: { ScheduleClock.date(hour: profile.hour, minute: profile.minute) }, set: {
            let components = ScheduleClock.components($0)
            profile.hour = components.hour
            profile.minute = components.minute
        })
    }

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
            DatePicker(t("time"), selection: time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
                .environment(\.timeZone, ScheduleClock.calendar.timeZone)
                .environment(\.calendar, ScheduleClock.calendar)
                .accessibilityValue(localizer.time(hour: profile.hour, minute: profile.minute))
            Text(t("timeHint")).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Section(t("actions")) {
            Toggle(isOn: $profile.clean) {
                Text(t("clean"))
                Text(t("cleanHint"))
            }
            .accessibilityLabel(t("clean"))
            .accessibilityHint(t("cleanHint"))
            Toggle(isOn: $profile.prune) {
                Text(t("prune"))
                Text(t("pruneHint"))
            }
            .accessibilityLabel(t("prune"))
            .accessibilityHint(t("pruneHint"))
            Picker(t("imageCleanup"), selection: $profile.images) {
                Text(t("imageNone")).tag(ImageCleanup.none)
                Text(t("imageDangling")).tag(ImageCleanup.dangling)
                Text(t("imageAll")).tag(ImageCleanup.all)
            }
            Text(t(profile.images == .all ? "imageAllHint" : profile.images == .dangling ? "imageDanglingHint" : "imageNoneHint"))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if profile.isDestructive {
                Label(t("destructiveWarning"), systemImage: "exclamationmark.triangle")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if !profile.hasActions {
                Label(t("noActions"), systemImage: "exclamationmark.circle")
                    .font(.subheadline)
            }
        }
    }
}
