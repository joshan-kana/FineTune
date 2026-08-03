# Architecture

FineTune captures application audio through its existing private Core Audio process taps and routes it directly to the physical device selected by macOS. Temporary private aggregates are implementation details and are not user-facing outputs.

The callback pipeline is:

```text
tap → volume/ramp → built-in correction → per-app AU chain → per-device AU chain → loudness/limiter → selected output
```

`ProcessTapController` owns primary and crossfade resources. `AUEffectChain` is an immutable snapshot. Main-thread changes construct a replacement chain and defer old-chain destruction so an in-flight callback never observes partially torn-down state.
