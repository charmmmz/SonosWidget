import SwiftUI

struct MusicAmbienceSettingsView: View {
    @Bindable var store: HueAmbienceStore
    @Bindable var manager: MusicAmbienceManager
    let sonosSpeakers: [SonosPlayer]

    @State private var showingSetup = false

    var body: some View {
        Section {
            statusRow

            Toggle("Enable Music Ambience", isOn: $store.isEnabled)
                .disabled(store.bridge == nil || store.mappings.isEmpty)

            Button {
                showingSetup = true
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
            }
        } header: {
            Text("Hue Music Ambience")
        } footer: {
            Text("Uses album artwork colors for Hue ambience. Without a NAS, continuous background syncing is limited by iOS.")
        }
        .sheet(isPresented: $showingSetup) {
            HueAmbienceSetupSheet(
                store: store,
                manager: manager,
                sonosSpeakers: sonosSpeakers
            )
        }
        .onChange(of: store.isEnabled) {
            manager.refreshStatus()
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

private struct HueAmbienceSetupSheet: View {
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

    var body: some View {
        NavigationStack {
            Form {
                bridgeSection
                manualBridgeSection
                assignmentsSection
                enhancedSection
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

    private var bridgeSection: some View {
        Section {
            if let bridge = store.bridge {
                LabeledContent("Paired", value: "\(bridge.name) · \(bridge.ipAddress)")
            }

            Button {
                Task { await findHueBridges() }
            } label: {
                Label("Find Hue Bridge", systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(isBusy)

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

            if store.bridge != nil {
                Button {
                    Task { await refreshHueResources() }
                } label: {
                    Label("Refresh Hue Areas", systemImage: "arrow.clockwise")
                }
                .disabled(isBusy)
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
            Text("Bridge")
        } footer: {
            Text("Press the Hue Bridge link button before pairing.")
        }
    }

    private var manualBridgeSection: some View {
        Section("Manual Bridge") {
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
    }

    private var assignmentsSection: some View {
        Section("Assignments") {
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
        }
    }

    private var enhancedSection: some View {
        Section("NAS Enhanced") {
            LabeledContent("Live Entertainment", value: "Available after NAS runtime is configured")
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

        if hueAreas.isEmpty {
            Task { await refreshHueResources() }
        }
    }

    private func findHueBridges() async {
        setupError = nil
        isBusy = true
        defer { isBusy = false }

        do {
            let bridges = try await HueBridgeDiscovery.discoverViaBroker()
            discoveredBridges = bridges
            if let bridge = store.bridge {
                mergeDiscoveredBridge(bridge)
            }
            selectedBridgeID = selectedBridgeID.isEmpty ? bridges.first?.id ?? "" : selectedBridgeID
            if discoveredBridges.isEmpty {
                setupError = "No Hue Bridge was found. Try manual pairing with the Bridge IP."
            }
        } catch {
            setupError = error.localizedDescription
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

    @State private var selectedAreaID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(speaker.name)
                .font(.subheadline.weight(.semibold))

            if let mapping = store.mapping(forSonosID: speaker.id) {
                Text("Current: \(targetLabel(mapping.preferredTarget)) · \(mapping.capability.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Hue Area", selection: $selectedAreaID) {
                Text("Choose Area").tag("")
                ForEach(areas) { area in
                    Text("\(area.name) · \(area.kind.label)").tag(area.id)
                }
            }

            Button {
                guard let selectedArea else {
                    return
                }

                store.upsertMapping(HueAmbienceAreaOptions.mapping(
                    sonosID: speaker.id,
                    sonosName: speaker.name,
                    selectedArea: selectedArea,
                    lights: lights
                ))
                manager.refreshStatus()
            } label: {
                Label("Save Assignment", systemImage: "checkmark.circle")
            }
            .disabled(selectedArea == nil)

            if store.mapping(forSonosID: speaker.id) != nil {
                Button(role: .destructive) {
                    store.removeMapping(forSonosID: speaker.id)
                    selectedAreaID = ""
                    manager.refreshStatus()
                } label: {
                    Label("Remove Assignment", systemImage: "minus.circle")
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            syncSelectionFromMapping()
        }
        .onChange(of: areas.map(\.id)) {
            syncSelectionFromMapping()
        }
    }

    private var selectedArea: HueAreaResource? {
        areas.first { $0.id == selectedAreaID }
    }

    private func syncSelectionFromMapping() {
        guard selectedAreaID.isEmpty,
              let targetID = store.mapping(forSonosID: speaker.id)?.preferredTarget?.id,
              areas.contains(where: { $0.id == targetID }) else {
            return
        }

        selectedAreaID = targetID
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
