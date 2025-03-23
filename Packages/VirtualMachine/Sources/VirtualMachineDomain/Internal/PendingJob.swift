import Foundation
import WebhookServer

struct PendingJob {
    let workflowJob: WorkflowJob
    let imageName: String
    let netBridgedAdapter: String?
    let isInsecure: Bool
    let isHeadless: Bool
    let memory: String?
    let cpu: String?
}
