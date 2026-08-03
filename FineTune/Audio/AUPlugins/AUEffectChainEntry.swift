// FineTune/Audio/AUPlugins/AUEffectChainEntry.swift
import Foundation

struct AUEffectChainEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let pluginDescriptor: AUPluginDescriptor
    var isEnabled: Bool
    var presetData: Data?
    var selectedFactoryPresetIndex: Int?
    var processingMode: AUProcessingMode
    var channelSelection: AUChannelSelection

    init(plugin: AUPluginDescriptor, isEnabled: Bool = true) {
        self.id = UUID()
        self.pluginDescriptor = plugin
        self.isEnabled = isEnabled
        self.presetData = nil
        self.selectedFactoryPresetIndex = nil
        self.processingMode = .auto
        self.channelSelection = .allChannels
    }
}

/// Observable UI state for a single AU effect chain (per-app or per-device).
/// AudioEngine owns these; SettingsManager persists entries + bypass to disk.
struct AUChainState {
    var entries: [AUEffectChainEntry] = []
    var isBypassed: Bool = false
    var failedEntryIDs: Set<UUID> = []
}
