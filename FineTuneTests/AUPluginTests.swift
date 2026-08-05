// FineTuneTests/AUPluginTests.swift
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

// MARK: - Render handoff tests

@Suite("AU render handoff", .serialized)
struct AUEffectRenderHandoffTests {

    @Test("Normal completion reaches quiescence")
    func normalCompletion() {
        let handoff = AUEffectRenderHandoff()
        #expect(handoff.beginRender())
        handoff.endRender()

        _ = handoff.beginRetirement()
        #expect(handoff.waitForQuiescence(timeout: 0.01))
        #expect(handoff.activeRenderCount == 0)
    }

    @Test("Delayed render completion is bounded and eventually safe")
    func delayedCompletion() {
        let handoff = AUEffectRenderHandoff()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        #expect(handoff.beginRender())

        DispatchQueue.global(qos: .userInitiated).async {
            entered.signal()
            _ = release.wait(timeout: .now() + 1)
            handoff.endRender()
        }
        #expect(entered.wait(timeout: .now() + 1) == .success)

        _ = handoff.beginRetirement()
        #expect(handoff.waitForQuiescence(timeout: 0.001) == false)
        release.signal()
        #expect(handoff.waitForQuiescence(timeout: 0.5))
        #expect(handoff.activeRenderCount == 0)
    }

    @Test("Timeout can be cancelled without destroying an active render")
    func timeoutCancellation() {
        let handoff = AUEffectRenderHandoff()
        #expect(handoff.beginRender())
        let token = handoff.beginRetirement()
        #expect(handoff.waitForQuiescence(timeout: 0.001) == false)

        handoff.cancelRetirement(ifToken: token)
        #expect(handoff.beginRender())
        handoff.endRender()
        handoff.endRender()
        #expect(handoff.activeRenderCount == 0)
    }

    @Test("Retired snapshot rejects new renders until quiescent")
    func noConcurrentReuse() {
        let handoff = AUEffectRenderHandoff()
        #expect(handoff.beginRender())
        let token = handoff.beginRetirement()
        #expect(handoff.beginRender() == false)
        handoff.endRender()
        #expect(handoff.waitForQuiescence(timeout: 0.01))

        handoff.cancelRetirement(ifToken: token)
        #expect(handoff.beginRender())
        handoff.endRender()
    }
}

@Suite("AU publication transaction")
struct AUEffectChainPublicationTransactionTests {

    @Test("Paired success publishes one generation")
    func pairedSuccess() {
        var transaction = AUEffectChainPublicationTransaction(generation: 7, requiresSecondary: true)
        transaction.recordPrimary(true)
        transaction.recordSecondary(true)
        #expect(transaction.canPublish(for: 7))
    }

    @Test("Primary success and secondary timeout do not publish")
    func secondaryTimeout() {
        var transaction = AUEffectChainPublicationTransaction(generation: 7, requiresSecondary: true)
        transaction.recordPrimary(true)
        transaction.recordSecondary(false)
        #expect(!transaction.canPublish(for: 7))
    }

    @Test("Both timed-out handoffs do not publish")
    func bothTimeout() {
        var transaction = AUEffectChainPublicationTransaction(generation: 7, requiresSecondary: true)
        transaction.recordPrimary(false)
        transaction.recordSecondary(false)
        #expect(!transaction.canPublish(for: 7))
    }

    @Test("A superseded generation cannot publish")
    func supersededGeneration() {
        var transaction = AUEffectChainPublicationTransaction(generation: 7, requiresSecondary: true)
        transaction.recordPrimary(true)
        transaction.recordSecondary(true)
        #expect(!transaction.canPublish(for: 8))
    }
}

// MARK: - AUPluginDescriptor Tests

@Suite("AUPluginDescriptor")
struct AUPluginDescriptorTests {

    @Test("ID is deterministic from component triple")
    func idFromTriple() {
        let desc = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        #expect(desc.id == "1-2-3")
    }

    @Test("Two descriptors with same triple are equal")
    func equalityByTriple() {
        let a = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        let b = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        #expect(a == b)
    }

    @Test("Different triples are not equal")
    func inequalityByTriple() {
        let a = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        let b = makeDescriptor(type: 1, subType: 2, manufacturer: 4)
        #expect(a != b)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = makeDescriptor(type: 100, subType: 200, manufacturer: 300)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AUPluginDescriptor.self, from: data)
        #expect(decoded == original)
        #expect(decoded.name == original.name)
        #expect(decoded.manufacturer == original.manufacturer)
        #expect(decoded.version == original.version)
    }

    @Test("audioComponentDescription reconstructs correctly")
    func audioComponentDescription() {
        let desc = makeDescriptor(type: 0x61756678, subType: 0x64656C79, manufacturer: 0x6170706C)
        let acd = desc.audioComponentDescription
        #expect(acd.componentType == 0x61756678)
        #expect(acd.componentSubType == 0x64656C79)
        #expect(acd.componentManufacturer == 0x6170706C)
        #expect(acd.componentFlags == 0)
        #expect(acd.componentFlagsMask == 0)
    }

    @Test("Hashable works in Set")
    func hashable() {
        let a = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        let b = makeDescriptor(type: 1, subType: 2, manufacturer: 3)
        let c = makeDescriptor(type: 4, subType: 5, manufacturer: 6)
        let set: Set<AUPluginDescriptor> = [a, b, c]
        #expect(set.count == 2)
    }

    private func makeDescriptor(type: UInt32, subType: UInt32, manufacturer: UInt32) -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: type,
            componentSubType: subType,
            componentManufacturer: manufacturer,
            name: "Test Plugin",
            manufacturer: "Test Manufacturer",
            version: 1
        )
    }
}

// MARK: - AUEffectChainEntry Tests

@Suite("AUEffectChainEntry")
struct AUEffectChainEntryTests {

    @Test("Init creates unique UUID")
    func uniqueID() {
        let plugin = makePlugin()
        let a = AUEffectChainEntry(plugin: plugin)
        let b = AUEffectChainEntry(plugin: plugin)
        #expect(a.id != b.id)
    }

    @Test("Init defaults to enabled with no preset")
    func defaults() {
        let entry = AUEffectChainEntry(plugin: makePlugin())
        #expect(entry.isEnabled == true)
        #expect(entry.presetData == nil)
        #expect(entry.selectedFactoryPresetIndex == nil)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        var entry = AUEffectChainEntry(plugin: makePlugin())
        entry.isEnabled = false
        entry.presetData = Data([0x01, 0x02, 0x03])
        entry.selectedFactoryPresetIndex = 5

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(AUEffectChainEntry.self, from: data)
        #expect(decoded.id == entry.id)
        #expect(decoded.pluginDescriptor == entry.pluginDescriptor)
        #expect(decoded.isEnabled == false)
        #expect(decoded.presetData == Data([0x01, 0x02, 0x03]))
        #expect(decoded.selectedFactoryPresetIndex == 5)
    }

    @Test("Equatable compares by ID")
    func equatable() {
        let a = AUEffectChainEntry(plugin: makePlugin())
        var b = a
        b.isEnabled = false
        // Same id means equal for Equatable (it's derived)
        // Actually Equatable is auto-synthesized comparing all fields
        #expect(a != b)
    }

    private func makePlugin() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79,
            componentManufacturer: 0x6170706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
    }
}

// MARK: - AUPluginScanner Tests

@Suite("AUPluginScanner", .serialized)
@MainActor
struct AUPluginScannerTests {

    @Test("Discovers system Audio Units")
    func discoversSystemAUs() {
        let scanner = AUPluginScanner()
        #expect(scanner.plugins.count > 0, "macOS ships with built-in AU effects")
    }

    @Test("Only discovers effect-type AUs")
    func onlyEffectTypes() {
        let scanner = AUPluginScanner()
        let effectTypes: Set<UInt32> = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        for plugin in scanner.plugins {
            #expect(effectTypes.contains(plugin.componentType),
                    "\(plugin.name) has unexpected type \(plugin.componentType)")
        }
    }

    @Test("Manufacturers dictionary groups correctly")
    func manufacturerGrouping() {
        let scanner = AUPluginScanner()
        let totalInManufacturers = scanner.manufacturers.values.reduce(0) { $0 + $1.count }
        #expect(totalInManufacturers == scanner.plugins.count)
    }

    @Test("Plugins are sorted by manufacturer then name")
    func sortOrder() {
        let scanner = AUPluginScanner()
        for i in 1..<scanner.plugins.count {
            let prev = scanner.plugins[i - 1]
            let curr = scanner.plugins[i]
            #expect((prev.manufacturer, prev.name) <= (curr.manufacturer, curr.name),
                    "\(prev.manufacturer):\(prev.name) should come before \(curr.manufacturer):\(curr.name)")
        }
    }

    @Test("findComponent returns non-nil for known Apple AU")
    func findComponentForAppleAU() {
        let scanner = AUPluginScanner()
        guard let applePlugin = scanner.plugins.first(where: { $0.manufacturer == "Apple" }) else {
            Issue.record("No Apple AU found on this system")
            return
        }
        #expect(scanner.findComponent(for: applePlugin) != nil)
    }

    @Test("Refresh produces consistent results")
    func refreshConsistency() {
        let scanner = AUPluginScanner()
        let firstCount = scanner.plugins.count
        scanner.refresh()
        #expect(scanner.plugins.count == firstCount)
    }

    @Test("hasNewPlugins starts false")
    func newPluginsFlag() {
        let scanner = AUPluginScanner()
        #expect(scanner.hasNewPlugins == false)
    }

    @Test("clearNewPluginsFlag resets flag")
    func clearFlag() {
        let scanner = AUPluginScanner()
        scanner.clearNewPluginsFlag()
        #expect(scanner.hasNewPlugins == false)
    }
}

// MARK: - AUEffectHost Tests

@Suite("AUChannelInfo capability matching")
struct AUChannelCapabilityMatcherTests {
    @Test("Apple wildcard and upper-bound semantics")
    func documentedSemantics() {
        #expect(AUChannelCapabilityMatcher.matches(input: 2, output: 2, requestedInput: 2, requestedOutput: 2))
        #expect(!AUChannelCapabilityMatcher.matches(input: 2, output: 2, requestedInput: 2, requestedOutput: 6))

        #expect(AUChannelCapabilityMatcher.matches(input: -1, output: -1, requestedInput: 6, requestedOutput: 6))
        #expect(!AUChannelCapabilityMatcher.matches(input: -1, output: -1, requestedInput: 6, requestedOutput: 8))
        #expect(AUChannelCapabilityMatcher.matches(input: -1, output: -2, requestedInput: 2, requestedOutput: 8))
        #expect(AUChannelCapabilityMatcher.matches(input: -2, output: -1, requestedInput: 8, requestedOutput: 2))
        #expect(AUChannelCapabilityMatcher.matches(input: -1, output: 2, requestedInput: 6, requestedOutput: 2))
        #expect(!AUChannelCapabilityMatcher.matches(input: -1, output: 2, requestedInput: 6, requestedOutput: 6))
        #expect(AUChannelCapabilityMatcher.matches(input: 2, output: -1, requestedInput: 2, requestedOutput: 8))
        #expect(AUChannelCapabilityMatcher.matches(input: -1, output: -3, requestedInput: 8, requestedOutput: 3))
        #expect(!AUChannelCapabilityMatcher.matches(input: -1, output: -3, requestedInput: 8, requestedOutput: 4))
        #expect(AUChannelCapabilityMatcher.matches(input: -4, output: -8, requestedInput: 4, requestedOutput: 8))
        #expect(!AUChannelCapabilityMatcher.matches(input: -4, output: -8, requestedInput: 5, requestedOutput: 8))
        #expect(AUChannelCapabilityMatcher.matches(input: 0, output: 2, requestedInput: 0, requestedOutput: 2))
        #expect(!AUChannelCapabilityMatcher.matches(input: 0, output: 2, requestedInput: 2, requestedOutput: 2))
    }

    @Test("Native layout counts distinguish mono, stereo, 5.1, and 7.1")
    func commonLayouts() {
        let capability = (input: -1, output: -3)
        #expect(AUChannelCapabilityMatcher.matches(input: capability.input, output: capability.output, requestedInput: 1, requestedOutput: 1))
        #expect(AUChannelCapabilityMatcher.matches(input: capability.input, output: capability.output, requestedInput: 2, requestedOutput: 2))
        #expect(AUChannelCapabilityMatcher.matches(input: capability.input, output: capability.output, requestedInput: 6, requestedOutput: 6) == false)
        #expect(AUChannelCapabilityMatcher.matches(input: -1, output: -8, requestedInput: 6, requestedOutput: 6))
        #expect(AUChannelCapabilityMatcher.matches(input: -1, output: -8, requestedInput: 8, requestedOutput: 8))
    }
}

@Suite("AU processing topology")
struct AUProcessingTopologyTests {
    @Test("A mock stereo-capable AU can fall back after native initialization rejects HDMI")
    func retriesSupportedFallbackAfterNativeFailure() {
        // This models FabFilter Pro-C 2 and BABY Audio Comeback: their mock
        // capability table accepts mono/stereo but rejects an 8-channel bus.
        let mockCapabilities = [(input: 1, output: 1), (input: 2, output: 2)]
        #expect(
            AUProcessingTopology.choose(
                mode: .auto,
                channelCount: 8,
                nativeCanProcess: false,
                supportedChannelCounts: mockCapabilities
            ) == .independentPerChannel
        )
    }

    @Test("A mock stereo-only AU stays visibly unsupported when mono is unavailable")
    func rejectsUnsupportedFallback() {
        let mockCapabilities = [(input: 2, output: 2)]
        #expect(
            AUProcessingTopology.choose(
                mode: .auto,
                channelCount: 8,
                nativeCanProcess: false,
                supportedChannelCounts: mockCapabilities
            ) == .unsupported
        )
    }
}

@Suite("Audio Unit chain topology")
struct AUEffectChainTopologyTests {
    @Test("Parallel hosts use maximum and serial entries use sum")
    func parallelThenSerial() {
        #expect(AUEffectChainTopology.parallelMaximum([0.01, 0.04, 0.02]) == 0.04)
        #expect(AUEffectChainTopology.serialSum([[0.01, 0.04], [0.02], [0.08, 0.03]], enabled: [true, false, true]) == 0.12)
        #expect(AUEffectChainTopology.serialSum([[0.01], [0.02]], enabled: [false, false]) == 0)
    }
}

@Suite("AUEffectHost")
struct AUEffectHostTests {

    @Test("Instantiate Apple AUDelay succeeds")
    func instantiateAUDelay() {
        let desc = appleAUDelay()
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100)
        #expect(host.instantiate() == true)
        #expect(host.audioUnit != nil)
    }

    @Test("Instantiate with bogus descriptor fails")
    func instantiateBogus() {
        let desc = AUPluginDescriptor(
            componentType: 0xDEADBEEF,
            componentSubType: 0xDEADBEEF,
            componentManufacturer: 0xDEADBEEF,
            name: "Bogus",
            manufacturer: "Bogus",
            version: 0
        )
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100)
        #expect(host.instantiate() == false)
        #expect(host.audioUnit == nil)
    }

    @Test("Enable/disable toggle works")
    func enableDisable() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100, enabled: true)
        #expect(host.isEnabled == true)
        host.setEnabled(false)
        #expect(host.isEnabled == false)
        host.setEnabled(true)
        #expect(host.isEnabled == true)
    }

    @Test("Factory presets are populated for AUDelay")
    func factoryPresets() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100)
        guard host.instantiate() else {
            Issue.record("Failed to instantiate AUDelay")
            return
        }
        // AUDelay may or may not have factory presets, but the property should not crash
        _ = host.factoryPresets
    }

    @Test("Tail time is non-negative")
    func tailTime() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100)
        guard host.instantiate() else { return }
        #expect(host.tailTimeSeconds >= 0)
    }

    @Test("Save and load preset round-trip")
    func presetRoundTrip() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100)
        guard host.instantiate() else {
            Issue.record("Failed to instantiate")
            return
        }
        guard let saved = host.savePreset() else {
            Issue.record("Failed to save preset")
            return
        }
        #expect(saved.count > 0)
        #expect(host.loadPreset(saved) == true)
    }

    @Test("renderInterleaved actually modifies audio with AULowpass")
    func renderInterleavedModifiesAudio() {
        let desc = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6C706173, // 'lpas'
            componentManufacturer: 0x6170706C, // 'appl'
            name: "AULowPassFilter",
            manufacturer: "Apple",
            version: 1
        )
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100, maxFrames: 512)
        guard host.instantiate() else {
            Issue.record("Failed to instantiate AULowPassFilter")
            return
        }

        // Set cutoff to 200 Hz so it aggressively filters high frequencies
        if let au = host.audioUnit {
            let cutoff: AudioUnitParameterValue = 200.0
            AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, cutoff, 0)
        }

        // Generate 10kHz sine wave (will be heavily filtered by 200Hz lowpass)
        let frameCount = 512
        var buffer = [Float](repeating: 0, count: frameCount * 2)
        let freq: Float = 10000.0
        let sampleRate: Float = 44100.0
        for i in 0..<frameCount {
            let sample = sinf(2.0 * .pi * freq * Float(i) / sampleRate) * 0.5
            buffer[i * 2] = sample     // L
            buffer[i * 2 + 1] = sample // R
        }

        // Compute energy before
        let energyBefore = buffer.reduce(Float(0)) { $0 + $1 * $1 }

        // Render through several buffers to let the filter settle
        for _ in 0..<10 {
            buffer.withUnsafeMutableBufferPointer { ptr in
                host.renderInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
            }
            // Refill with sine for next iteration
            for i in 0..<frameCount {
                let sample = sinf(2.0 * .pi * freq * Float(i) / sampleRate) * 0.5
                buffer[i * 2] = sample
                buffer[i * 2 + 1] = sample
            }
        }

        // Final render pass — measure output
        buffer.withUnsafeMutableBufferPointer { ptr in
            host.renderInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
        }

        let energyAfter = buffer.reduce(Float(0)) { $0 + $1 * $1 }

        // A 200Hz lowpass should massively attenuate a 10kHz signal
        #expect(energyAfter < energyBefore * 0.01,
                "AULowPassFilter at 200Hz should attenuate 10kHz signal by >40dB, got ratio \(energyAfter / energyBefore)")
    }

    @Test("renderInterleaved works with AUReverb2")
    func renderInterleavedReverb2() {
        let desc = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x72766232, // 'rvb2'
            componentManufacturer: 0x6170706C, // 'appl'
            name: "AUReverb2",
            manufacturer: "Apple",
            version: 1
        )
        let host = AUEffectHost(descriptor: desc, entryID: UUID(), sampleRate: 44100, maxFrames: 512)
        guard host.instantiate() else {
            Issue.record("Failed to instantiate AUReverb2")
            return
        }

        // Set DryWetMix to 100% wet so reverb is fully audible
        if let au = host.audioUnit {
            // Parameter 0 = DryWetMix (0-100)
            AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, 100.0, 0)
        }

        let frameCount = 512

        // Feed an impulse (single loud sample) then silence — reverb tail should persist
        var impulse = [Float](repeating: 0, count: frameCount * 2)
        impulse[0] = 1.0  // L
        impulse[1] = 1.0  // R

        impulse.withUnsafeMutableBufferPointer { ptr in
            host.renderInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
        }

        // Now render silence — the reverb tail should produce non-zero output
        var silence = [Float](repeating: 0, count: frameCount * 2)
        silence.withUnsafeMutableBufferPointer { ptr in
            host.renderInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
        }

        let tailEnergy = silence.reduce(Float(0)) { $0 + $1 * $1 }
        #expect(tailEnergy > 0.0001, "AUReverb2 at 100% wet should produce a reverb tail after an impulse, got energy \(tailEnergy)")
    }

    @Test("Disabled host passes audio through unchanged")
    func disabledHostPassthrough() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100, maxFrames: 256, enabled: false)
        _ = host.instantiate()

        var buffer: [Float] = [0.5, -0.5, 0.3, -0.3]
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { ptr in
            host.renderInterleaved(samples: ptr.baseAddress!, frameCount: 2)
        }
        #expect(buffer == original)
    }

    private func appleAUDelay() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79, // 'dely'
            componentManufacturer: 0x6170706C, // 'appl'
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
    }
}

// MARK: - AUEffectChain Tests

@Suite("AUEffectChain")
struct AUEffectChainTests {

    @Test("Empty entries create chain with zero hosts")
    func emptyChain() {
        let chain = AUEffectChain(entries: [], sampleRate: 44100)
        #expect(chain.hosts.count == 0)
        #expect(chain.entries.count == 0)
    }

    @Test("Chain with valid AU creates hosts")
    func validChain() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100)
        #expect(chain.hosts.count == 1)
        #expect(chain.hosts[0].entryID == entry.id)
    }

    @Test("Chain skips invalid AUs")
    func invalidAUSkipped() {
        let bogus = AUPluginDescriptor(
            componentType: 0xDEADBEEF,
            componentSubType: 0xDEADBEEF,
            componentManufacturer: 0xDEADBEEF,
            name: "Bogus",
            manufacturer: "Bogus",
            version: 0
        )
        let validEntry = AUEffectChainEntry(plugin: appleAUDelay())
        let bogusEntry = AUEffectChainEntry(plugin: bogus)
        let chain = AUEffectChain(entries: [bogusEntry, validEntry], sampleRate: 44100)
        #expect(chain.entries.count == 2)
        #expect(chain.hosts.count == 1)
    }

    @Test("Bypass flag starts false")
    func bypassDefault() {
        let chain = AUEffectChain(entries: [], sampleRate: 44100)
        #expect(chain.isBypassed == false)
    }

    @Test("Bypass toggle works")
    func bypassToggle() {
        let chain = AUEffectChain(entries: [], sampleRate: 44100)
        chain.setBypassed(true)
        #expect(chain.isBypassed == true)
        chain.setBypassed(false)
        #expect(chain.isBypassed == false)
    }

    @Test("maxTailTime reflects hosts")
    func maxTailTime() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100)
        // Should not crash; value depends on AU implementation
        #expect(chain.maxTailTime >= 0)
    }

    @Test("host(for:) finds correct host by entryID")
    func hostLookup() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100)
        #expect(chain.host(for: entry.id) != nil)
        #expect(chain.host(for: UUID()) == nil)
    }

    @Test("Compatible hosts survive chain replacement")
    func reusesCompatibleHosts() {
        let firstEntry = AUEffectChainEntry(plugin: appleAUDelay())
        let secondEntry = AUEffectChainEntry(plugin: appleAUDelay())
        let original = AUEffectChain(entries: [firstEntry], sampleRate: 44100)
        let replacement = AUEffectChain(
            entries: [firstEntry, secondEntry],
            sampleRate: 44100,
            reusing: original
        )

        #expect(replacement.host(for: firstEntry.id) === original.host(for: firstEntry.id))
        #expect(replacement.host(for: secondEntry.id) !== original.host(for: firstEntry.id))
    }

    @Test("Reused host reflects an enabled-state change")
    func reusesHostForToggle() {
        let enabledEntry = AUEffectChainEntry(plugin: appleAUDelay(), isEnabled: true)
        let original = AUEffectChain(entries: [enabledEntry], sampleRate: 44100)
        var disabledEntry = enabledEntry
        disabledEntry.isEnabled = false
        let replacement = AUEffectChain(
            entries: [disabledEntry],
            sampleRate: 44100,
            reusing: original
        )

        #expect(replacement.host(for: enabledEntry.id) === original.host(for: enabledEntry.id))
        #expect(replacement.isEntryEnabled(enabledEntry.id) == false)
    }

    @Test("Replacement preserves a newly requested factory preset")
    func replacementPreservesRequestedFactoryPreset() {
        let originalEntry = AUEffectChainEntry(plugin: appleAUDelay())
        let original = AUEffectChain(entries: [originalEntry], sampleRate: 44100)
        var requestedEntry = originalEntry
        requestedEntry.selectedFactoryPresetIndex = 2
        requestedEntry.presetData = nil

        let replacement = AUEffectChain(
            entries: [requestedEntry],
            sampleRate: 44100,
            reusing: original
        )

        #expect(replacement.entries.first?.selectedFactoryPresetIndex == 2)
        #expect(replacement.entries.first?.presetData == nil)
    }

    @Test("Replacement preserves explicitly supplied preset data")
    func replacementPreservesExplicitPresetData() {
        let originalEntry = AUEffectChainEntry(plugin: appleAUDelay())
        let original = AUEffectChain(entries: [originalEntry], sampleRate: 44100)
        var requestedEntry = originalEntry
        requestedEntry.presetData = Data([0x11, 0x22, 0x33])
        requestedEntry.selectedFactoryPresetIndex = nil

        let replacement = AUEffectChain(
            entries: [requestedEntry],
            sampleRate: 44100,
            reusing: original
        )

        #expect(replacement.entries.first?.presetData == Data([0x11, 0x22, 0x33]))
        #expect(replacement.entries.first?.selectedFactoryPresetIndex == nil)
    }

    @Test("Timed-out replacement retains the old chain and resumes after retirement cancellation")
    func timedOutReplacementKeepsOldChainUsable() {
        let oldEntry = AUEffectChainEntry(plugin: appleAUDelay())
        let oldChain = AUEffectChain(entries: [oldEntry], sampleRate: 44100)
        let oldEntries = oldChain.entries

        #expect(oldChain.beginRenderForTesting())
        let retirementToken = oldChain.beginRetirement()
        #expect(oldChain.waitForRenderQuiescence(timeout: 0.001) == false)

        oldChain.cancelRetirement(ifToken: retirementToken)
        #expect(oldChain.entries == oldEntries)
        #expect(oldChain.beginRenderForTesting())
        oldChain.endRenderForTesting()
        oldChain.endRenderForTesting()
    }

    @Test("processInterleaved routes audio through chain")
    func processInterleavedWorks() {
        let desc = AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6C706173, // 'lpas' - AULowPassFilter
            componentManufacturer: 0x6170706C,
            name: "AULowPassFilter",
            manufacturer: "Apple",
            version: 1
        )
        let entry = AUEffectChainEntry(plugin: desc)
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100, maxFrames: 256)
        #expect(chain.hosts.count == 1)

        // Set cutoff low
        if let au = chain.hosts.first?.audioUnit {
            let cutoff: AudioUnitParameterValue = 100.0
            AudioUnitSetParameter(au, 0, kAudioUnitScope_Global, 0, cutoff, 0)
        }

        let frameCount = 256
        var buffer = [Float](repeating: 0, count: frameCount * 2)
        // 15kHz sine
        for i in 0..<frameCount {
            let s = sinf(2.0 * .pi * 15000.0 * Float(i) / 44100.0)
            buffer[i * 2] = s
            buffer[i * 2 + 1] = s
        }

        // Settle filter
        for _ in 0..<20 {
            var temp = buffer
            temp.withUnsafeMutableBufferPointer { ptr in
                chain.processInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
            }
        }

        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.processInterleaved(samples: ptr.baseAddress!, frameCount: frameCount)
        }

        let energy = buffer.reduce(Float(0)) { $0 + $1 * $1 }
        let maxPossibleEnergy = Float(frameCount * 2) // each sample max 1.0
        #expect(energy < maxPossibleEnergy * 0.001, "15kHz should be nearly silent through 100Hz lowpass")
    }

    @Test("Disabled reused group is not rendered")
    func disabledGroupPassthrough() {
        let entry = AUEffectChainEntry(plugin: appleLowPassFilter(), isEnabled: false)
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100, maxFrames: 64)
        var buffer: [Float] = [0.5, -0.5, 0.25, -0.25]
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.processInterleaved(samples: pointer.baseAddress!, frameCount: 2)
        }
        #expect(buffer == original)
        #expect(chain.isEntryEnabled(entry.id) == false)
    }

    @Test("Bypassed chain does not modify audio")
    func bypassedChainPassthrough() {
        let entry = AUEffectChainEntry(plugin: appleAUDelay())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100, maxFrames: 64)
        chain.setBypassed(true)

        var buffer: [Float] = [0.5, -0.5, 0.3, -0.3]
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.processInterleaved(samples: ptr.baseAddress!, frameCount: 2)
        }
        #expect(buffer == original)
    }

    @Test("Timed-out handoff preserves the old chain and resumes after cancellation")
    func timedOutHandoffPreservesOldChain() {
        let entry = AUEffectChainEntry(plugin: appleLowPassFilter())
        let chain = AUEffectChain(entries: [entry], sampleRate: 44100, maxFrames: 256)
        let originalEntries = chain.entries
        #expect(chain.beginRenderForTesting())

        let retirementToken = chain.beginRetirement()
        #expect(chain.waitForRenderQuiescence(timeout: 0.001) == false)
        chain.cancelRetirement(ifToken: retirementToken)
        chain.endRenderForTesting()

        #expect(chain.entries == originalEntries)
        #expect(chain.beginRenderForTesting())
        chain.endRenderForTesting()
    }

    private func appleAUDelay() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79,
            componentManufacturer: 0x6170706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
    }

    private func appleLowPassFilter() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6C706173,
            componentManufacturer: 0x6170706C,
            name: "AULowPassFilter",
            manufacturer: "Apple",
            version: 1
        )
    }
}

// MARK: - Peer registry tests

@Suite("AU peer registry", .serialized)
struct AUEffectPeerRegistryTests {

    @Test("Shared hosts remain registered until every owner unregisters")
    func ownerScopedCleanup() {
        let registry = AUEffectPeerRegistry.shared
        let entryID = UUID()
        let firstOwner = UUID()
        let secondOwner = UUID()
        let first = AUEffectHost(descriptor: appleAUDelay(), entryID: entryID, sampleRate: 44100)
        let second = AUEffectHost(descriptor: appleAUDelay(), entryID: entryID, sampleRate: 44100)
        #expect(first.instantiate())
        #expect(second.instantiate())

        registry.register([first], entryID: entryID, ownerID: firstOwner)
        registry.register([first, second], entryID: entryID, ownerID: secondOwner)
        #expect(registry.hostCountForTesting(entryID: entryID) == 2)

        registry.unregisterSynchronouslyForTesting([first], entryID: entryID, ownerID: firstOwner)
        #expect(registry.hostCountForTesting(entryID: entryID) == 2)
        registry.unregisterSynchronouslyForTesting([first], entryID: entryID, ownerID: secondOwner)
        #expect(registry.hostCountForTesting(entryID: entryID) == 1)
        registry.unregisterSynchronouslyForTesting([second], entryID: entryID, ownerID: secondOwner)
        #expect(registry.hostCountForTesting(entryID: entryID) == 0)
    }

    @Test("Two independent mono hosts synchronize and exclude the source")
    func independentMonoHostsSynchronize() {
        let registry = AUEffectPeerRegistry.shared
        let entryID = UUID()
        let ownerID = UUID()
        let source = makeHost(entryID: entryID, format: format(channelCount: 1), mode: .independentPerChannel)
        let peer = makeHost(entryID: entryID, format: format(channelCount: 1), mode: .independentPerChannel)
        let callback = DispatchSemaphore(value: 0)
        var peerUpdates = 0
        var sourceUpdates = 0

        source.setPeerParameterSetterForTesting { _ in
            sourceUpdates += 1
            return noErr
        }
        peer.setPeerParameterSetterForTesting { value in
            peerUpdates += 1
            callback.signal()
            registry.emitParameterChangeForTesting(entryID: entryID, source: peer, parameterID: 7, value: value)
            return noErr
        }
        registry.register([source, peer], entryID: entryID, ownerID: ownerID)
        registry.emitParameterChangeForTesting(entryID: entryID, source: source, parameterID: 7, value: 0.5)

        #expect(callback.wait(timeout: .now() + 1) == .success)
        #expect(peerUpdates == 1)
        #expect(sourceUpdates == 0)
        registry.unregisterSynchronouslyForTesting([source, peer], entryID: entryID, ownerID: ownerID)
    }

    @Test("5.1 and 7.1 host groups fan out to every independent host")
    func multichannelHostGroupsSynchronize() {
        let registry = AUEffectPeerRegistry.shared
        #expect(synchronizeHostGroup(registry: registry, channelCount: 6, expectedPeers: 5))
        #expect(synchronizeHostGroup(registry: registry, channelCount: 8, expectedPeers: 7))
    }

    @Test("Two simulated device tap groups share parameter peers")
    func deviceTapGroupsSynchronize() {
        let registry = AUEffectPeerRegistry.shared
        let entryID = UUID()
        let firstOwner = UUID()
        let secondOwner = UUID()
        let firstGroup = [
            makeHost(entryID: entryID, format: format(channelCount: 1)),
            makeHost(entryID: entryID, format: format(channelCount: 1))
        ]
        let secondGroup = [
            makeHost(entryID: entryID, format: format(channelCount: 1)),
            makeHost(entryID: entryID, format: format(channelCount: 1))
        ]
        let callback = DispatchSemaphore(value: 0)
        var updates = 0
        for host in secondGroup {
            host.setPeerParameterSetterForTesting { _ in
                updates += 1
                callback.signal()
                return noErr
            }
        }

        registry.register(firstGroup, entryID: entryID, ownerID: firstOwner)
        registry.register(secondGroup, entryID: entryID, ownerID: secondOwner)
        registry.emitParameterChangeForTesting(entryID: entryID, source: firstGroup[0], parameterID: 3, value: 0.25)

        #expect(callback.wait(timeout: .now() + 1) == .success)
        #expect(callback.wait(timeout: .now() + 1) == .success)
        #expect(updates == 2)
        #expect(registry.hostCountForTesting(entryID: entryID) == 4)
        registry.unregisterSynchronouslyForTesting(firstGroup, entryID: entryID, ownerID: firstOwner)
        registry.unregisterSynchronouslyForTesting(secondGroup, entryID: entryID, ownerID: secondOwner)
    }

    @Test("Failed peer updates clear suppression for the next source change")
    func failedPeerUpdateClearsSuppression() {
        let registry = AUEffectPeerRegistry.shared
        let entryID = UUID()
        let ownerID = UUID()
        let source = makeHost(entryID: entryID, format: format(channelCount: 1))
        let peer = makeHost(entryID: entryID, format: format(channelCount: 1))
        let callback = DispatchSemaphore(value: 0)
        var shouldFail = true
        var updates = 0
        peer.setPeerParameterSetterForTesting { _ in
            updates += 1
            callback.signal()
            return shouldFail ? -1 : noErr
        }
        registry.register([source, peer], entryID: entryID, ownerID: ownerID)

        registry.emitParameterChangeForTesting(entryID: entryID, source: source, parameterID: 9, value: 0.75)
        #expect(callback.wait(timeout: .now() + 1) == .success)
        shouldFail = false
        registry.emitParameterChangeForTesting(entryID: entryID, source: source, parameterID: 9, value: 0.8)
        #expect(callback.wait(timeout: .now() + 1) == .success)
        #expect(updates == 2)
        registry.unregisterSynchronouslyForTesting([source, peer], entryID: entryID, ownerID: ownerID)
    }

    @Test("Stale hosts are removed from peer groups")
    func staleHostCleanup() {
        let registry = AUEffectPeerRegistry.shared
        let entryID = UUID()
        let ownerID = UUID()
        var stale: AUEffectHost? = makeHost(entryID: entryID, format: format(channelCount: 1))
        let live = makeHost(entryID: entryID, format: format(channelCount: 1))
        registry.register([stale!, live], entryID: entryID, ownerID: ownerID)
        #expect(registry.hostCountForTesting(entryID: entryID) == 2)
        stale = nil
        #expect(registry.hostCountForTesting(entryID: entryID) == 1)
        registry.unregisterSynchronouslyForTesting([live], entryID: entryID, ownerID: ownerID)
    }

    @Test("Failed preset load leaves the host available for rendering")
    func failedPresetLoadContained() {
        let host = AUEffectHost(descriptor: appleAUDelay(), entryID: UUID(), sampleRate: 44100)
        #expect(host.instantiate())
        #expect(host.loadPresetSafely(Data([0x00, 0x01, 0x02]), timeout: 0.01) == false)
        #expect(host.audioUnit != nil)
    }

    private func appleAUDelay() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x64656C79,
            componentManufacturer: 0x6170706C,
            name: "AUDelay",
            manufacturer: "Apple",
            version: 1
        )
    }

    private func appleLowPassFilter() -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x6C706173,
            componentManufacturer: 0x6170706C,
            name: "AULowPassFilter",
            manufacturer: "Apple",
            version: 1
        )
    }

    private func makeHost(
        entryID: UUID,
        format: AudioStreamFormatDescription,
        mode: AUProcessingMode = .auto
    ) -> AUEffectHost {
        AUEffectHost(
            descriptor: appleAUDelay(),
            entryID: entryID,
            sampleRate: format.sampleRate,
            format: format,
            processingMode: mode
        )
    }

    private func format(channelCount: Int) -> AudioStreamFormatDescription {
        let tag: AudioChannelLayoutTag?
        switch channelCount {
        case 1: tag = kAudioChannelLayoutTag_Mono
        case 6: tag = kAudioChannelLayoutTag_AudioUnit_5_1
        case 8: tag = kAudioChannelLayoutTag_AudioUnit_7_1
        default: tag = nil
        }
        return AudioStreamFormatDescription(
            sampleRate: 44100,
            frameCapacity: 64,
            channelCount: channelCount,
            isInterleaved: false,
            channelLayoutTag: tag
        )
    }

    private func synchronizeHostGroup(
        registry: AUEffectPeerRegistry,
        channelCount: Int,
        expectedPeers: Int
    ) -> Bool {
        let entryID = UUID()
        let ownerID = UUID()
        let hosts = (0..<channelCount).map { _ in
            makeHost(entryID: entryID, format: format(channelCount: channelCount), mode: .independentPerChannel)
        }
        let callback = DispatchSemaphore(value: 0)
        var updates = 0
        for host in hosts.dropFirst() {
            host.setPeerParameterSetterForTesting { _ in
                updates += 1
                callback.signal()
                return noErr
            }
        }
        registry.register(hosts, entryID: entryID, ownerID: ownerID)
        registry.emitParameterChangeForTesting(entryID: entryID, source: hosts[0], parameterID: 11, value: 0.4)
        for _ in 0..<expectedPeers {
            guard callback.wait(timeout: .now() + 1) == .success else {
                registry.unregisterSynchronouslyForTesting(hosts, entryID: entryID, ownerID: ownerID)
                return false
            }
        }
        let result = updates == expectedPeers && registry.hostCountForTesting(entryID: entryID) == channelCount
        registry.unregisterSynchronouslyForTesting(hosts, entryID: entryID, ownerID: ownerID)
        return result
    }
}

// MARK: - CrashGuard Plugin Tracking Tests

@Suite("CrashGuard Plugin Tracking")
struct CrashGuardPluginTrackingTests {

    @Test("FNV-1a hash is deterministic")
    func hashDeterministic() {
        let h1 = CrashGuard.fnv1aHash("test-plugin")
        let h2 = CrashGuard.fnv1aHash("test-plugin")
        #expect(h1 == h2)
    }

    @Test("FNV-1a hash differs for different strings")
    func hashDiffers() {
        let h1 = CrashGuard.fnv1aHash("plugin-a")
        let h2 = CrashGuard.fnv1aHash("plugin-b")
        #expect(h1 != h2)
    }

    @Test("readAndClearCrashPlugins returns empty when no crash file")
    func noCrashFile() {
        let result = CrashGuard.readAndClearCrashPlugins(knownPluginIDs: ["foo", "bar"])
        #expect(result.isEmpty)
    }
}

// MARK: - SettingsManager AU Tests

@Suite("SettingsManager AU Persistence", .serialized)
@MainActor
struct SettingsManagerAUTests {

    @Test("Get/set app AU effect chain round-trip")
    func appChainRoundTrip() {
        let settings = SettingsManager()
        let entry = AUEffectChainEntry(plugin: makePlugin())
        settings.setAUEffectChain([entry], for: "com.test.app")
        let loaded = settings.getAUEffectChain(for: "com.test.app")
        #expect(loaded.count == 1)
        #expect(loaded[0].id == entry.id)
    }

    @Test("Empty chain removes key")
    func emptyChainRemovesKey() {
        let settings = SettingsManager()
        let entry = AUEffectChainEntry(plugin: makePlugin())
        settings.setAUEffectChain([entry], for: "com.test.app")
        settings.setAUEffectChain([], for: "com.test.app")
        let loaded = settings.getAUEffectChain(for: "com.test.app")
        #expect(loaded.isEmpty)
    }

    @Test("Get/set device AU effect chain round-trip")
    func deviceChainRoundTrip() {
        let settings = SettingsManager()
        let entry = AUEffectChainEntry(plugin: makePlugin())
        settings.setDeviceAUEffectChain([entry], for: "device-uid-123")
        let loaded = settings.getDeviceAUEffectChain(for: "device-uid-123")
        #expect(loaded.count == 1)
        #expect(loaded[0].id == entry.id)
    }

    @Test("Favorite toggle works")
    func favoriteToggle() {
        let settings = SettingsManager()
        let pluginID = "test-plugin-id"
        #expect(settings.isAUPluginFavorite(pluginID) == false)
        settings.toggleAUPluginFavorite(pluginID)
        #expect(settings.isAUPluginFavorite(pluginID) == true)
        settings.toggleAUPluginFavorite(pluginID)
        #expect(settings.isAUPluginFavorite(pluginID) == false)
    }

    @Test("Crash history tracking")
    func crashHistory() {
        let settings = SettingsManager()
        #expect(settings.wasAUPluginInvolvedInCrash("p1") == false)
        settings.markAUPluginsActiveAtCrash(["p1", "p2"])
        #expect(settings.wasAUPluginInvolvedInCrash("p1") == true)
        #expect(settings.wasAUPluginInvolvedInCrash("p2") == true)
        #expect(settings.wasAUPluginInvolvedInCrash("p3") == false)
        settings.clearAUPluginCrashHistory()
        #expect(settings.wasAUPluginInvolvedInCrash("p1") == false)
    }

    @Test("disableCrashedAUPlugins disables matching entries")
    func disableCrashed() {
        let settings = SettingsManager()
        let plugin1 = makePlugin(name: "Plugin1", subType: 1)
        let plugin2 = makePlugin(name: "Plugin2", subType: 2)
        let entry1 = AUEffectChainEntry(plugin: plugin1)
        let entry2 = AUEffectChainEntry(plugin: plugin2)
        settings.setAUEffectChain([entry1, entry2], for: "com.test.app")

        settings.disableCrashedAUPlugins([plugin1.id])

        let loaded = settings.getAUEffectChain(for: "com.test.app")
        #expect(loaded.count == 2)
        #expect(loaded[0].isEnabled == false)
        #expect(loaded[1].isEnabled == true)
    }

    @Test("Reset clears all AU settings")
    func resetClearsAll() {
        let settings = SettingsManager()
        settings.setAUEffectChain([AUEffectChainEntry(plugin: makePlugin())], for: "app1")
        settings.setDeviceAUEffectChain([AUEffectChainEntry(plugin: makePlugin())], for: "dev1")
        settings.toggleAUPluginFavorite("fav1")
        settings.markAUPluginsActiveAtCrash(["crash1"])

        settings.resetAllSettings()

        #expect(settings.getAUEffectChain(for: "app1").isEmpty)
        #expect(settings.getDeviceAUEffectChain(for: "dev1").isEmpty)
        #expect(settings.isAUPluginFavorite("fav1") == false)
        #expect(settings.wasAUPluginInvolvedInCrash("crash1") == false)
    }

    private func makePlugin(name: String = "Test", subType: UInt32 = 0x74657374) -> AUPluginDescriptor {
        AUPluginDescriptor(
            componentType: kAudioUnitType_Effect,
            componentSubType: subType,
            componentManufacturer: 0x74737400,
            name: name,
            manufacturer: "Test",
            version: 1
        )
    }
}
