## Unreleased (candidate for 0.0.15)

* iOS: fix a deadlock that could hang `stopSession`/`startSession` forever (present in v0.0.14). The mixer and
  capture tap blocks emitted session snapshots on AVAudioEngine's render threads, and a snapshot reads
  `engine.inputNode`; a concurrent `AVAudioPlayerNode.stop()` holds the engine lock while it waits for that tap
  thread. Those three snapshots (`playback_startup_confirmed`, `playback_mixer_buffer_first`,
  `capture_buffer_first`) are now emitted from the session queue, and a tap thread never touches the engine.
* iOS farewell barrier: playback-lifetime continuity (Group A).
  * New `RenderLifetimeFence`: the plugin advances a render-lifetime generation BEFORE every operation that can end
    or restart the player's render timeline (node stop/reset, play() on a stopped node, engine start/stop/reset,
    engine configuration change, interruption, route change, media services loss/reset). Each farewell buffer's
    scheduling anchor records it. A `.dataPlayedBack` callback can only verify through an anchor read while the
    generation is unchanged (checked before and after the read), so a flush, even one delivered late, can never be
    verified by a restarted timeline. The WHOLE turn is bound to the generation read at begin: it is re-checked at
    every push and, atomically against advances, at the drained emission, so a stop/pause between chunks or after
    the audio played but before END fails the turn. System notifications advance it synchronously.
  * The turn begins at ONE render-anchor read (>= 960 frames into its timeline, unchanged generation, else it fails
    closed); the start frame is derived from that same anchor, never from an earlier read. Every scheduling anchor and the anchor read at the drained emission (under
    the fence lock; retried within the bound if missing) must lie on its continuous timeline, so an unannounced
    restart between chunks or after the last callback but before END also fails the turn.
  * The non-blocking cancel and invalidate paths seal the turn synchronously before they enqueue, and the drained
    emission is atomic against that seal: once `farewellCancel` (or an asynchronous invalidation) returns, the turn
    can no longer drain (also fixes this race in v0.0.14). The plugin records every `farewellCancel` before it
    acknowledges it, and applies a recorded cancel when a queued `farewellBegin` reaches a barrier installed later.
  * Each push derives its start frame from the same single anchor read that is its timeline reference, and fails closed
    (`scheduled_behind_playhead`) unless, from an anchor read after submission in the same render lifetime, a
    conservative upper bound on the current render position (stale anchor projected forward by elapsed host time, plus
    a render-ahead allowance built from documented maxima of the live graph: the player's maximum downstream
    `outputPresentationLatency`, the output node's `presentationLatency`, two actual I/O buffers and one whole
    `maximumFramesToRender` slice) is still >= leadFrames/4 short of the start (missing anchor after a ~10 ms retry:
    `submission_unverified`; no bound available: `render_ahead_bound_unavailable`). Start frames are re-anchored
    beyond that bound.
  * A buffer is scheduled only once its timeline is >= 960 frames old (begin waits, within its existing bound), so
    any restart, even one no code path announced, moves the sample/host line beyond the continuity tolerance.
  * A callback is verified by a render anchor at or after it that (c) projects the callback instant to at most one
    render quantum (960 frames) before end + latency, (d) lies on the same affine sample/host line as the
    scheduling anchor (96 frames + 200 ppm), and (e) has itself reached end + latency. A missing or early anchor is
    retried for at most 200 ms, re-checking everything; nothing is projected forward or taken from elapsed time.
  * Fixes genuinely played short farewells being reported as `played_back_before_end_frame` by a few ms (measured on
    the iOS 26.5 simulator: about 20-50% of 200 ms farewells on v0.0.14).
  * (d) is evaluated only within 60 s of the scheduling anchor (tolerance <= 384 frames, below half of the >= 960-frame
    shift of any restart); beyond it the turn fails closed (`render_continuity_window_exceeded`). Because the
    emission anchor is compared with the begin anchor, a whole turn (begin to drained) is limited to 60 s.
  * New fail-closed reasons: `render_lifetime_changed`, `render_lifetime_changed_at_schedule`,
    `render_discontinuity(...)`, `render_anchor_unavailable_at_schedule`, `render_timeline_too_young`,
    `render_continuity_window_exceeded`, `render_lifetime_changed_at_begin`,
    `final_render_anchor_unavailable`, `scheduled_behind_playhead(...)`, `submission_unverified`. No Dart API change.

## 0.0.1

* TODO: Describe initial release.
