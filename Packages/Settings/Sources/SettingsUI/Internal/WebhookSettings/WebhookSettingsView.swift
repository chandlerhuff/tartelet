import Foundation
import GitHubDomain
import Observation
import SettingsDomain
import SwiftUI

struct WebhookSettingsView<SettingsStoreType: SettingsStore & Observable>: View {
    @Bindable var settingsStore: SettingsStoreType
    let isSettingsEnabled: Bool

    @State private var webhookPort = ""
    @State private var netBridgedAdapter = ""

    var body: some View {
        Form {
            Section {
                TextField(L10n.Settings.Webhook.port, text: $webhookPort)
                    .disabled(!isSettingsEnabled)
                Text(L10n.Settings.Webhook.Port.subtitle)
                Toggle(isOn: $settingsStore.insecurePull) {
                    Text(L10n.Settings.Webhook.insecurePulls)
                }
                .disabled(!isSettingsEnabled)
                TextField(L10n.Settings.Webhook.netBridgedAdapter, text: $netBridgedAdapter)
                    .disabled(!isSettingsEnabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            webhookPort = settingsStore.webhookPort ?? ""
            netBridgedAdapter = settingsStore.netBridgedAdapter ?? ""
        }
        .onChange(of: webhookPort) { _, newValue in
            guard !newValue.isEmpty, Int(newValue) != nil else {
                settingsStore.webhookPort = nil
                return
            }
            settingsStore.webhookPort = newValue
        }
        .onChange(of: netBridgedAdapter) { _, newValue in
            guard !newValue.isEmpty else {
                settingsStore.netBridgedAdapter = nil
                return
            }
            settingsStore.netBridgedAdapter = newValue
        }
    }
}
