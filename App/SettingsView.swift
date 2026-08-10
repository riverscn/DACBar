import SwiftUI

struct SettingsView: View {
    @Bindable var model: DeviceModel
    @Bindable var hotKeys: GlobalHotKeyController
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Bindable var updates: UpdateController

    var body: some View {
        TabView {
            GeneralSettingsView(
                launchAtLogin: launchAtLogin,
                updates: updates)
                .tabItem {
                    Label(
                        AppL10n.text("settings.general", defaultValue: "General"),
                        systemImage: "gearshape")
                }

            ShortcutSettingsView(model: model, hotKeys: hotKeys)
                .tabItem {
                    Label(
                        AppL10n.text("settings.shortcuts", defaultValue: "Shortcuts"),
                        systemImage: "keyboard")
                }
        }
        .frame(
            minWidth: 460,
            idealWidth: 560,
            maxWidth: .infinity,
            minHeight: 340,
            idealHeight: 400,
            maxHeight: .infinity)
        .scenePadding()
    }
}

private struct GeneralSettingsView: View {
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Bindable var updates: UpdateController

    var body: some View {
        Form {
            Section(AppL10n.text("settings.startup", defaultValue: "Startup")) {
                Toggle(
                    AppL10n.text(
                        "settings.launch-at-login", defaultValue: "Launch DACBar at Login"),
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }))

                if launchAtLogin.state == .requiresApproval {
                    HStack {
                        Text(AppL10n.text(
                            "settings.login-approval",
                            defaultValue: "Allow DACBar in System Settings to finish enabling it."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(AppL10n.text(
                            "settings.open-login-items", defaultValue: "Open Login Items…")) {
                            launchAtLogin.openSystemSettings()
                        }
                    }
                }

                if let error = launchAtLogin.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section(AppL10n.text("settings.updates", defaultValue: "Updates")) {
                Toggle(
                    AppL10n.text(
                        "settings.automatic-checks", defaultValue: "Automatically Check for Updates"),
                    isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }))
                    .disabled(!updates.isConfigured)

                Toggle(
                    AppL10n.text(
                        "settings.automatic-downloads", defaultValue: "Automatically Download Updates"),
                    isOn: Binding(
                        get: { updates.automaticallyDownloadsUpdates },
                        set: { updates.setAutomaticallyDownloadsUpdates($0) }))
                    .disabled(!updates.isConfigured || !updates.automaticallyChecksForUpdates)

                Button(AppL10n.text("update.check", defaultValue: "Check for Updates…")) {
                    updates.check()
                }
                .disabled(!updates.canCheckForUpdates)
            }

            Section(AppL10n.text("settings.about", defaultValue: "About")) {
                LabeledContent(
                    AppL10n.text("settings.version", defaultValue: "Version"),
                    value: versionDescription)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

private struct ShortcutSettingsView: View {
    @Bindable var model: DeviceModel
    @Bindable var hotKeys: GlobalHotKeyController

    var body: some View {
        Form {
            Section {
                Toggle(
                    AppL10n.text(
                        "settings.enable-shortcuts", defaultValue: "Enable Global Shortcuts"),
                    isOn: Binding(
                        get: { hotKeys.isEnabled },
                        set: { hotKeys.setEnabled($0) }))
            } footer: {
                Text(AppL10n.text(
                    "settings.shortcuts-note",
                    defaultValue: "Shortcuts control the DAC selected in DACBar, including when an audio player uses it in exclusive mode."))
            }

            Section(AppL10n.text("settings.volume", defaultValue: "Volume")) {
                LabeledContent(AppL10n.text(
                    "settings.volume-up", defaultValue: "Increase Volume")) {
                    HotKeyRecorder(shortcut: Binding(
                        get: { hotKeys.volumeUp },
                        set: { hotKeys.setShortcut($0, for: .increase) }))
                }
                LabeledContent(AppL10n.text(
                    "settings.volume-down", defaultValue: "Decrease Volume")) {
                    HotKeyRecorder(shortcut: Binding(
                        get: { hotKeys.volumeDown },
                        set: { hotKeys.setShortcut($0, for: .decrease) }))
                }

                HStack {
                    Spacer()
                    Button(AppL10n.text(
                        "settings.restore-shortcuts", defaultValue: "Restore Defaults")) {
                        hotKeys.restoreDefaults()
                    }
                }
            }

            Section(AppL10n.text("settings.shortcut-status", defaultValue: "Status")) {
                LabeledContent(
                    AppL10n.text("settings.shortcut-target", defaultValue: "Target DAC"),
                    value: targetDescription)
                LabeledContent(
                    AppL10n.text("settings.registration", defaultValue: "Registration"),
                    value: registrationDescription)
            }
        }
        .formStyle(.grouped)
    }

    private var targetDescription: String {
        guard let selected = model.selected else {
            return AppL10n.text("settings.no-target", defaultValue: "No Device Selected")
        }
        guard model.isReady else {
            return AppL10n.format(
                "settings.target-unavailable",
                defaultValue: "%@ (Unavailable)",
                selected.disambiguatedName)
        }
        return selected.disambiguatedName
    }

    private var registrationDescription: String {
        switch hotKeys.status {
        case .disabled:
            return AppL10n.text("settings.shortcut-disabled", defaultValue: "Disabled")
        case .registered:
            return AppL10n.text("settings.shortcut-active", defaultValue: "Active")
        case .duplicate:
            return AppL10n.text(
                "settings.shortcut-duplicate",
                defaultValue: "Choose Two Different Shortcuts")
        case .failed:
            return AppL10n.text(
                "settings.shortcut-conflict",
                defaultValue: "Unavailable or Used by Another App")
        }
    }
}
