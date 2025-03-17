import Foundation

public protocol VirtualMachine {
    var name: String { get }
    var canStart: Bool { get }
    var runnerLabels: String? { get }
    func start(netBridgedAdapter: String?) async throws
    func clone(named newName: String, isInsecure: Bool) async throws -> VirtualMachine
    func delete() async throws
    func getIPAddress() async throws -> String
}
