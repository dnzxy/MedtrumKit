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
        manager.takeControl()

        XCTAssertFalse(manager.isControlReleased)
        XCTAssertEqual(manager.state.basalDose.type, .basal)
        XCTAssertNil(manager.state.bolusDose)
    }

    // MARK: Another controller

    func testTheKitNeverRefusesThePatchOnItsOwn() {
        // a refusal saved by an earlier build doesn't stop this one
        var raw = activeState().rawValue
        raw["refusesSessions"] = true
        raw["foreignSessionDetectedAt"] = Date.now
        let manager = MedtrumPumpManager(state: MedtrumPumpState(rawValue: raw), withBluetooth: false)

        XCTAssertFalse(manager.refusesSessions)
        XCTAssertNil(manager.foreignSessionDetectedAt)
        XCTAssertNil(manager.rawState["refusesSessions"])
    }

    func testAReleaseThatCameWithTheOldRefusalIsUndone() {
        var raw = activeState().rawValue
        raw["controlReleased"] = true
        raw["refusesSessions"] = true
        XCTAssertFalse(MedtrumPumpState(rawValue: raw).controlReleased)

        raw["refusesSessions"] = nil
        XCTAssertTrue(MedtrumPumpState(rawValue: raw).controlReleased, "a real hand-off stays released")
    }

    // MARK: Pump data

    func testFreshDataReportsTheLastSyncNotNil() {
        let state = activeState()
        state.lastSync = Date.now.addingTimeInterval(-30)
        let manager = MedtrumPumpManager(state: state, withBluetooth: false)
        let reported = expectation(description: "completion")
        manager.ensureCurrentPumpData { lastSync in
            XCTAssertEqual(lastSync, state.lastSync)
            reported.fulfill()
        }
        wait(for: [reported], timeout: 1)
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
