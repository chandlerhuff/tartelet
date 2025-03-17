import Foundation
import VirtualMachineDomain

public final class TartVirtualMachine: VirtualMachine {
    public var name: String {
        vmName
    }
    public var canStart: Bool {
        true
    }

    private let tart: Tart
    private let vmName: String
    public let runnerLabels: String?

    public init(tart: Tart, vmName: String, runnerLabels: String? = nil) {
        self.tart = tart
        self.vmName = vmName
        self.runnerLabels = runnerLabels
    }

    public func start(netBridgedAdapter: String?) async throws {
        try await tart.run(name: vmName, netBridgedAdapter: netBridgedAdapter)
    }

    public func clone(named newName: String, isInsecure: Bool) async throws -> VirtualMachine {
        try await tart.clone(sourceName: name, newName: newName, isInsecure: isInsecure)
        return TartVirtualMachine(tart: tart, vmName: newName, runnerLabels: runnerLabels)
    }

    public func delete() async throws {
        try await tart.delete(name: name)
    }

    public func getIPAddress(shouldUseArpResolver: Bool) async throws -> String {
        try await tart.getIPAddress(ofVirtualMachineNamed: name, shouldUseArpResolver: shouldUseArpResolver)
    }
}
