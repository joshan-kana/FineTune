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
    var selectedStereoPair: AUStereoPair?

    init(plugin: AUPluginDescriptor, isEnabled: Bool = true) {
        self.id = UUID()
        self.pluginDescriptor = plugin
        self.isEnabled = isEnabled
        self.presetData = nil
        self.selectedFactoryPresetIndex = nil
        self.processingMode = .auto
        self.channelSelection = .allChannels
        self.selectedStereoPair = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, pluginDescriptor, isEnabled, presetData, selectedFactoryPresetIndex
        case processingMode, channelSelection, selectedStereoPair
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        pluginDescriptor = try c.decode(AUPluginDescriptor.self, forKey: .pluginDescriptor)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        presetData = try c.decodeIfPresent(Data.self, forKey: .presetData)
        selectedFactoryPresetIndex = try c.decodeIfPresent(Int.self, forKey: .selectedFactoryPresetIndex)
        processingMode = try c.decodeIfPresent(AUProcessingMode.self, forKey: .processingMode) ?? .auto
        channelSelection = try c.decodeIfPresent(AUChannelSelection.self, forKey: .channelSelection) ?? .allChannels
        selectedStereoPair = try c.decodeIfPresent(AUStereoPair.self, forKey: .selectedStereoPair)
    }
}

/// Observable UI state for a single AU effect chain (per-app or per-device).
/// AudioEngine owns these; SettingsManager persists entries + bypass to disk.
struct AUChainState {
    var entries: [AUEffectChainEntry] = []
    var isBypassed: Bool = false
    var failedEntryIDs: Set<UUID> = []
}
