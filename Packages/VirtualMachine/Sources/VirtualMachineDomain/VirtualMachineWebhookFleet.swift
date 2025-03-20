import Combine
import Foundation
import LoggingDomain
import Observation
import WebhookServer

@Observable
public final class VirtualMachineFleetWebhook {
    @MainActor
    public private(set) var isStarted = false
    @MainActor
    public private(set) var isStopping = false

    private let logger: Logger
    private let webhookServer: WebhookServer
    private let virtualMachineProvider: VirtualMachineProvider
    private var webhookServerTask: Task<(), any Error>?
    private var activeTasks: [WorkflowJob: Task<(), Never>] = [:]
    private var numberOfMachines = 0
    private var gitHubRunnerLabels: String?
    private var isInsecure = false
    private var isHeadless = false
    private var netBridgedAdapter: String?
    private var cancellables = Set<AnyCancellable>()

    public init(logger: Logger, webhookServer: WebhookServer, virtualMachineProvider: VirtualMachineProvider) {
        self.logger = logger
        self.webhookServer = webhookServer
        self.virtualMachineProvider = virtualMachineProvider

        webhookServer.workflowJobPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] workflowJob in
                Task { [weak self] in
                    guard let self, await isStarted else {
                        return
                    }
                    handleWorkflowJob(workflowJob)
                }
            }
            .store(in: &cancellables)
    }

    @MainActor
    // swiftlint:disable:next function_parameter_count
    public func start(
        numberOfMachines: Int,
        gitHubRunnerLabels: String,
        webhookPort: Int?,
        isInsecure: Bool,
        isHeadless: Bool,
        netBridgedAdapter: String?
    ) {
        self.isInsecure = isInsecure
        self.isHeadless = isHeadless
        self.netBridgedAdapter = netBridgedAdapter
        guard let webhookPort else {
            logger.error("Starting without webhook port")
            return
        }
        guard !isStarted else {
            return
        }
        self.numberOfMachines = numberOfMachines
        self.gitHubRunnerLabels = gitHubRunnerLabels

        webhookServerTask = Task { [webhookServer] in
            logger.info("Starting web server on port: \(webhookPort)")
            try await webhookServer.run(port: webhookPort)
            isStarted = false
        }
        isStarted = true
    }

    @MainActor
    public func stopImmediately() {
        isStarted = false
        isStopping = false
        webhookServerTask?.cancel()
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks = [:]
    }

    @MainActor
    public func stop() {
        guard isStarted else {
            return
        }
        isStopping = true
        Task {
            await webhookServer.stop()
            webhookServerTask?.cancel()
            isStopping = false
            isStarted = false
        }
    }
}

private extension VirtualMachineFleetWebhook {
    func handleWorkflowJob(_ workflowJob: WorkflowJob) {
        guard let gitHubRunnerLabels,
              workflowJob.labels.contains(gitHubRunnerLabels),
              workflowJob.labels.count == 2,
              workflowJob.action == .queued,
              let imageName = workflowJob.labels.first(where: { $0 != gitHubRunnerLabels }) else {
            return
        }
        let runnerLabels = workflowJob.labels.joined(separator: ",")
        let count = activeTasks.count
        let task = Task {
            do {
                let virtualMachine = try await virtualMachineProvider.createVirtualMachine(
                    imageName: imageName,
                    name: "tartelet-temp-\(count + 1)",
                    runnerLabels: runnerLabels,
                    isInsecure: isInsecure
                )
                try await runVirtualMachine(virtualMachine, netBridgedAdapter: netBridgedAdapter)
                activeTasks.removeValue(forKey: workflowJob)
            } catch {
                logger.error(error.localizedDescription)
                activeTasks.removeValue(forKey: workflowJob)
            }
        }
        activeTasks[workflowJob]?.cancel()
        activeTasks[workflowJob] = task
    }

    func runVirtualMachine(_ virtualMachine: VirtualMachine, netBridgedAdapter: String?) async throws {
        try await withTaskCancellationHandler {
            logger.info("Start virtual machine named \(virtualMachine.name)")
            do {
                try await virtualMachine.start(netBridgedAdapter: netBridgedAdapter, isHeadless: isHeadless)
                logger.info("Did stop virtual machine named \(virtualMachine.name)")
                do {
                    try await virtualMachine.delete()
                    logger.info("Did delete virtual machine named \(virtualMachine.name)")
                } catch {
                    logger.info("Could not delete virtual machine named \(virtualMachine.name)")
                    throw error
                }
            } catch {
                logger.info(
                    "Virtual machine named \(virtualMachine.name) stopped with message: "
                    + error.localizedDescription
                )
                throw error
            }
        } onCancel: {
            Task.detached(priority: .high) {
                self.logger.info("Stop virtual machine named \(virtualMachine.name)")
                do {
                    try await virtualMachine.delete()
                } catch {
                    self.logger.info(
                        "Could not delete virtual machine named \(virtualMachine.name): "
                        + error.localizedDescription
                    )
                    throw error
                }
            }
        }
    }
}
