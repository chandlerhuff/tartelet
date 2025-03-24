import Foundation
import LoggingDomain
import WebhookServer

struct ActiveJob {
    let labels: Set<String>
    let task: Task<(), Never>
}

actor JobHandler {
    private var numberOfMachines = 1
    private var activeJobs = [UUID: ActiveJob]()
    private var pendingJobs = [Int: PendingJob]()
    private nonisolated let virtualMachineProvider: VirtualMachineProvider
    private nonisolated let logger: Logger

    init(virtualMachineProvider: VirtualMachineProvider, logger: Logger) {
        self.virtualMachineProvider = virtualMachineProvider
        self.logger = logger
    }

    func set(numberOfMachines: Int) {
        self.numberOfMachines = numberOfMachines
    }

    func handle(pendingJob: PendingJob) {
        switch pendingJob.action {
        case .waiting, .unknown:
            break
        case .queued:
            logger.info("Pending job added: \(pendingJob.id)")
            pendingJobs[pendingJob.id] = pendingJob

            if activeJobs.count < numberOfMachines {
                start(pendingJob: pendingJob)
            }
        case .inProgress:
            pendingJobs.removeValue(forKey: pendingJob.id)
        case .completed:
            guard pendingJobs[pendingJob.id] != nil else {
                return
            }
            pendingJobs.removeValue(forKey: pendingJob.id)
            let otherPending = pendingJobs.values.filter { existingJob in
                existingJob.workflowJob.labels == pendingJob.workflowJob.labels
            }.count
            if otherPending == 0 {
                activeJobs.forEach { _, activeJob in
                    guard activeJob.labels == pendingJob.workflowJob.labels else {
                        return
                    }
                    activeJob.task.cancel()
                }
            } else {
                pendingJobs.values.first { existingJob in
                    existingJob.workflowJob.labels == pendingJob.workflowJob.labels
                }?.didStart = true
            }
        }
    }

    func cancelAll() {
        for (_, job) in activeJobs {
            job.task.cancel()
        }
    }

    private func start(pendingJob: PendingJob) {
        func runVirtualMachine(_ virtualMachine: VirtualMachine, netBridgedAdapter: String?, isHeadless: Bool) async throws {
        }

        logger.info("Starting job: \(pendingJob.workflowJob.id)")
        pendingJob.didStart = true
        let runnerLabels = pendingJob.workflowJob.labels.joined(separator: ",")
        let uuid = UUID()
        let task = Task { [weak self, logger, virtualMachineProvider] in
            do {
                logger.info("Creating virtual with image \(pendingJob.imageName)")
                let virtualMachine = try await virtualMachineProvider.createVirtualMachine(
                    imageName: pendingJob.imageName,
                    name: "tartelet-temp-\(uuid.uuidString)",
                    runnerLabels: runnerLabels,
                    isInsecure: pendingJob.isInsecure,
                    memory: pendingJob.memory,
                    cpu: pendingJob.cpu
                )

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
                        try await virtualMachine.start(netBridgedAdapter: pendingJob.netBridgedAdapter, isHeadless: pendingJob.isHeadless)
                        logger.info("Did stop virtual machine named \(virtualMachine.name)")
                        try await delete()
                    } catch {
                        logger.info("Virtual machine named \(virtualMachine.name) stopped with message: " + error.localizedDescription)
                        try await delete()
                        throw error
                    }
                } onCancel: {
                    Task.detached(priority: .high) {
                        logger.info("Cancel virtual machine named \(virtualMachine.name)")
                        do {
                            try await virtualMachine.delete()
                        } catch {
                            logger.info("Could not delete virtual machine named \(virtualMachine.name): " + error.localizedDescription)
                            throw error
                        }
                    }
                }

                await self?.remove(uuid: uuid)
            } catch {
                logger.error(error.localizedDescription)
                await self?.remove(uuid: uuid)
            }
        }

        activeJobs[uuid]?.task.cancel()
        activeJobs[uuid] = .init(labels: pendingJob.workflowJob.labels, task: task)
    }

    private func remove(uuid: UUID) {
        activeJobs.removeValue(forKey: uuid)
        if activeJobs.count < numberOfMachines, let pendingJob = pendingJobs.first(where: { !$0.value.didStart })?.value {
            start(pendingJob: pendingJob)
        }
    }
}
