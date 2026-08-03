# Audio Units

FineTune discovers effect and music-effect Audio Units through Core Audio. Each effect records its component descriptor, preset data, enabled state, processing mode, compatibility state, tail time, and reported latency.

The host queries supported channel counts and layout tags before setting the stream format, maximum frames per slice, render callback, and initialization. `Auto` prefers a native full-layout instance. Effects that only support mono can use independent per-channel instances. Stereo-only or unsupported effects bypass with an explanation while preserving audio.

Plugin editors and generic controls are retained from the port of upstream PR #305. Third-party plugins execute only after their host buffers and state are prepared off the callback thread.
