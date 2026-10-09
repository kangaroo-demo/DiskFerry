import Foundation
import ServiceManagement
import Testing
@testable import DiskFerryApp

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var isAvailable = true
    var status = SMAppService.Status.notRegistered
    var registeredStatus = SMAppService.Status.enabled
    var registerCount = 0
    var unregisterCount = 0
    var settingsCount = 0
    var failure: Error?
    var unregisterWaiter: CheckedContinuation<Void, Never>?
    var delayUnregister = false

    func register() throws {
        registerCount += 1
        if let failure { throw failure }
        status = registeredStatus
    }
    func unregister() async throws {
        unregisterCount += 1
        if delayUnregister {
            await withCheckedContinuation { unregisterWaiter = $0 }
        }
        if let failure { throw failure }
        status = .notRegistered
    }
    func openSystemSettings() { settingsCount += 1 }
}

@Test @MainActor func launchDoesNotRegisterAutomaticallyAndToggleUsesSystemState() async {
    let service = FakeLoginItemService()
    let controller = LoginItemController(isDemo: false, service: service)
    #expect(!controller.isEnabled)
    #expect(service.registerCount == 0)
    await controller.setEnabled(true)
    #expect(controller.isEnabled)
    #expect(service.registerCount == 1)
    await controller.setEnabled(true)
    #expect(service.registerCount == 1)
    await controller.setEnabled(false)
    #expect(!controller.isEnabled)
    #expect(service.unregisterCount == 1)
    await controller.setEnabled(false)
    #expect(service.unregisterCount == 1)
}

@Test @MainActor func loginItemReflectsExternalChangesWithoutReregistering() async {
    let service = FakeLoginItemService()
    service.status = .enabled
    let controller = LoginItemController(isDemo: false, service: service)
    #expect(controller.isEnabled)
    service.status = .requiresApproval
    controller.refresh()
    #expect(!controller.isEnabled)
    #expect(controller.requiresApproval)
    await controller.setEnabled(true)
    #expect(service.settingsCount == 1)
    #expect(service.registerCount == 0)
    #expect(!controller.isEnabled)
    await controller.setEnabled(false)
    #expect(service.unregisterCount == 1)
    #expect(!controller.requiresApproval)
}

@Test @MainActor func approvalPendingNeverReportsLoginEnabled() async {
    let service = FakeLoginItemService()
    service.registeredStatus = .requiresApproval
    let controller = LoginItemController(isDemo: false, service: service)
    await controller.setEnabled(true)
    #expect(controller.requiresApproval)
    #expect(!controller.isEnabled)
    #expect(controller.errorMessage == nil)
    service.status = .enabled
    controller.refresh()
    #expect(controller.isEnabled)
}

@Test @MainActor func aMainAppWithoutAPreviousLoginItemCanRegister() async {
    // macOS can return notFound before this app has ever registered a login item.
    let service = FakeLoginItemService()
    service.status = .notFound
    let controller = LoginItemController(isDemo: false, service: service)
    #expect(controller.canChange)
    await controller.setEnabled(true)
    #expect(service.registerCount == 1)
    #expect(controller.isEnabled)
}

@Test @MainActor func failedRegistrationAndRemovalKeepActualSystemStatus() async {
    let service = FakeLoginItemService()
    service.failure = NSError(domain: "LoginItemTest", code: 1)
    let controller = LoginItemController(isDemo: false, service: service)
    await controller.setEnabled(true)
    #expect(!controller.isEnabled)
    #expect(controller.errorMessage != nil)
    #expect(!controller.isUpdating)
    service.status = .enabled
    await controller.setEnabled(false)
    #expect(controller.isEnabled)
    #expect(controller.errorMessage != nil)
    #expect(!controller.isUpdating)
}

@Test @MainActor func demoCannotChangeOrInspectLoginItems() async {
    let service = FakeLoginItemService()
    service.status = .enabled
    let controller = LoginItemController(isDemo: true, service: service)
    await controller.setEnabled(true)
    await controller.setEnabled(false)
    controller.refresh()
    controller.openSystemSettings()
    #expect(!controller.isEnabled)
    #expect(!controller.canChange)
    #expect(service.registerCount == 0)
    #expect(service.unregisterCount == 0)
    #expect(service.settingsCount == 0)
    #expect(service.status == .enabled)
}

@Test @MainActor func bareExecutableCannotRegisterAMainAppLoginItem() async {
    let service = FakeLoginItemService()
    service.isAvailable = false
    let controller = LoginItemController(isDemo: false, service: service)
    await controller.setEnabled(true)
    controller.openSystemSettings()
    #expect(!controller.canChange)
    #expect(service.registerCount == 0)
    #expect(service.settingsCount == 0)
}

@Test @MainActor func pendingUnregisterSerializesRepeatedToggleRequests() async {
    let service = FakeLoginItemService()
    service.status = .enabled
    service.delayUnregister = true
    let controller = LoginItemController(isDemo: false, service: service)
    let removal = Task { await controller.setEnabled(false) }
    while service.unregisterWaiter == nil { await Task.yield() }
    #expect(controller.isUpdating)
    #expect(!controller.canChange)
    await controller.setEnabled(true)
    #expect(service.registerCount == 0)
    service.unregisterWaiter?.resume()
    await removal.value
    #expect(!controller.isEnabled)
    #expect(!controller.isUpdating)
    #expect(service.unregisterCount == 1)
}
