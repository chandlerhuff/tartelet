import Foundation
import LoggingDomain
import WebhookServer

actor JobHandler {
    private var numberOfMachines = 1
    private var activeTasks: [Int: Task<(), Never>] = [:]
    private var pendingJobs = [PendingJob]()
    private nonisolated let virtualMachineProvider: VirtualMachineProvider
    private nonisolated let logger: Logger

    init(virtualMachineProvider: VirtualMachineProvider, logger: Logger) {
        self.virtualMachineProvider = virtualMachineProvider
        self.logger = logger
    }

    func set(numberOfMachines: Int) {
        self.numberOfMachines = numberOfMachines
    }

    func add(pendingJob: PendingJob) {
        if activeTasks.count < numberOfMachines {
            start(pendingJob: pendingJob)
        } else {
            logger.info("Pending job added: \(pendingJob.workflowJob.id)")
            pendingJobs.append(pendingJob)
        }
    }

    func cancel(workflowJob: WorkflowJob) {
        activeTasks[workflowJob.id]?.cancel()
    }

    func cancelAll() {
        for (_, task) in activeTasks {
            task.cancel()
        }
    }

    private func start(pendingJob: PendingJob) {
        logger.info("Starting job: \(pendingJob.workflowJob.id)")
        let runnerLabels = pendingJob.workflowJob.labels.joined(separator: ",")
        let task = Task {
            do {
                logger.info("Creating virtual with image \(pendingJob.imageName)")
                let virtualMachine = try await virtualMachineProvider.createVirtualMachine(
                    imageName: pendingJob.imageName,
                    name: "tartelet-temp-\(pendingJob.workflowJob.id)",
                    runnerLabels: runnerLabels,
                    isInsecure: pendingJob.isInsecure
                )
                try await runVirtualMachine(
                    virtualMachine,
                    netBridgedAdapter: pendingJob.netBridgedAdapter,
                    isHeadless: pendingJob.isHeadless
                )
                remove(workflowJob: pendingJob.workflowJob)
            } catch {
                logger.error(error.localizedDescription)
                remove(workflowJob: pendingJob.workflowJob)
            }
        }
        activeTasks[pendingJob.workflowJob.id]?.cancel()
        activeTasks[pendingJob.workflowJob.id] = task
    }

    private func runVirtualMachine(_ virtualMachine: VirtualMachine, netBridgedAdapter: String?, isHeadless: Bool) async throws {
        func delete() async throws {
            do {
                try await virtualMachine.delete()
                logger.info("Did delete virtual machine named \(virtualMachine.name)")
            } catch {
                logger.info("Could not delete virtual machine named \(virtualMachine.name)")
                throw error
            }
        }

        try await withTaskCancellationHandler {
            logger.info("Start virtual machine named \(virtualMachine.name)")
            do {
                try await virtualMachine.start(netBridgedAdapter: netBridgedAdapter, isHeadless: isHeadless)
                logger.info("Did stop virtual machine named \(virtualMachine.name)")
                try await delete()
            } catch {
                logger.info("Virtual machine named \(virtualMachine.name) stopped with message: " + error.localizedDescription)
                try await delete()
                throw error
            }
        } onCancel: {
            Task.detached(priority: .high) {
                self.logger.info("Cancel virtual machine named \(virtualMachine.name)")
                do {
                    try await virtualMachine.delete()
                } catch {
                    self.logger.info("Could not delete virtual machine named \(virtualMachine.name): " + error.localizedDescription)
                    throw error
                }
            }
        }
    }

    private func remove(workflowJob: WorkflowJob) {
        activeTasks.removeValue(forKey: workflowJob.id)
        if activeTasks.count < numberOfMachines, !pendingJobs.isEmpty {
            let pendingJob = pendingJobs.removeFirst()
            start(pendingJob: pendingJob)
        }
    }
}
