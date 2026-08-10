import Foundation
import Observation
import OSLog
import DACDeviceKit

typealias DeviceDriver = DACDeviceKit.Driver

@MainActor
@Observable
final class DeviceModel {

    enum Phase: Equatable {
        case disconnected
        case connecting
        case reading
        case ready
        case failed(String)
    }

    private(set) var confirmed = DACDeviceKit.Snapshot()
    var draft = DACDeviceKit.Snapshot()
    private(set) var phase: Phase = .disconnected
    private(set) var devices: [AttachedDevice] = []
    private(set) var selected: AttachedDevice?
    private(set) var settings: [DACDeviceKit.SettingDescriptor] = []

    var devicePresent: Bool { selected != nil }
    var isReady: Bool { phase == .ready && driver != nil && draft.valid }

    private static let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier, category: "device-model")
    private static let selectionKey = "selectedDeviceIdentity"
    private static let legacySelectionKey = "selectedLocationID"

    @ObservationIgnored private let watcher: any DeviceWatching
    @ObservationIgnored private let driverFactory:
        (AttachedDevice) throws -> any DeviceDriver
    @ObservationIgnored private var driver: (any DeviceDriver)?
    @ObservationIgnored private var sent = DACDeviceKit.Snapshot()
    @ObservationIgnored private var pendingWrite: DACDeviceKit.Snapshot?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var retryAttempts: [DACDeviceKit.Mutation: Int] = [:]
    @ObservationIgnored private var changesDuringRefresh: [DACDeviceKit.Mutation] = []
    @ObservationIgnored private var watcherNeedsRestart = false
    @ObservationIgnored private var generation = 0

    init(
        watcher: any DeviceWatching = DeviceWatcher(),
        driverFactory: @escaping (AttachedDevice) throws -> any DeviceDriver = {
            try SupportedDevices.makeDriver(for: $0.device)
        }
    ) {
        self.watcher = watcher
        self.driverFactory = driverFactory

        // DACBAR_FORCE_STATUS lays out the panel without hardware.
        if let forced = ProcessInfo.processInfo.environment["DACBAR_FORCE_STATUS"] {
            applyMock(forced)
            return
        }

        watcher.onChange = { [weak self] devices in
            self?.devicesDidChange(to: devices)
        }
        watcher.onFailure = { [weak self] message in
            guard let self else { return }
            Self.logger.error("Device watcher failed: \(message)")
            self.watcherNeedsRestart = true
            self.refreshTask?.cancel()
            self.refreshTask = nil
            self.changesDuringRefresh.removeAll()
            self.phase = .failed(message)
        }
        do {
            try watcher.start()
            watcherNeedsRestart = false
            devicesDidChange(to: watcher.devices)
        } catch {
            Self.logger.error("Device watcher startup failed: \(error.localizedDescription)")
            watcherNeedsRestart = true
            phase = .failed(error.localizedDescription)
        }
    }

    isolated deinit {
        refreshTask?.cancel()
        writeTask?.cancel()
        driver?.close()
        watcher.stop()
    }

    private func applyMock(_ forced: String) {
        let profile = SupportedDevices.previewProfile
        let first = AttachedDevice(
            profile: profile,
            productID: profile.hidMatches[0].productID,
            locationID: 0x0110_0000,
            registryEntryID: 1,
            name: profile.displayName,
            portPath: "1-1")
        let second = AttachedDevice(
            profile: profile,
            productID: profile.hidMatches[0].productID,
            locationID: 0x0210_0000,
            registryEntryID: 2,
            name: profile.displayName,
            portPath: "2-1")
        devices = forced == "twoDevices" ? [first, second] : [first]
        selected = devices.first
        settings = SupportedDevices.previewSettings
        let mock = DACDeviceKit.Snapshot(
            valid: true,
            values: [
                .volume: 27,
                .gain: 0,
                .filter: 1,
                .balance: -3,
                .brightness: 6,
                .screenTimeout: 30,
                .orientation: 0,
                .screenOffset: 2,
            ],
            firmware: "01.00.00")
        confirmed = mock
        sent = mock
        draft = mock
        phase = .ready
    }

    // MARK: - Device presence

    private func devicesDidChange(to list: [AttachedDevice]) {
        devices = list.sorted { $0.locationID < $1.locationID }
        let previous = selected
        selected = resolveSelection(in: devices)

        guard let selected else {
            invalidateSession(resetState: true)
            phase = .disconnected
            return
        }
        if selected != previous || driver == nil {
            connect(to: selected)
        }
    }

    private func resolveSelection(in list: [AttachedDevice]) -> AttachedDevice? {
        if let selected,
           let current = list.first(where: { $0.id == selected.id }) {
            return current
        }
        let remembered = UserDefaults.standard.string(forKey: Self.selectionKey)
        if let remembered,
           let match = list.first(where: { $0.persistedSelection == remembered }) {
            return match
        }
        // One-time compatibility with releases that persisted only the port.
        let legacy = UserDefaults.standard.object(forKey: Self.legacySelectionKey) as? Int
        if let legacy,
           let match = list.first(where: {
               $0.locationID == UInt32(truncatingIfNeeded: legacy)
           }) { return match }
        return list.first
    }

    func select(_ device: AttachedDevice) {
        guard device != selected else { return }
        selected = device
        UserDefaults.standard.set(device.persistedSelection, forKey: Self.selectionKey)
        connect(to: device)
    }

    private func connect(to device: AttachedDevice) {
        invalidateSession(resetState: true)
        phase = .connecting
        let session = generation
        UserDefaults.standard.set(device.persistedSelection, forKey: Self.selectionKey)

        do {
            let opened = try driverFactory(device)
            opened.onChange = { [weak self] write in
                guard let self, self.generation == session else { return }
                self.deviceReportedChange(write)
            }
            opened.onConfirmed = { [weak self] write in
                guard let self, self.generation == session else { return }
                self.writeWasConfirmed(write)
            }
            opened.onDropped = { [weak self] write in
                guard let self, self.generation == session else { return }
                self.writeWasDropped(write)
            }
            opened.onRemoved = { [weak self] in
                guard let self, self.generation == session else { return }
                self.driverWasRemoved()
            }
            driver = opened
            settings = opened.descriptor.settings
            startRefresh(driver: opened, session: session)
        } catch {
            Self.logger.error("Connection failed: \(error.localizedDescription)")
            driver = nil
            phase = .failed(error.localizedDescription)
        }
    }

    private func driverWasRemoved() {
        invalidateSession(resetState: true)
        devices = []
        selected = nil
        phase = .disconnected
        Self.logger.info("Active device connection was removed")
    }

    private func invalidateSession(resetState: Bool) {
        generation += 1
        refreshTask?.cancel()
        writeTask?.cancel()
        refreshTask = nil
        writeTask = nil
        pendingWrite = nil
        retryAttempts.removeAll()
        changesDuringRefresh.removeAll()
        driver?.close()
        driver = nil

        if resetState {
            confirmed = DACDeviceKit.Snapshot()
            sent = DACDeviceKit.Snapshot()
            draft = DACDeviceKit.Snapshot()
            settings = []
        }
    }

    // MARK: - Reading

    /// Reopens a failed driver or refreshes the active one. The model owns
    /// the task so switching devices always cancels and invalidates the result.
    func refresh() {
        if watcherNeedsRestart {
            restartWatcher()
            return
        }
        guard let selected else {
            restartWatcher()
            return
        }
        guard let driver else {
            connect(to: selected)
            return
        }
        startRefresh(driver: driver, session: generation)
    }

    private func startRefresh(driver: any DeviceDriver, session: Int) {
        refreshTask?.cancel()
        writeTask?.cancel()
        writeTask = nil
        pendingWrite = nil
        changesDuringRefresh.removeAll()
        phase = .reading

        refreshTask = Task { @MainActor [weak self, driver] in
            let retryDelays = driver.descriptor.readRetryDelays
            for attempt in 0...retryDelays.count {
                do {
                    let state = try await driver.read()
                    try driver.descriptor.validate(state)
                    try Task.checkCancellation()
                    guard let self, self.generation == session,
                          self.driver === driver else { return }
                    guard !self.watcherNeedsRestart else {
                        self.changesDuringRefresh.removeAll()
                        self.refreshTask = nil
                        return
                    }
                    self.confirmed = state
                    self.sent = state
                    self.draft = state
                    // Firmware-probing drivers may refine their capabilities
                    // during the first read (for example, an old/new protocol
                    // delegate). Publish that change through Observation.
                    self.settings = driver.descriptor.settings
                    for write in self.changesDuringRefresh {
                        self.confirmed.apply(write)
                        self.sent.apply(write)
                        self.draft.apply(write)
                    }
                    self.changesDuringRefresh.removeAll()
                    self.retryAttempts.removeAll()
                    self.phase = .ready
                    self.refreshTask = nil
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, self.generation == session,
                          self.driver === driver else { return }
                    guard attempt < retryDelays.count else {
                        Self.logger.error(
                            "Refresh failed after retries: \(error.localizedDescription, privacy: .public)")
                        self.phase = .failed(error.localizedDescription)
                        self.changesDuringRefresh.removeAll()
                        self.refreshTask = nil
                        return
                    }

                    let delay = retryDelays[attempt]
                    Self.logger.info(
                        "Device not ready after read attempt \(attempt + 1, privacy: .public); retrying after \(String(describing: delay), privacy: .public)")
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func deviceReportedChange(_ write: DACDeviceKit.Mutation) {
        guard phase != .reading else {
            changesDuringRefresh.append(write)
            return
        }
        confirmed.apply(write)
        sent.apply(write)
        draft.apply(write)
        retryAttempts.removeValue(forKey: write)
        if draft.valid, !watcherNeedsRestart { phase = .ready }
    }

    private func writeWasConfirmed(_ write: DACDeviceKit.Mutation) {
        retryAttempts.removeValue(forKey: write)
        guard phase != .reading else {
            changesDuringRefresh.append(write)
            return
        }
        confirmed.apply(write)
    }

    private func restartWatcher() {
        watcher.stop()
        phase = .connecting
        do {
            try watcher.start()
            watcherNeedsRestart = false
            devicesDidChange(to: watcher.devices)
            if phase == .connecting, let driver {
                startRefresh(driver: driver, session: generation)
            }
        } catch {
            Self.logger.error("Device watcher restart failed: \(error.localizedDescription)")
            watcherNeedsRestart = true
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Writing

    func value(for setting: DACDeviceKit.SettingID) -> Int? {
        draft[setting]
    }

    func textValue(for setting: DACDeviceKit.SettingID) -> String? {
        draft.textValues[setting]
    }

    func updateDraft(_ setting: DACDeviceKit.SettingID, value: Int) {
        guard let descriptor = settings.first(where: { $0.id == setting }),
              (try? descriptor.validate(value)) != nil
        else { return }
        draft[setting] = value
        scheduleApply()
    }

    /// Moves the selected DAC by logical volume steps. Global shortcuts use
    /// this same capability-driven mutation path as the slider, so they inherit
    /// the active driver's validation, coalescing, pacing, and retry behavior.
    /// No Core Audio default-device assumption is made: exclusive players may
    /// own the selected DAC while macOS keeps a different default output.
    @discardableResult
    func adjustVolume(bySteps stepCount: Int) -> Bool {
        guard isReady, stepCount != 0,
              let descriptor = settings.first(where: { $0.id == .volume }),
              case .range(let minimum, let maximum, let step, _) = descriptor.presentation,
              step > 0,
              let current = draft[.volume],
              (try? descriptor.validate(current)) != nil
        else { return false }

        let delta = stepCount.multipliedReportingOverflow(by: step)
        guard !delta.overflow else { return false }
        let candidate = current.addingReportingOverflow(delta.partialValue)
        let target: Int
        if stepCount < 0, candidate.overflow || candidate.partialValue < minimum {
            target = minimum
        } else if stepCount > 0, candidate.overflow || candidate.partialValue > maximum {
            // `maximum` is not required to be a step boundary. Stop at the
            // highest value reachable from the current valid value instead.
            let distance = maximum.subtractingReportingOverflow(current)
            guard !distance.overflow else { return false }
            target = current + (distance.partialValue / step) * step
        } else {
            target = candidate.partialValue
        }
        guard target != current, (try? descriptor.validate(target)) != nil else {
            return false
        }
        updateDraft(.volume, value: target)
        return true
    }

    func scheduleApply() {
        guard isReady, let driver else { return }
        guard sent != draft else { return }
        pendingWrite = draft
        startWriteTaskIfNeeded(driver: driver, session: generation)
    }

    private func startWriteTaskIfNeeded(driver: any DeviceDriver, session: Int) {
        guard writeTask == nil else { return }
        writeTask = Task { @MainActor [weak self, driver] in
            await self?.drainWrites(driver: driver, session: session)
        }
    }

    private func drainWrites(driver: any DeviceDriver, session: Int) async {
        defer {
            if generation == session { writeTask = nil }
        }

        while let target = pendingWrite {
            pendingWrite = nil
            let writes: [DACDeviceKit.Mutation]
            do {
                writes = try sent.mutations(
                    to: target, settings: driver.descriptor.settings)
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }

            for write in writes {
                do {
                    try await driver.submit(write)
                    try Task.checkCancellation()
                    guard generation == session, self.driver === driver else { return }
                    sent.apply(write)
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == session, self.driver === driver else { return }
                    Self.logger.error("Write submission failed: \(error.localizedDescription)")
                    handleWriteFailure(write, message: error.localizedDescription,
                                       driver: driver, session: session)
                    if case .failed = phase { return }
                }
            }
        }
    }

    private func writeWasDropped(_ write: DACDeviceKit.Mutation) {
        // The read snapshot is authoritative during refresh. Retrying an older
        // timeout behind that read could change the device after the snapshot
        // has already replaced the UI state.
        guard phase != .reading else {
            retryAttempts.removeValue(forKey: write)
            return
        }
        // Slider writes stay in flight without blocking the next value. A timeout
        // for an older intermediate value must not roll back or retry after the
        // user has already selected a newer value for the same command.
        guard draft[write.setting] == write.value,
              confirmed[write.setting] != write.value else {
            retryAttempts.removeValue(forKey: write)
            return
        }
        Self.logger.error(
            "Current write was not acknowledged setting=\(write.setting.rawValue, privacy: .public) value=\(write.value, privacy: .public)")
        if let confirmedValue = confirmed[write.setting] {
            sent.apply(DACDeviceKit.Mutation(
                setting: write.setting, value: confirmedValue))
        }
        handleWriteFailure(
            write,
            message: AppL10n.text(
                "error.write-unconfirmed", defaultValue: "The device did not confirm the write"),
                           driver: driver, session: generation)
    }

    private func handleWriteFailure(
        _ write: DACDeviceKit.Mutation,
        message: String,
        driver: (any DeviceDriver)?,
        session: Int
    ) {
        let retries = retryAttempts[write, default: 0]
        let limit = driver?.descriptor.writeRetryLimit ?? 0
        guard retries < limit, let driver else {
            pendingWrite = nil
            phase = .failed(AppL10n.format(
                "error.retry-failed",
                defaultValue: "%@. The retry also failed.",
                message))
            return
        }
        retryAttempts[write] = retries + 1
        pendingWrite = draft
        startWriteTaskIfNeeded(driver: driver, session: session)
    }
}
