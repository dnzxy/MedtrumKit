import Foundation
import LoopKit

// Handing the patch to another controller, such as Trio on Apple Watch.
//
// The patch accepts any controller that has its serial number and session token, and keeps one
// Bluetooth link at a time. So the releasing side drops its link and stops reconnecting, and the
// adopting side connects with the exported state. Each side books only the doses it commanded:
// the open basal dose is closed at the release and started fresh at a take or an adopt.

// MARK: - Configuration sharing

extension MedtrumPumpManager: DeviceConfigurationSharing {
    public func exportConfiguration() -> SharedDeviceConfiguration {
        if !state.sharedWithAnotherController {
            state.sharedWithAnotherController = true
            notifyStateDidChange()
        }

        let shared = MedtrumPumpState(rawValue: state.rawValue)
        shared.peripheralIdentifier = nil
        shared.controlReleased = false
        shared.refusesSessions = false
        shared.foreignSessionDetectedAt = nil
        shared.supersedingUntil = nil
        shared.lastOwnDeliveryCommandAt = nil
        shared.lastSeenBasalSequence = nil
        shared.bolusDose = nil

        return SharedDeviceConfiguration(
            managerIdentifier: pluginIdentifier,
            asOf: state.reservoirReadAt ?? state.lastSync,
            deliveredUnits: deliveredUnits?.units,
            state: shared.rawValue
        )
    }

    /// The state an adopting manager starts from, or nil if the export can't drive a patch.
    static func adoptedState(from configuration: SharedDeviceConfiguration, localState: [String: Any]?) -> MedtrumPumpState? {
        guard configuration.managerIdentifier == "Medtrum" else {
            return nil
        }

        let state = MedtrumPumpState(rawValue: configuration.state)
        guard !state.pumpSN.isEmpty, !state.sessionToken.isEmpty, !state.patchSessionEnded else {
            return nil
        }

        state.peripheralIdentifier = handle(in: localState, forPumpSN: state.pumpSN)
        state.controlReleased = false
        state.sharedWithAnotherController = true
        state.basalDose = UnfinalizedDose(
            basalRate: state.currentBaseBasalRate,
            insulinType: state.insulinType,
            startDate: Date.now
        )
        state.bolusDose = nil
        return state
    }

    /// This device's Bluetooth handle for the patch. Never in the export.
    public var localState: [String: Any]? {
        guard let identifier = state.peripheralIdentifier else {
            return nil
        }
        return ["pumpSN": state.pumpSN, "peripheralIdentifier": identifier.uuidString]
    }

    static func handle(in localState: [String: Any]?, forPumpSN pumpSN: Data) -> UUID? {
        guard let localState, localState["pumpSN"] as? Data == pumpSN else {
            return nil
        }
        return (localState["peripheralIdentifier"] as? String).flatMap(UUID.init(uuidString:))
    }
}

// MARK: - Exclusive control

extension MedtrumPumpManager: ExclusiveDeviceControl {
    public var isControlReleased: Bool {
        state.controlReleased
    }

    /// Refused while a bolus is running: only this controller could follow it to the end.
    public func releaseControl() {
        guard !state.controlReleased else {
            return
        }
        guard state.bolusState == .noBolus else {
            log.warning("Release refused: a bolus is running")
            return
        }

        let now = Date.now
        var events = finalizedTempBasal(endedAt: now)
        if !events.isEmpty {
            events.append(NewPumpEvent.basal(dose: UnfinalizedDose(
                basalRate: state.currentBaseBasalRate,
                insulinType: state.insulinType,
                startDate: now
            ).toDoseEntry()))
        }
        state.basalDose = UnfinalizedDose(basalRate: state.currentBaseBasalRate, insulinType: state.insulinType, startDate: now)
        state.controlReleased = true
        state.sharedWithAnotherController = true
        state.supersedingUntil = nil
        notifyStateDidChange()
        if !events.isEmpty {
            emitPumpEvents(events)
        }

        log.info("Control released to another controller")
        bluetooth?.disconnectForRelease()
    }

    public func takeControl() {
        take(supersedingUntil: nil, liftingRefusal: false)
    }

    /// Until `until`, deliveries by another controller are noted but don't stop this one: it may not have heard yet.
    public func takeControl(supersedingAnotherControllerUntil until: Date?) {
        take(supersedingUntil: until, liftingRefusal: until != nil)
    }

    /// The user chose this device after another one used the patch.
    public func takeControlLiftingRefusal() {
        take(supersedingUntil: nil, liftingRefusal: true)
    }

    public func stopSupersedingAnotherController() {
        state.supersedingUntil = nil
        notifyStateDidChange()
    }

    private func take(supersedingUntil until: Date?, liftingRefusal: Bool) {
        let wasReleased = state.controlReleased
        if liftingRefusal {
            state.refusesSessions = false
            state.foreignSessionDetectedAt = nil
        }
        guard !state.refusesSessions else {
            log.warning("Take refused: another controller used the patch")
            return
        }

        state.supersedingUntil = until
        if wasReleased || liftingRefusal {
            // the other controller booked its own doses; start ours from now
            state.basalDose = UnfinalizedDose(
                basalRate: state.currentBaseBasalRate,
                insulinType: state.insulinType,
                startDate: Date.now
            )
            state.bolusDose = nil
            state.lastSeenBasalSequence = nil
            state.foreignSessionDetectedAt = nil
        }
        state.controlReleased = false
        notifyStateDidChange()
        log.info("Taking control of the patch")

        ensureConnectedAndActive { error in
            if let error {
                self.log.warning("Take: no connection yet: \(error.localizedDescription)")
                return
            }
            self.pumpDelegate.notify { delegate in
                delegate?.deviceManagerControlDidBecomeReady(self)
            }
        }
    }

    public var isControlReady: Bool {
        guard !state.controlReleased, !state.refusesSessions, let bluetooth else {
            return false
        }
        return bluetooth.isConnected
    }

    /// True when there is no Bluetooth handle for this patch here, so a take has to scan, which only works in the foreground.
    public static func takeControlNeedsSearch(adopting configuration: SharedDeviceConfiguration, localState: [String: Any]?) -> Bool {
        let pumpSN = configuration.state["pumpSN"] as? Data ?? Data()
        return handle(in: localState, forPumpSN: pumpSN) == nil
    }

    public var refusesSessions: Bool {
        state.refusesSessions
    }

    public var foreignSessionDetectedAt: Date? {
        state.foreignSessionDetectedAt
    }

    public var deliveryStartedAt: Date? {
        state.patchActivatedAt
    }

    public var deliveryEndsAt: Date? {
        state.patchExpiresAt
    }
}

// MARK: - Another controller's deliveries

extension MedtrumPumpManager {
    /// A temp basal or bolus seen this soon after one of our own delivery commands is taken as ours.
    static let ownCommandWindow: TimeInterval = .minutes(2)

    func noteOwnDeliveryCommand() {
        state.lastOwnDeliveryCommandAt = Date.now
    }

    /// Called for each status from the patch. Only on a patch shared with another controller. The first
    /// status after a take or an adopt sets the baseline and is never counted.
    func noteObservedDelivery(basal: BasalData?, bolus: BolusData?) {
        guard state.sharedWithAnotherController, !state.controlReleased else {
            return
        }

        let now = Date.now
        let ownCommandRecently = state.lastOwnDeliveryCommandAt.map { now.timeIntervalSince($0) < Self.ownCommandWindow } ?? false
        let hasBaseline = state.lastSeenBasalSequence != nil
        var foreign = false

        if let basal {
            if let last = state.lastSeenBasalSequence, basal.sequence != last, basal.type.isTemp, !ownCommandRecently {
                foreign = true
            }
            state.lastSeenBasalSequence = basal.sequence
        }
        if hasBaseline, let bolus, !bolus.completed, bolus.delivered > 0, state.bolusDose == nil, !ownCommandRecently {
            foreign = true
        }

        guard foreign else {
            return
        }

        if state.foreignSessionDetectedAt == nil {
            state.foreignSessionDetectedAt = now
            log.warning("Another controller delivered insulin on this patch")
        }
        if let until = state.supersedingUntil, until > now {
            return
        }
        if !state.refusesSessions {
            state.refusesSessions = true
            log.warning("Refusing the patch until the user chooses this device again")
            bluetooth?.disconnectForRelease()
        }
    }
}

// MARK: - Delivered-total odometer

extension MedtrumPumpManager: PumpDeliveryOdometer {
    static let pulseSize = 0.05

    /// The starting reservoir minus the current one, in whole pulses.
    public var deliveredUnits: (units: Double, at: Date)? {
        guard let initial = state.initialReservoir, let readAt = state.reservoirReadAt else {
            return nil
        }
        let pulses = ((initial - state.reservoir) / Self.pulseSize).rounded()
        return (max(0, pulses) * Self.pulseSize, readAt)
    }

    public var deliveryPulseUnits: Double {
        Self.pulseSize
    }

    public var deliveredUnitsAreFinal: Bool {
        state.pumpState.isFault || state.pumpState.isTerminated
    }

    public func refreshDeliveredUnits() async -> Bool {
        let before = state.reservoirReadAt
        let synced: Date? = await withCheckedContinuation { continuation in
            syncPumpData { continuation.resume(returning: $0) }
        }
        guard synced != nil, let after = state.reservoirReadAt else {
            return false
        }
        return before.map { after > $0 } ?? true
    }

    /// Our own bolus only: the patch reports what a bolus delivered so far, not how much it will give.
    public var bolusUnderWayEndsAt: Date? {
        guard state.bolusState != .noBolus, let bolus = state.bolusDose else {
            return nil
        }
        return bolus.estimatedEndDate
    }

    /// Reads the status if it is older than `age`.
    public func readStatusIfOlder(than age: TimeInterval, completion: @escaping (Date?) -> Void) {
        guard !state.controlReleased, !state.refusesSessions, Date.now.timeIntervalSince(state.lastSync) > age else {
            completion(state.lastSync)
            return
        }
        syncPumpData { _ in
            completion(self.state.lastSync)
        }
    }
}

extension BasalType {
    var isTemp: Bool {
        self == .ABSOLUTE_TEMP || self == .RELATIVE_TEMP
    }
}
