import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var model: DeviceModel
    let updates: UpdateController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header

            content

            footer
        }
        // MenuBarExtra's window reuses whatever height it measured first, so the
        // stack has to hug its content and pin to the top; App.swift additionally
        // re-identifies the view per step to force a fresh measurement.
        .frame(width: PanelMetrics.panelWidth, alignment: .top)
        // MenuBarExtra resizes its window to fit, but only if the content
        // actually reports an intrinsic height. A greedy `maxHeight: .infinity`
        // here would make the view fill whatever the window already is, so it
        // could never shrink after a section is folded away.
        .fixedSize(horizontal: false, vertical: true)
        // No background and no container shape of our own: on macOS 26 the
        // system draws the panel's Liquid Glass and its 16pt corners below
        // SwiftUI. Anything we add here only occludes it.

    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .disconnected:
            noDevice
        case .connecting:
            message(icon: "cable.connector",
                    title: AppL10n.text("state.connecting.title", defaultValue: "Connecting"),
                    detail: AppL10n.text("state.connecting.detail", defaultValue: "Opening the device control channel…"))
        case .reading:
            message(icon: "arrow.clockwise",
                    title: AppL10n.text("state.reading.title", defaultValue: "Reading"),
                    detail: AppL10n.text("state.reading.detail", defaultValue: "Synchronizing device settings…"))
        case .ready:
            controls
        case .failed(let error):
            failure(message: error)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            // Template rendering discards the composed image's own greys so the
            // glyph picks up the accent colour, matching the lone symbol it
            // replaced.
            Image(nsImage: DeviceGlyph.header)
                .renderingMode(.template)
                .foregroundStyle(model.devicePresent ? AnyShapeStyle(.tint)
                                                     : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                deviceName
                if let sub = subtitle {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 8)

            if model.devicePresent {
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .disabled(model.phase == .reading || model.phase == .connecting)
                .help(AppL10n.text("action.refresh.help", defaultValue: "Read again"))
                .accessibilityLabel(AppL10n.text(
                    "action.refresh.accessibility", defaultValue: "Read device status again"))
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// Plain text for the usual single-dongle case; a picker only once there is
    /// actually something to choose between.
    @ViewBuilder
    private var deviceName: some View {
        if model.devices.count > 1 {
            // A stock pop-up button: this picks a value, and macOS draws that
            // with the up/down chevrons, as against the single downward one a
            // pull-down `Menu` gets. Borderless to match the filter and timeout
            // menus, which are pop-ups too.
            //
            // Its label always renders in the system control font — `.font()`
            // has no effect on it — so the single-device title below is matched
            // to *this* rather than the other way round.
            //
            // No `.fixedSize()`: it claims a width wide enough to truncate the
            // subtitle underneath.
            Picker(AppL10n.text("device.picker", defaultValue: "Device"), selection: Binding(
                get: { model.selected?.persistedSelection ?? "" },
                set: { identity in
                    guard let device = model.devices.first(where: {
                        $0.persistedSelection == identity
                    })
                    else { return }
                    model.select(device)
                })) {
                // Model name first: owning two different models is likelier than
                // owning the same one twice, and then the name is what
                // identifies them. The port disambiguates the case where it
                // cannot.
                ForEach(model.devices) { device in
                    Text(device.disambiguatedName).tag(device.persistedSelection)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .buttonStyle(.borderless)
            // Cancels the pop-up button's own leading padding, so its label
            // starts on the same line as the subtitle beneath it — and where the
            // plain title sits when only one device is attached.
            .padding(.leading, -4)
        } else {
            // Sized to match the picker's label, which always renders in the
            // system control font, so the title does not change when a second
            // device is plugged in.
            Text(model.selected?.name ?? AppL10n.text(
                "app.title", defaultValue: "DACBar"))
                .font(.title3)
        }
    }

    /// Reserved for failures.
    ///
    /// Everything else that used to sit under the title — progress, "即将自动应用",
    /// the firmware — now reads along the status line at the bottom, which is
    /// where a glance goes for state anyway and leaves the header as just the
    /// device.
    ///
    /// Errors stay here because the status line is a single truncating row next
    /// to the quit button: a message clipped halfway is worse than a second line
    /// in the header.
    private var subtitle: String? {
        if case .failed(let message) = model.phase { return message }
        if let selected = model.selected,
           case .experimental = selected.profile.verification {
            return AppL10n.text(
                "device.experimental", defaultValue: "This model has not been verified on hardware")
        }
        return nil
    }

    private var footer: some View {
        HStack(spacing: 4) {
            statusDot
            Text(statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                openSettings()
                // DACBar is an LSUIElement accessory app. Opening the scene is
                // not sufficient to bring its window above the active regular
                // app, so explicitly activate only for this user action.
                Task { @MainActor in
                    await Task.yield()
                    NSApp.activate()
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(AppL10n.text("settings.open", defaultValue: "Settings…"))
            .accessibilityLabel(AppL10n.text("settings.open", defaultValue: "Settings…"))
            if updates.isConfigured {
                Button {
                    updates.check()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .disabled(!updates.canCheckForUpdates)
                .help(AppL10n.text("update.check", defaultValue: "Check for Updates…"))
                .accessibilityLabel(AppL10n.text(
                    "update.check", defaultValue: "Check for Updates…"))
            }
            Button(AppL10n.text("action.quit", defaultValue: "Quit")) {
                NSApplication.shared.terminate(nil)
            }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        switch model.phase {
        case .connecting: return .blue
        case .reading: return .blue
        case .failed:  return .red
        case .ready:   return .green
        case .disconnected: return .secondary
        }
    }

    /// State, then the firmware once it is known.
    private var statusLine: String {
        guard model.phase == .ready, model.devicePresent,
              !model.confirmed.firmware.isEmpty else { return statusText }
        return AppL10n.format(
            "status.with-firmware",
            defaultValue: "%1$@ · Firmware %2$@",
            statusText, model.confirmed.firmware)
    }

    private var statusText: String {
        switch model.phase {
        case .connecting:
            return AppL10n.text("status.connecting", defaultValue: "Connecting")
        case .reading:
            return AppL10n.text("status.reading", defaultValue: "Reading")
        case .failed:
            return AppL10n.text("status.failed", defaultValue: "Error")
        case .ready:
            return AppL10n.text("status.ready", defaultValue: "Connected")
        case .disconnected:
            return AppL10n.text("status.disconnected", defaultValue: "Disconnected")
        }
    }

    // MARK: - Controls

    private var controls: some View {
        DeviceControlsView(
            settings: model.settings,
            value: { model.value(for: $0) },
            textValue: { model.textValue(for: $0) },
            onChange: { model.update($0, to: $1) })
    }

    // MARK: - States

    private var noDevice: some View {
        message(icon: "cable.connector.slash",
                title: AppL10n.text("state.no-device.title", defaultValue: "No Device Detected"),
                detail: AppL10n.text("state.no-device.detail", defaultValue: "Connect a supported DAC."))
    }

    private func failure(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(AppL10n.text("state.failure.title", defaultValue: "Unable to Control Device"))
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(AppL10n.text("action.retry", defaultValue: "Retry")) {
                model.refresh()
            }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title).font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
    }

    // MARK: - Setup
}
