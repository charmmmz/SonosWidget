import SwiftUI

struct MusicAmbienceSetupPresentationState: Equatable {
    var isPresented = false

    mutating func present() {
        isPresented = true
    }

    mutating func dismiss() {
        isPresented = false
    }
}

@MainActor
struct MusicAmbienceSettingsSyncActions {
    let refreshStatus: () -> Void
    let canSyncToRelay: () -> Bool
    let syncToRelay: () async -> Void

    func enabledChanged() async {
        refreshStatus()
        guard canSyncToRelay() else { return }
        await syncToRelay()
    }

    func syncableSettingChanged() async {
        guard canSyncToRelay() else { return }
        await syncToRelay()
    }

    func groupPlaybackChanged() async {
        await syncableSettingChanged()
    }

    func stopBehaviorChanged() async {
        await syncableSettingChanged()
    }
}

struct MusicAmbienceSettingsView: View {
    @Bindable var store: HueAmbienceStore
    @Bindable var manager: MusicAmbienceManager
    let sonosSpeakers: [SonosPlayer]
    let presentSetup: () -> Void
    @Bindable private var relay = RelayManager.shared

    var body: some View {
        Section {
            statusRow

            Toggle("Enable Music Ambience", isOn: $store.isEnabled)
                .disabled(store.bridge == nil || store.mappings.isEmpty)

            Button {
                presentSetup()
            } label: {
                Label(
                    store.bridge == nil ? "Set Up Hue Bridge" : "Edit Hue Assignments",
                    systemImage: "sparkles"
                )
            }

            if store.bridge != nil {
                Picker("Group Playback", selection: $store.groupStrategy) {
                    ForEach(HueGroupSyncStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.label).tag(strategy)
                    }
                }

                Picker("When Playback Stops", selection: $store.stopBehavior) {
                    ForEach(HueAmbienceStopBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }

                Picker("Light Motion Speed", selection: $store.flowSpeed) {
                    ForEach(HueAmbienceFlowSpeed.allCases, id: \.self) { flowSpeed in
                        Text(flowSpeed.label).tag(flowSpeed)
                    }
                }

                Button {
                    Task {
                        await relay.pushHueAmbienceConfig(
                            store: store,
                            sonosSpeakers: sonosSpeakers
                        )
                    }
                } label: {
                    Label("Sync to NAS Relay", systemImage: "server.rack")
                }
                .disabled(!canSyncToRelay)

                Text(nasRelayStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Hue Music Ambience")
        } footer: {
            Text("Uses album artwork colors for Hue ambience. Without a NAS, continuous background syncing is limited by iOS.")
        }
        .onChange(of: store.isEnabled) {
            let actions = syncActions
            Task {
                await actions.enabledChanged()
            }
        }
        .onChange(of: store.flowSpeed) {
            let actions = syncActions
            Task {
                await actions.syncableSettingChanged()
            }
        }
        .onChange(of: store.groupStrategy) {
            let actions = syncActions
            Task {
                await actions.groupPlaybackChanged()
            }
        }
        .onChange(of: store.stopBehavior) {
            let actions = syncActions
            Task {
                await actions.stopBehaviorChanged()
            }
        }
    }

    private var syncActions: MusicAmbienceSettingsSyncActions {
        MusicAmbienceSettingsSyncActions(
            refreshStatus: {
                manager.refreshStatus()
            },
            canSyncToRelay: {
                canSyncToRelay
            },
            syncToRelay: {
                await relay.pushHueAmbienceConfig(
                    store: store,
                    sonosSpeakers: sonosSpeakers
                )
            }
        )
    }

    private var canSyncToRelay: Bool {
        relay.url != nil
            && store.bridge != nil
            && !store.mappings.isEmpty
            && relay.hueAmbienceSyncStatus != .syncing
    }

    private var nasRelayStatusText: String {
        switch relay.hueAmbienceSyncStatus {
        case .synced(let date):
            return "NAS Relay has the current Music Ambience config · \(date.formatted(date: .omitted, time: .shortened))"
        case .syncing:
            return "Uploading Bridge credentials and Hue assignments to your local relay..."
        case .failed(let reason):
            return "NAS Relay sync failed: \(reason)"
        case .idle:
            if relay.url == nil {
                return "Set a NAS Relay URL below, then sync this Hue setup so Docker can run the light effect."
            }
            return "Sync sends the Hue app key and assignments to your local NAS Relay."
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title3)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.status.title)
                    .font(.subheadline.weight(.semibold))
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusIcon: String {
        switch manager.status {
        case .disabled:
            return "lightswitch.off"
        case .unconfigured:
            return "link.badge.plus"
        case .idle:
            return "checkmark.circle.fill"
        case .syncing:
            return "sparkles"
        case .paused:
            return "pause.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch manager.status {
        case .syncing, .idle:
            return .green
        case .paused, .unconfigured:
            return .orange
        case .error:
            return .red
        case .disabled:
            return .secondary
        }
    }

    private var statusSubtitle: String {
        if let bridge = store.bridge {
            return "\(bridge.name) · \(store.mappings.count) assignment\(store.mappings.count == 1 ? "" : "s")"
        }
        return "Pair a Hue Bridge and assign Entertainment Areas to Sonos rooms."
    }
}

struct HueAmbienceSetupSheet: View {
    @Bindable var store: HueAmbienceStore
    @Bindable var manager: MusicAmbienceManager
    let sonosSpeakers: [SonosPlayer]

    @Environment(\.dismiss) private var dismiss
    @State private var bridgeIP = ""
    @State private var bridgeName = "Hue Bridge"
    @State private var discoveredBridges: [HueBridgeInfo] = []
    @State private var selectedBridgeID = ""
    @State private var hueAreas: [HueAreaResource] = []
    @State private var hueLights: [HueLightResource] = []
    @State private var setupError: String?
    @State private var isBusy = false
    @State private var isManualBridgeExpanded = false

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                assignmentsSection
                effectSection
            }
            .navigationTitle("Music Ambience")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        manager.refreshStatus()
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadStoredBridgeState()
            }
        }
    }

    private var connectionSection: some View {
        Section {
            if let bridge = store.bridge {
                LabeledContent("Bridge", value: "\(bridge.name) · \(bridge.ipAddress)")
                LabeledContent("Hue Areas", value: "\(assignmentAreas.count)")
            }

            HStack {
                Button {
                    Task { await findHueBridges() }
                } label: {
                    Label("Find", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)

                if store.bridge != nil {
                    Spacer()

                    Button {
                        Task { await refreshHueResources() }
                    } label: {
                        Label("Refresh Areas", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBusy)
                }
            }

            if !discoveredBridges.isEmpty {
                Picker("Discovered Bridge", selection: $selectedBridgeID) {
                    ForEach(discoveredBridges) { bridge in
                        Text("\(bridge.name) · \(bridge.ipAddress)").tag(bridge.id)
                    }
                }

                Button {
                    Task { await pairSelectedBridge() }
                } label: {
                    Label("Pair Selected Bridge", systemImage: "link.badge.plus")
                }
                .disabled(selectedBridge == nil || isBusy)
            }

            DisclosureGroup("Manual IP", isExpanded: $isManualBridgeExpanded) {
                TextField("192.168.1.20", text: $bridgeIP)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Hue Bridge", text: $bridgeName)
                Button {
                    Task { await pairManualBridge() }
                } label: {
                    Label("Pair Manual Bridge", systemImage: "link")
                }
                .disabled(manualBridge == nil || isBusy)
            }

            if isBusy {
                ProgressView()
            }

            if let setupError {
                Text(setupError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Use Find on the same Wi-Fi network, or expand Manual IP. Press the Hue Bridge link button before pairing.")
        }
    }

    private var assignmentsSection: some View {
        Section {
            if sonosSpeakers.isEmpty {
                Text("Connect Sonos speakers before assigning Hue areas.")
                    .foregroundStyle(.secondary)
            } else if assignmentAreas.isEmpty {
                Text("Pair or refresh the Hue Bridge to load assignable areas.")
                    .foregroundStyle(.secondary)
            } else {
                if !hueAreas.contains(where: { $0.kind == .entertainmentArea }) {
                    Text("No Entertainment Areas found. Rooms and Zones are available as fallback targets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(sonosSpeakers) { speaker in
                    HueMappingRow(
                        store: store,
                        manager: manager,
                        speaker: speaker,
                        areas: assignmentAreas,
                        lights: hueLights
                    )
                }
            }
        } header: {
            Text("Speaker Assignments")
        } footer: {
            Text("Choosing an area saves immediately. Entertainment Areas are preferred; Rooms and Zones appear only when no Entertainment Area exists.")
        }
    }

    private var effectSection: some View {
        Section("Effect") {
            Picker("Light Motion", selection: $store.motionStyle) {
                ForEach(HueAmbienceMotionStyle.allCases, id: \.self) { motionStyle in
                    Text(motionStyle.label).tag(motionStyle)
                }
            }

            Text(store.motionStyle.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Live Entertainment", value: HueLiveEntertainmentRuntimeStatus.unavailable.reason)
            Text("Beat-synced Entertainment streaming still needs the NAS runtime. App-only mode uses slow Hue transitions while Charm Player is active.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedBridge: HueBridgeInfo? {
        discoveredBridges.first { $0.id == selectedBridgeID }
    }

    private var assignmentAreas: [HueAreaResource] {
        HueAmbienceAreaOptions.displayAreas(from: hueAreas)
    }

    private var manualBridge: HueBridgeInfo? {
        let trimmedIP = bridgeIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIP.isEmpty else {
            return nil
        }

        let trimmedName = bridgeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bridgeID = store.bridge?.ipAddress == trimmedIP
            ? store.bridge?.id ?? trimmedIP.replacingOccurrences(of: ".", with: "-")
            : trimmedIP.replacingOccurrences(of: ".", with: "-")

        return HueBridgeInfo(
            id: bridgeID,
            ipAddress: trimmedIP,
            name: trimmedName.isEmpty ? "Hue Bridge" : trimmedName
        )
    }

    private func loadStoredBridgeState() {
        guard let bridge = store.bridge else {
            return
        }

        bridgeIP = bridge.ipAddress
        bridgeName = bridge.name
        mergeDiscoveredBridge(bridge)
        hueAreas = store.hueAreas
        hueLights = store.hueLights

        if hueAreas.isEmpty || store.hueResources.needsFunctionMetadataRefresh {
            Task { await refreshHueResources() }
        }
    }

    private func findHueBridges() async {
        setupError = nil
        isBusy = true
        defer { isBusy = false }

        let bridges = await HueBridgeDiscovery.discoverLocal()
        discoveredBridges = bridges
        if let bridge = store.bridge {
            mergeDiscoveredBridge(bridge)
        }
        selectedBridgeID = selectedBridgeID.isEmpty ? discoveredBridges.first?.id ?? "" : selectedBridgeID
        if discoveredBridges.isEmpty {
            setupError = "No Hue Bridge was found on this local network. " +
                "Make sure Local Network access is allowed and this iPhone is on the same Wi-Fi as the Bridge, " +
                "or pair manually with the Bridge IP."
        }
    }

    private func pairSelectedBridge() async {
        guard let selectedBridge else {
            return
        }

        await pairAndFetchResources(for: selectedBridge)
    }

    private func pairManualBridge() async {
        guard let bridge = manualBridge else {
            return
        }

        await pairAndFetchResources(for: bridge)
    }

    private func pairAndFetchResources(for bridge: HueBridgeInfo) async {
        setupError = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let client = HueBridgeClient(bridge: bridge)
            _ = try await client.pairBridge(deviceType: "Charm Player#iPhone")
            store.bridge = bridge
            hueAreas = store.hueAreas
            hueLights = store.hueLights
            bridgeIP = bridge.ipAddress
            bridgeName = bridge.name
            mergeDiscoveredBridge(bridge)
            manager.refreshStatus()

            let resources = try await client.fetchResources()
            guard store.updateResources(resources, forBridgeID: bridge.id) else {
                return
            }
            hueAreas = resources.areas
            hueLights = resources.lights
            manager.refreshStatus()
        } catch {
            setupError = error.localizedDescription
            manager.refreshStatus()
        }
    }

    private func refreshHueResources() async {
        guard let bridge = store.bridge else {
            return
        }

        setupError = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let resources = try await HueBridgeClient(bridge: bridge).fetchResources()
            guard store.updateResources(resources, forBridgeID: bridge.id) else {
                return
            }
            hueAreas = resources.areas
            hueLights = resources.lights
        } catch {
            setupError = error.localizedDescription
        }
    }

    private func mergeDiscoveredBridge(_ bridge: HueBridgeInfo) {
        if let index = discoveredBridges.firstIndex(where: { $0.id == bridge.id }) {
            discoveredBridges[index] = bridge
        } else {
            discoveredBridges.append(bridge)
        }

        selectedBridgeID = bridge.id
    }
}

private struct HueMappingRow: View {
    @Bindable var store: HueAmbienceStore
    @Bindable var manager: MusicAmbienceManager
    let speaker: SonosPlayer
    let areas: [HueAreaResource]
    let lights: [HueLightResource]

    @State private var isLightSelectionExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(speaker.name)
                        .font(.subheadline.weight(.semibold))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Menu {
                    ForEach(areas) { area in
                        Button {
                            saveArea(area)
                        } label: {
                            if currentArea?.id == area.id {
                                Label(areaMenuTitle(area), systemImage: "checkmark")
                            } else {
                                Text(areaMenuTitle(area))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentArea?.name ?? "Choose")
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
            }

            if !areaLights.isEmpty {
                DisclosureGroup("Lights", isExpanded: $isLightSelectionExpanded) {
                    ForEach(areaLights) { light in
                        Toggle(isOn: Binding(
                            get: { isLightEnabled(light) },
                            set: { setLight(light, isEnabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(light.name)
                                Text(light.function.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .font(.caption)
            }

            if store.mapping(forSonosID: speaker.id) != nil {
                Button(role: .destructive) {
                    removeAssignment()
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private var currentMapping: HueSonosMapping? {
        store.mapping(forSonosID: speaker.id)
    }

    private var currentArea: HueAreaResource? {
        guard let target = currentMapping?.preferredTarget else {
            return nil
        }
        return areas.first { $0.ambienceTarget == target }
    }

    private var areaLights: [HueLightResource] {
        guard let currentArea else {
            return []
        }

        let lightsByID = lights.reduce(into: [String: HueLightResource]()) { result, light in
            result[light.id] = light
        }

        return currentArea.childLightIDs.compactMap { lightID in
            guard let light = lightsByID[lightID], light.supportsColor else {
                return nil
            }

            return light
        }
    }

    private var statusText: String {
        guard let mapping = currentMapping else {
            return "No Hue area assigned"
        }

        let areaName = currentArea?.name ?? targetLabel(mapping.preferredTarget)
        return "\(areaName) · \(mapping.capability.label)"
    }

    private func saveArea(_ area: HueAreaResource) {
        guard currentArea?.id != area.id else {
            return
        }

        let didSave = store.assignArea(
            sonosID: speaker.id,
            sonosName: speaker.name,
            areaID: area.id,
            from: areas,
            lights: lights
        )
        if didSave {
            manager.refreshStatus()
        }
    }

    private func isLightEnabled(_ light: HueLightResource) -> Bool {
        guard let mapping = currentMapping else {
            return false
        }

        if mapping.excludedLightIDs.contains(light.id) {
            return false
        }

        return light.participatesInAmbienceByDefault
            || mapping.includedLightIDs.contains(light.id)
    }

    private func setLight(_ light: HueLightResource, isEnabled: Bool) {
        guard var mapping = currentMapping else {
            return
        }

        if isEnabled {
            mapping.excludedLightIDs.remove(light.id)
            if light.participatesInAmbienceByDefault {
                mapping.includedLightIDs.remove(light.id)
            } else {
                mapping.includedLightIDs.insert(light.id)
            }
        } else {
            mapping.includedLightIDs.remove(light.id)
            if light.participatesInAmbienceByDefault {
                mapping.excludedLightIDs.insert(light.id)
            } else {
                mapping.excludedLightIDs.remove(light.id)
            }
        }

        store.upsertMapping(mapping)
        manager.refreshStatus()
    }

    private func removeAssignment() {
        store.removeMapping(forSonosID: speaker.id)
        manager.refreshStatus()
    }

    private func areaMenuTitle(_ area: HueAreaResource) -> String {
        "\(area.name) · \(area.kind.label)"
    }

    private func targetLabel(_ target: HueAmbienceTarget?) -> String {
        switch target {
        case .entertainmentArea(let id):
            return "Entertainment Area \(id)"
        case .room(let id):
            return "Room \(id)"
        case .zone(let id):
            return "Zone \(id)"
        case nil:
            return "None"
        }
    }
}
