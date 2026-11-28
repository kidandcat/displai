/// Mutes Minerva while nobody can hear the Mac (its output muted or at volume 0, see
/// [DesktopWindow.outputSilent]) and puts the mute back as it was when the sound returns, unless
/// the user muted or unmuted by hand in between: then their choice stays.
class AutoMute {
  bool _silent = false;

  /// Minerva is muted because of the output (the user has not touched the mute since).
  bool _active = false;

  /// The mute before the output went silent.
  bool _before = false;

  /// Minerva is muted because the output is silent.
  bool get active => _active;

  /// The output is [silent] (or not) and Minerva's mute is [muted]: the mute to set, or null to
  /// leave it as it is. Only a change of [silent] does something.
  bool? output({required bool silent, required bool muted}) {
    if (silent == _silent) return null;
    _silent = silent;
    if (silent) {
      _active = true;
      _before = muted;
      return true;
    }
    if (!_active) return null;
    _active = false;
    return _before;
  }

  /// The user muted or unmuted by hand: the sound coming back leaves it as they set it.
  void manual() => _active = false;
}
