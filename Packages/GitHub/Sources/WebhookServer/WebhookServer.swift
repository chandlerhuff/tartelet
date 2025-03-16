import Combine
import FlyingFox
import Foundation
import GitHubDomain

public struct WorkflowJob: Codable, Identifiable, Hashable {
    public let id: Int
    public let action: WorkflowAction
    public let labels: [String]

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum WorkflowAction: String {
    case queued
    case completed
    case unknown
}

extension WorkflowAction: Codable {
    public init(from decoder: Decoder) throws {
        self = try WorkflowAction(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

struct WebhookResponse: Codable {
    struct WorkflowJobResponse: Codable, Identifiable {
        let id: Int
        let labels: [String]
    }

    let action: WorkflowAction
    let workflow_job: WorkflowJobResponse
}

public final class WebhookServer {
    private let decoder = JSONDecoder()
    private let workflowJobSubject = PassthroughSubject<WorkflowJob, Never>()

    public var workflowJobPublisher: AnyPublisher<WorkflowJob, Never> {
        workflowJobSubject.eraseToAnyPublisher()
    }

    public init() {
    }

    public func run(port: Int) async throws {
        let server = HTTPServer(port: UInt16(port))
        await server.appendRoute("POST /") { [weak self] request in
            guard let self else {
                return .init(statusCode: .badGateway)
            }
            do {
                let bodyData = try await request.bodyData
                let string = String(data: bodyData, encoding: .utf8)
                guard let string else {
                    return .init(statusCode: .ok)
                }
                print("New Request: \(string)")
                let webhookResponse = try decoder.decode(WebhookResponse.self, from: bodyData)
                let workflowJob = WorkflowJob(
                    id: webhookResponse.workflow_job.id,
                    action: webhookResponse.action,
                    labels: webhookResponse.workflow_job.labels
                )
                workflowJobSubject.send(workflowJob)
            } catch {
                print("Error: \(error)")
                throw error
            }
            return .init(statusCode: .ok)
        }
        try await server.run()
    }
}
