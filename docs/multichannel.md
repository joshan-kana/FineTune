# Multichannel processing

Supported layouts are mono, stereo, 5.1 LPCM, and 7.1 LPCM. Audio Unit 7.1 uses L, R, C, LFE, Ls, Rs, Lrs, Rrs. Interleaved buffers, planar buffers, and buffer lists containing channel groups are represented without downmixing.

Native effects receive the complete layout. Independent mode creates one mono host per channel; Centre and LFE are never paired as stereo. A device-level channel selection policy is persisted with the effect entry for future UI controls.

FineTune's volume ramp and limiter apply to every channel. EQ processors maintain per-channel filter state. Loudness equalization uses a linked sidechain for interleaved layouts; non-native or unavailable correction paths bypass rather than collapsing the layout.
