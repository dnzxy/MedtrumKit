import LoopKit
@testable import MedtrumKit
import XCTest

final class DeviceHandoffTests: XCTestCase {
    private let pumpSN = Data([0x28, 0xD8, 0x12, 0x4A])
    private let handle = UUID()

    private func activeState() -> MedtrumPumpState {
        let state = MedtrumPumpState(nil)
        state.isOnboarded = true
        state.pumpSN = pumpSN
        state.sessionToken = Data([1, 2, 3, 4])
        state.patchId = UInt64(256).toData(length: 4)
        state.pumpState = .active
        state.patchSessionEnded = false
        state.patchActivatedAt = Date.now.addingTimeInterval(-.hours(10))
        state.peripheralIdentifier = handle
        state.initialReservoir = 200
        state.reservoir = 187.35
        state.reservoirReadAt = Date.now
        return state
    }

    private func basal(_ type: BasalType, sequence: Double) -> BasalData {
        BasalData(type: type, sequence: sequence, patchId: 256, startTime: Date.now, rate: 1, delivery: 0)
    }

    // MARK: Export and adopt

    func testExportLeavesOutTheHandleAndThisControllersFlags() throws {
        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        manager.releaseControl()
        let export = manager.exportConfiguration()
        let shared = MedtrumPumpState(rawValue: export.state)

        XCTAssertEqual(export.managerIdentifier, "Medtrum")
        XCTAssertNil(shared.peripheralIdentifier)
        XCTAssertFalse(shared.controlReleased)
        XCTAssertEqual(shared.pumpSN, pumpSN)
        XCTAssertEqual(try XCTUnwrap(export.deliveredUnits), 12.65, accuracy: 0.001)
    }

    func testAdoptUsesThisDevicesHandleOnlyForTheSamePatch() throws {
        let export = MedtrumPumpManager(state: activeState(), withBluetooth: false).exportConfiguration()
        let own = UUID()

        let same = try XCTUnwrap(MedtrumPumpManager.adoptedState(
            from: export,
            localState: ["pumpSN": pumpSN, "peripheralIdentifier": own.uuidString]
        ))
        XCTAssertEqual(same.peripheralIdentifier, own)
        XCTAssertTrue(same.sharedWithAnotherController)
        XCTAssertNil(same.bolusDose)
        XCTAssertFalse(MedtrumPumpManager.takeControlNeedsSearch(
            adopting: export,
            localState: ["pumpSN": pumpSN, "peripheralIdentifier": own.uuidString]
        ))

        let other = try XCTUnwrap(MedtrumPumpManager.adoptedState(
            from: export,
            localState: ["pumpSN": Data([9, 9, 9, 9]), "peripheralIdentifier": own.uuidString]
        ))
        XCTAssertNil(other.peripheralIdentifier)
        XCTAssertTrue(MedtrumPumpManager.takeControlNeedsSearch(adopting: export, localState: nil))
    }

    func testAdoptRefusesAnEndedPatchOrAnotherPlugin() {
        let ended = activeState()
        ended.patchSessionEnded = true
        let endedExport = SharedDeviceConfiguration(managerIdentifier: "Medtrum", asOf: Date.now, state: ended.rawValue)
        XCTAssertNil(MedtrumPumpManager.adoptedState(from: endedExport, localState: nil))

        let other = SharedDeviceConfiguration(managerIdentifier: "Omni", asOf: Date.now, state: activeState().rawValue)
        XCTAssertNil(MedtrumPumpManager.adoptedState(from: other, localState: nil))
    }

    // MARK: Release and take

    func testReleaseIsPersistedAndRefusedDuringABolus() {
        let bolusing = activeState()
        bolusing.bolusDose = UnfinalizedDose(
            decisionId: nil, units: 2, duration: 60, activationType: .manualNoRecommendation, insulinType: nil
        )
        let busy = MedtrumPumpManager(state: bolusing, withBluetooth: false)
        busy.releaseControl()
        XCTAssertFalse(busy.isControlReleased)

        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        manager.releaseControl()
        XCTAssertTrue(manager.isControlReleased)
        XCTAssertFalse(manager.isControlReady)
        XCTAssertTrue(MedtrumPumpState(rawValue: manager.rawState).controlReleased)
        XCTAssertEqual(manager.state.peripheralIdentifier, handle)
    }

    func testTakeAfterAReleaseStartsFresh() {
        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        manager.releaseControl()
        manager.state.lastSeenBasalSequence = 7
        manager.takeControl()

        XCTAssertFalse(manager.isControlReleased)
        XCTAssertNil(manager.state.lastSeenBasalSequence)
        XCTAssertEqual(manager.state.basalDose.type, .basal)
        XCTAssertNil(manager.state.bolusDose)
    }

    // MARK: Another controller's deliveries

    func testATempBasalWeDidNotCommandStopsThisController() {
        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        manager.state.sharedWithAnotherController = true

        // the first status after a take only sets the baseline
        manager.noteObservedDelivery(basal: basal(.ABSOLUTE_TEMP, sequence: 10), bolus: nil)
        XCTAssertNil(manager.foreignSessionDetectedAt)

        manager.noteObservedDelivery(basal: basal(.ABSOLUTE_TEMP, sequence: 11), bolus: nil)
        XCTAssertNotNil(manager.foreignSessionDetectedAt)
        XCTAssertTrue(manager.refusesSessions)

        manager.takeControlLiftingRefusal()
        XCTAssertFalse(manager.refusesSessions)
        XCTAssertNil(manager.foreignSessionDetectedAt)
    }

    func testOurOwnTempBasalIsNotAnotherController() {
        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        manager.state.sharedWithAnotherController = true
        manager.noteObservedDelivery(basal: basal(.STANDARD, sequence: 10), bolus: nil)

        manager.noteOwnDeliveryCommand()
        manager.noteObservedDelivery(basal: basal(.ABSOLUTE_TEMP, sequence: 11), bolus: nil)
        XCTAssertNil(manager.foreignSessionDetectedAt)
    }

    func testWhileSupersedingAnotherControllerIsNotedButDoesNotStopUs() {
        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        manager.releaseControl()
        manager.takeControl(supersedingAnotherControllerUntil: Date.now.addingTimeInterval(.hours(1)))
        manager.noteObservedDelivery(basal: basal(.STANDARD, sequence: 10), bolus: nil)

        manager.noteObservedDelivery(basal: basal(.ABSOLUTE_TEMP, sequence: 11), bolus: nil)
        XCTAssertNotNil(manager.foreignSessionDetectedAt)
        XCTAssertFalse(manager.refusesSessions)
    }

    func testABolusWeDidNotStartStopsThisController() {
        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        manager.state.sharedWithAnotherController = true
        manager.noteObservedDelivery(basal: basal(.STANDARD, sequence: 10), bolus: nil)

        manager.noteObservedDelivery(basal: nil, bolus: BolusData(type: 0, completed: false, delivered: 0.5))
        XCTAssertTrue(manager.refusesSessions)
    }

    func testAPatchNeverSharedIsNotChecked() {
        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        manager.noteObservedDelivery(basal: basal(.STANDARD, sequence: 10), bolus: nil)
        manager.noteObservedDelivery(basal: basal(.ABSOLUTE_TEMP, sequence: 11), bolus: nil)
        XCTAssertNil(manager.foreignSessionDetectedAt)
    }

    // MARK: Odometer

    func testDeliveredUnitsAreTheReservoirUsedInWholePulses() throws {
        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        let delivered = try XCTUnwrap(manager.deliveredUnits)
        XCTAssertEqual(delivered.units, 12.65, accuracy: 0.0001)
        XCTAssertEqual(manager.deliveryPulseUnits, 0.05)

        let unread = activeState()
        unread.reservoirReadAt = nil
        XCTAssertNil(MedtrumPumpManager(state: unread, withBluetooth: false).deliveredUnits)
    }

    func testAFaultedPatchsTotalIsFinal() {
        let state = activeState()
        state.pumpState = .occlusion
        XCTAssertTrue(MedtrumPumpManager(state: state, withBluetooth: false).deliveredUnitsAreFinal)
        XCTAssertFalse(MedtrumPumpManager(state: activeState(), withBluetooth: false).deliveredUnitsAreFinal)
    }
}
