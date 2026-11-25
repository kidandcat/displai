import 'dart:convert';

import '../store/store.dart';
import 'models.dart';

/// Why a provider can't take turns for a while.
enum LimitReason {
  /// Its usage limit, rate limit or quota is reached (the account's: every model of it).
  usage,

  /// It is not signed in (or its login expired).
  signIn,
}

/// A provider said it can't answer for now: [resetsAt] when it says when that ends.
class ProviderLimit {
  const ProviderLimit(this.reason, {this.resetsAt});
  final LimitReason reason;
  final DateTime? resetsAt;

  @override
  String toString() => 'ProviderLimit(${reason.name}, resets $resetsAt)';
}

/// Until when a provider is out, and why.
typedef ProviderOut = ({DateTime until, LimitReason reason});

/// Reads a provider's error for a usage limit, rate limit or quota (or a lost login), else null.
/// Claude Code: "You've hit your limit · resets 3pm (Europe/Madrid)", "Claude AI usage limit
/// reached|1764003600"; Antigravity: "RESOURCE_EXHAUSTED", "quota"; Codex: "You've hit your
/// usage limit… try again at 3:45 PM". [now] is when the error came.
ProviderLimit? limitIn(String? error, {DateTime? now}) {
  if (error == null || error.isEmpty) return null;
  final e = error.toLowerCase();
  if (_signIn.hasMatch(e)) return const ProviderLimit(LimitReason.signIn);
  if (!_usage.hasMatch(e)) return null;
  return ProviderLimit(LimitReason.usage, resetsAt: resetIn(error, now: now ?? DateTime.now()));
}

final _usage = RegExp(
  r'usage limit|rate[ _-]?limit|hit your limit|limit reached|limit exceeded|quota|resource[ _]exhausted|'
  r'too many requests|\b429\b|out of (extra )?usage|credit balance is too low|usagelimitexceeded|'
  r'ratelimitexceeded',
);

final _signIn = RegExp(
  r'not (signed|logged) in|please (run /login|log ?in|sign in)|log out and sign in again|'
  r'authentication (failed|required)|oauth token (has )?(expired|revoked)|access token could not be refreshed|'
  r'invalid api key|\b401\b|unauthorized',
);

/// When the limit in [error] ends, if it says: a Unix time after `|` (Claude Code's older form),
/// "in 2 hours 30 minutes", or a clock time ("resets 3pm", "try again at 15:30") taken as the
/// next time it is that time here.
DateTime? resetIn(String error, {required DateTime now}) {
  final unix = RegExp(r'\|(\d{10})\b').firstMatch(error);
  if (unix != null) return DateTime.fromMillisecondsSinceEpoch(int.parse(unix[1]!) * 1000);
  final e = error.toLowerCase();
  final rel = RegExp(r'\bin\s+(?:(\d+)\s*(?:h|hours?|hrs?)\b)?\s*(?:(\d+)\s*(?:m|min|mins|minutes?)\b)?').allMatches(e);
  for (final m in rel) {
    if (m[1] == null && m[2] == null) continue;
    return now.add(Duration(hours: int.parse(m[1] ?? '0'), minutes: int.parse(m[2] ?? '0')));
  }
  final at = RegExp(r'(?:resets?|again|until|after)\s+(?:at\s+|on\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?')
      .firstMatch(e);
  if (at == null || (at[2] == null && at[3] == null)) return null;
  var hour = int.parse(at[1]!);
  final minute = int.parse(at[2] ?? '0');
  final pm = at[3]?.startsWith('p');
  if (pm != null) hour = hour % 12 + (pm ? 12 : 0);
  if (hour > 23 || minute > 59) return null;
  var t = DateTime(now.year, now.month, now.day, hour, minute);
  if (!t.isAfter(now)) t = t.add(const Duration(days: 1));
  return t;
}

/// Which providers are out for now, shared by the conversation and the workers (a limit is the
/// account's, whichever session hit it), saved so it survives restarts. Minerva runs on the first
/// choice of a fallback chain whose provider is not out ([pick]), and goes back to an earlier
/// one once its time is up.
class ProviderLimits {
  ProviderLimits({this.store, this.onChange}) {
    final raw = store?.get(_key);
    if (raw == null) return;
    try {
      for (final e in (jsonDecode(raw) as Map).entries) {
        final p = BrainProvider.values.where((p) => p.name == e.key).firstOrNull;
        final v = e.value;
        if (p == null || v is! Map || v['until'] is! int) continue;
        _limits[p] = (
          until: DateTime.fromMillisecondsSinceEpoch(v['until'] as int),
          reason: LimitReason.values.where((r) => r.name == v['reason']).firstOrNull ?? LimitReason.usage,
        );
      }
    } catch (_) {}
  }

  final Store? store;

  /// Called when a provider goes out or comes back.
  void Function()? onChange;

  static const _key = 'provider_limits';

  /// How long a provider is left alone when it does not say when its limit ends: long enough
  /// not to fail every turn, short enough to notice a reset soon.
  static const usageRetry = Duration(minutes: 30);
  static const signInRetry = Duration(minutes: 10);

  /// A reset further away than this is taken as a mistake (a misread time).
  static const _longest = Duration(days: 8);

  final _limits = <BrainProvider, ProviderOut>{};

  /// When [provider] can be used again, or null if it can now.
  DateTime? until(BrainProvider provider, {DateTime? now}) {
    final l = _limits[provider];
    if (l == null || !l.until.isAfter(now ?? DateTime.now())) return null;
    return l.until;
  }

  LimitReason? reason(BrainProvider provider, {DateTime? now}) => out(provider, now: now)?.reason;

  /// Until when [provider] is out and why, or null if it can be used now.
  ProviderOut? out(BrainProvider provider, {DateTime? now}) =>
      until(provider, now: now) == null ? null : _limits[provider];

  /// Every provider that is out now (what the phone shows).
  Map<BrainProvider, ProviderOut> all({DateTime? now}) => {for (final p in BrainProvider.values) p: ?out(p, now: now)};

  /// [provider] said it is out: leave it alone until its reset (or a while, when it does not say).
  void hit(BrainProvider provider, ProviderLimit limit, {DateTime? now}) {
    now ??= DateTime.now();
    var until = limit.resetsAt ?? now.add(limit.reason == LimitReason.signIn ? signInRetry : usageRetry);
    if (!until.isAfter(now) || until.difference(now) > _longest) until = now.add(usageRetry);
    _limits[provider] = (until: until, reason: limit.reason);
    _save();
    onChange?.call();
  }

  /// [provider] answered: whatever it said before is over.
  void clear(BrainProvider provider) {
    if (_limits.remove(provider) == null) return;
    _save();
    onChange?.call();
  }

  void _save() => store?.set(
    _key,
    _limits.isEmpty
        ? null
        : jsonEncode({
            for (final e in _limits.entries)
              e.key.name: {'until': e.value.until.millisecondsSinceEpoch, 'reason': e.value.reason.name},
          }),
  );

  /// The choice to run on: the first of [chain] whose provider is installed and not out. When all
  /// are out, the one back soonest (Minerva tries it anyway rather than not answering).
  ModelChoice pick(List<ModelChoice> chain, {Set<BrainProvider> unavailable = const {}, DateTime? now}) {
    now ??= DateTime.now();
    for (final c in chain) {
      if (!unavailable.contains(c.provider) && until(c.provider, now: now) == null) return c;
    }
    final usable = [
      for (final c in chain)
        if (!unavailable.contains(c.provider)) c,
    ];
    if (usable.isEmpty) return chain.first;
    return usable.reduce((a, b) => until(b.provider, now: now)!.isBefore(until(a.provider, now: now)!) ? b : a);
  }

  /// The choice to go on with when [from] just went out: the first of [chain] on another
  /// provider that is not out, or null when none can take over now.
  ModelChoice? next(
    List<ModelChoice> chain,
    BrainProvider from, {
    Set<BrainProvider> unavailable = const {},
    DateTime? now,
  }) {
    for (final c in chain) {
      if (c.provider == from || unavailable.contains(c.provider)) continue;
      if (until(c.provider, now: now) == null) return c;
    }
    return null;
  }
}

/// The preferred choice followed by its fallbacks, without repeating a provider (each provider
/// runs one choice: its limit is the account's, whatever the model).
List<ModelChoice> fallbackChain(ModelChoice preferred, List<ModelChoice> fallbacks) {
  final seen = {preferred.provider};
  return [
    preferred,
    for (final f in fallbacks)
      if (seen.add(f.provider)) f,
  ];
}

/// Saved fallbacks of the conversation (`brain`) or the workers (`workers`), in order.
List<ModelChoice> loadFallbacks(Store store, String prefix) {
  final raw = store.get('$prefix.fallbacks');
  if (raw == null) return const [];
  try {
    return fallbacksFromJson(jsonDecode(raw)) ?? const [];
  } catch (_) {
    return const [];
  }
}

void saveFallbacks(Store store, String prefix, List<ModelChoice> fallbacks) =>
    store.set('$prefix.fallbacks', fallbacks.isEmpty ? null : jsonEncode([for (final f in fallbacks) f.toJson()]));

/// Fallbacks from a JSON list of [ModelChoice.toJson] (the store, or settings sent between the
/// desktop and the phone), skipping malformed ones; null if [j] is not a list.
List<ModelChoice>? fallbacksFromJson(Object? j) => j is List ? [for (final c in j) ?ModelChoice.fromJson(c)] : null;
