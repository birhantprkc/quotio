import AppKit
import SwiftUI
import Foundation
import XCTest
import QuotioApplication
import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class CompanionScreenModelTests: XCTestCase {
    func testNetworkChoicesNeedNoHTTPSInputAndRecoverWhenTailscaleAppears() async {
        let controller = CompanionStub()
        controller.enabled = false
        controller.origin = ""
        controller.mode = .localNetwork
        controller.addresses = [.init(mode: .localNetwork, address: "192.168.1.10", interface: "en0")]
        let model = CompanionScreenModel(controller: controller)
        await model.reload()
        XCTAssertEqual(model.mode, .localNetwork)
        XCTAssertEqual(model.selectedAddress, "192.168.1.10")
        XCTAssertTrue(model.canEnable)
        model.mode = .tailscale
        XCTAssertFalse(model.canEnable)
        controller.addresses.append(.init(mode: .tailscale, address: "100.64.0.2", interface: "utun4"))
        await model.reload()
        XCTAssertEqual(model.mode, .tailscale)
        XCTAssertTrue(model.canEnable)
        await model.configure(enabled: true)
        XCTAssertEqual(controller.mode, .tailscale)
        XCTAssertEqual(model.origin, "https://100.64.0.2:6768")
        XCTAssertTrue(model.enabled)
    }

    func testCreatePairingEnablesSharingAndCancelRevokesTheCredential() async throws {
        let controller = CompanionStub()
        controller.enabled = false
        controller.mode = .localNetwork
        controller.addresses = [.init(mode: .localNetwork, address: "192.168.1.10", interface: "en0")]
        let model = CompanionScreenModel(controller: controller)
        await model.reload()
        await model.createPairing()
        let id = try XCTUnwrap(model.pairing?.device.id)
        XCTAssertTrue(model.enabled)
        XCTAssertEqual(controller.issueCount, 1)
        await model.cancelPairing()
        XCTAssertNil(model.pairing)
        XCTAssertFalse(controller.issued.contains { $0.id == id })
    }

    func testSelectingAndDisablingTailscaleKeepsLANAndItsPairingCode() async throws {
        let controller = CompanionStub()
        controller.mode = .localNetwork
        controller.origin = "https://192.168.1.10:6768"
        controller.endpoints = [
            .init(enabled: true, listen: "192.168.1.10:6768", publicUrl: controller.origin, mode: .localNetwork),
            .init(enabled: false, listen: "100.64.0.2:6768", publicUrl: "https://100.64.0.2:6768", mode: .tailscale),
        ]
        controller.addresses = [.init(mode: .localNetwork, address: "192.168.1.10", interface: "en0"),
                                .init(mode: .tailscale, address: "100.64.0.2", interface: "utun4")]
        let model = CompanionScreenModel(controller: controller)
        await model.reload()
        await model.issue()
        let lanPairing = try XCTUnwrap(model.pairing)
        model.mode = .tailscale
        XCTAssertFalse(model.enabled)
        XCTAssertEqual(model.selectedAddress, "100.64.0.2")
        XCTAssertEqual(model.pairing?.device.id, lanPairing.device.id)
        await model.configure(enabled: true)
        XCTAssertTrue(model.enabled)
        XCTAssertEqual(model.connections.filter(\.enabled).count, 2)
        await model.reload()
        XCTAssertEqual(model.mode, .tailscale)
        model.finishPairing()
        await model.issue()
        XCTAssertEqual(model.pairing?.origin, "https://100.64.0.2:6768")
        await model.configure(enabled: false)
        XCTAssertFalse(model.enabled)
        XCTAssertNil(model.pairing)
        model.mode = .localNetwork
        XCTAssertTrue(model.enabled)
        XCTAssertEqual(model.origin, "https://192.168.1.10:6768")
        XCTAssertEqual(model.connections.filter(\.enabled).count, 1)
    }

    func testRenderPairingLayouts() async throws {
        guard let output = ProcessInfo.processInfo.environment["QUOTIO_COMPANION_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set QUOTIO_COMPANION_SNAPSHOT_DIR for visual verification")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../apps/macos/build/DebugDerivedData/Build/Products/Debug/Quotio.app").standardizedFileURL
        let previousBundle = PresentationLocalization.bundle
        defer { PresentationLocalization.updateBundle(previousBundle) }
        if let resources = Bundle(url: app)?.path(forResource: "en", ofType: "lproj"), let bundle = Bundle(path: resources) {
            PresentationLocalization.updateBundle(bundle)
        }
        let controller = CompanionStub()
        controller.mode = .localNetwork
        controller.origin = "https://192.168.1.10:6768"
        controller.addresses = [.init(mode: .localNetwork, address: "192.168.1.10", interface: "en0"),
                                .init(mode: .tailscale, address: "100.64.0.2", interface: "utun4")]
        controller.endpoints = [
            .init(enabled: true, listen: "192.168.1.10:6768", publicUrl: controller.origin, mode: .localNetwork),
            .init(enabled: true, listen: "100.64.0.2:6768", publicUrl: "https://100.64.0.2:6768", mode: .tailscale),
        ]
        let model = CompanionScreenModel(controller: controller)
        let pasteboard = PasteboardScreenModel(writer: NoCopyPasteboard())
        await model.reload()
        await model.issue()
        let layouts: [(String, CGFloat, NSAppearance.Name)] = [
            ("setup", 400, .darkAqua), ("setup", 640, .aqua), ("tailscale", 400, .darkAqua),
            ("pairing", 400, .darkAqua), ("pairing", 640, .aqua),
            ("settings", 760, .darkAqua), ("settings", 760, .aqua),
        ]
        for (surface, width, appearance) in layouts {
            let setupController = CompanionStub()
            let setupModel = CompanionScreenModel(controller: setupController)
            setupController.enabled = false
            setupController.mode = surface == "tailscale" ? .tailscale : .localNetwork
            setupController.addresses = [.init(mode: .localNetwork, address: "192.168.1.10", interface: "en0")]
            await setupModel.reload()
            let visibleModel = ["setup", "tailscale"].contains(surface) ? setupModel : model
            let content = surface == "settings"
                ? AnyView(Form { CompanionSettingsSection(model: model) }.formStyle(.grouped))
                : AnyView(CompanionPairingView(
                    model: visibleModel,
                    presentation: ["setup", "tailscale"].contains(surface) ? .menuBar : .settings
                ))
            let view = content.environment(pasteboard)
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 750)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(surface)-\(Int(width))-\(appearance == .darkAqua ? "dark" : "light").png"))
        }
        XCTAssertEqual(controller.issueCount, 1)
    }

    func testClosingAndReopeningPreservesInFlightPairingWithoutIssuingAgain() async throws {
        let controller = CompanionStub()
        let model = CompanionScreenModel(controller: controller)
        await model.reload()
        XCTAssertEqual(controller.issueCount, 0)
        model.presentPairing(in: .settings)
        controller.suspendIssuance = true
        let request = Task { await model.issue() }
        for _ in 0..<100 where controller.pending == nil { await Task.yield() }
        XCTAssertNotNil(controller.pending)
        model.hidePairing(in: .settings)
        model.presentPairing(in: .menuBar)
        model.hidePairing(in: .settings)
        XCTAssertEqual(model.presentation, .menuBar)
        await model.issue()
        controller.completeIssuance()
        await request.value
        XCTAssertNotNil(model.pairing)
        await model.reload()
        await model.issue()
        XCTAssertEqual(controller.issueCount, 1)
        XCTAssertNotNil(model.pairing)
        model.finishPairing()
        XCTAssertNil(model.pairing)
        XCTAssertNil(model.presentation)
    }

    func testRevocationExpiryAndEndpointChangesDiscardOnlyCurrentCode() async throws {
        let controller = CompanionStub()
        let model = CompanionScreenModel(controller: controller)
        await model.reload()
        await model.issue()
        let id = try XCTUnwrap(model.pairing?.device.id)
        await model.revoke("another-device")
        XCTAssertEqual(model.pairing?.device.id, id)
        controller.issued.removeAll()
        await model.reload()
        XCTAssertNil(model.pairing)
        await model.issue()
        model.clearExpiredPairing(now: Date.distantFuture)
        XCTAssertNil(model.pairing)
        await model.issue()
        controller.origin = "https://changed.example.test"
        await model.reload()
        XCTAssertNil(model.pairing)
        await model.issue()
        await model.configure(enabled: false)
        XCTAssertNil(model.pairing)
        XCTAssertFalse(model.enabled)
    }

    func testFailedOperationsKeepConfirmedStateAndNeverRetryIssuance() async {
        let controller = CompanionStub()
        let model = CompanionScreenModel(controller: controller)
        await model.reload()
        controller.fail = true
        await model.issue()
        XCTAssertEqual(controller.issueCount, 1)
        XCTAssertEqual(model.failure, .hostUnavailable)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.pairing)
        await model.configure(enabled: false)
        XCTAssertTrue(model.enabled)
        controller.fail = false
        await model.reload()
        XCTAssertNil(model.failure)
        XCTAssertEqual(controller.issueCount, 1)
    }

    func testReloadRetainsSavedConfigurationWhenOffWithoutOverwritingDraft() async {
        let controller = CompanionStub()
        controller.enabled = false
        let model = CompanionScreenModel(controller: controller)
        await model.reload()
        XCTAssertEqual(model.origin, controller.origin)
        XCTAssertEqual(model.port, 6768)
        model.origin = "https://draft.example.test"
        model.port = 7777
        await model.reload()
        XCTAssertEqual(model.origin, "https://draft.example.test")
        XCTAssertEqual(model.port, 7777)
    }
}

@MainActor
private final class CompanionStub: CompanionControlling {
    var fail = false
    var issueCount = 0
    var enabled = true
    var origin = "https://host.example.test"
    var mode: CompanionConnectionMode = .proxy
    var addresses: [CompanionNetworkAddress] = []
    var endpoints: [CompanionEndpoint]?
    var issued: [CompanionDevice] = []
    var suspendIssuance = false
    var pending: CheckedContinuation<Void, Never>?

    func status() async throws -> CompanionStatus {
        if fail { throw CompanionFailure.hostUnavailable }
        return CompanionStatus(enabled: enabled, listen: "127.0.0.1:6768", publicUrl: origin, mode: mode, addresses: addresses, endpoints: endpoints)
    }
    func configure(enabled: Bool, origin: String, port: Int, mode: CompanionConnectionMode, address: String) async throws -> CompanionStatus {
        if fail { throw CompanionFailure.hostUnavailable }
        self.enabled = enabled
        self.mode = mode
        self.origin = mode == .proxy ? origin : "https://\(address):\(port)"
        if endpoints != nil {
            endpoints?.removeAll { $0.mode == mode }
            endpoints?.append(.init(enabled: enabled, listen: "\(address):\(port)", publicUrl: self.origin, mode: mode))
        }
        return try await status()
    }
    func devices() async throws -> [CompanionDevice] { issued }
    func issue(label: String, origin: String) async throws -> CompanionPairing {
        issueCount += 1
        if fail { throw CompanionFailure.hostUnavailable }
        if suspendIssuance { await withCheckedContinuation { pending = $0 } }
        let device = CompanionDevice(id: "phone-\(issueCount)", label: label, scope: "read", expiresAt: .now.addingTimeInterval(3600))
        issued.append(device)
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["pairing_version": 2, "origin": origin, "host_name": "Test Mac", "host_id": "host-fixture", "client_id": device.id, "token": String(repeating: "x", count: 93), "expires_at": "2030-01-01T00:00:00Z", "certificate": Data([1]).base64EncodedString()]), as: UTF8.self)
        return CompanionPairing(device: device, origin: origin, token: "synthetic-token", payload: payload)
    }
    func revoke(id: String) async throws { issued.removeAll { $0.id == id } }
    func completeIssuance() { pending?.resume(); pending = nil; suspendIssuance = false }
}

@MainActor
private struct NoCopyPasteboard: PasteboardWriting {
    func copy(_ value: String) { XCTFail("Rendering must not copy a credential") }
}
