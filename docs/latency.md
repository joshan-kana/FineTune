# Latency and real-time behavior

The AU chain runs inside FineTune's existing tap/render pipeline. There is no BlackHole hop, external host hop, or user-facing virtual output. Each host reports Audio Unit algorithmic latency and each chain exposes the aggregate.

Defaults avoid look-ahead, linear-phase processing, unnecessary oversampling, and extra global buffering. Physical device and HDMI latency remain separate from FineTune's callback cost and plugin-reported latency; the application does not claim zero end-to-end latency.
