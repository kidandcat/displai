/// Presence animation: the app's audio-reactive "face".
///
/// Usage: create one [PresenceSignal], set its `mode`, feed it audio with
/// `addAudio`, and show it with `PresenceView(signal: s)` (full window) or
/// `PresenceView(signal: s, compact: true)` (status-bar orb).
library;

export 'presence_signal.dart' show PresenceMode, PresenceSignal;
export 'presence_view.dart'
    show
        PresenceView,
        PresenceFrame,
        kPresenceAccent,
        kPresenceAccent2,
        kPresenceBackground;
