import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../brain/antigravity_session.dart';
import '../brain/codex_session.dart';
import '../brain/models.dart';

/// Which limit a [UsageWindow] is.
enum UsageKind {
  /// The rolling five-hour limit.
  session,

  /// The weekly limit.
  week,

  /// Any other length (Codex says it in minutes).
  other,
}

/// One usage limit of a provider's plan: how much of it is spent and when it starts over.
class UsageWindow {
  const UsageWindow({required this.kind, required this.used, this.resetsAt, this.scope, this.minutes});

  final UsageKind kind;

  /// Percent spent, 0–100.
  final double used;
  final DateTime? resetsAt;

  /// The models it is for when it is not the whole plan's (Claude's weekly limit of one model,
  /// an Antigravity model group other than Gemini's), else null.
  final String? scope;

  /// Length of an [UsageKind.other] window.
  final int? minutes;

  /// [used] as of [now]: nothing once the window has started over since it was read.
  double usedAt(DateTime now) => resetsAt != null && !resetsAt!.isAfter(now) ? 0 : used;

  /// Percent of the limit left as of [now], 0–100.
  double leftAt(DateTime now) => (100 - usedAt(now)).clamp(0, 100).toDouble();

  /// How long the window is.
  Duration? get length => switch (kind) {
        UsageKind.session => const Duration(hours: 5),
        UsageKind.week => const Duration(days: 7),
        UsageKind.other => minutes == null ? null : Duration(minutes: minutes!),
      };

  /// Where the spending so far leads by the reset, at the same pace (see [UsageProjection]).
  UsageProjection projectAt(DateTime now) {
    final spent = usedAt(now);
    final reset = resetsAt;
    final len = length;
    if (spent >= 100) return const UsageProjection(UsageLevel.bad, spent: true);
    // No reset time (a window that has not started) or no length: judged by what is spent.
    if (reset == null || len == null || !reset.isAfter(now)) return UsageProjection(UsageProjection.levelOf(spent));
    final start = reset.subtract(len);
    final elapsed = now.difference(start);
    final fraction = elapsed.inMilliseconds / len.inMilliseconds;
    // Too early in the window for the pace to mean much: judged by what is spent.
    if (fraction < UsageProjection.earliest) return UsageProjection(UsageProjection.levelOf(spent));
    final projected = spent / fraction.clamp(0, 1);
    final runsOut = spent > 0 ? start.add(elapsed * (100 / spent)) : null;
    return UsageProjection(
      UsageProjection.levelOf(projected),
      projected: projected,
      runsOutAt: runsOut != null && runsOut.isBefore(reset) ? runsOut : null,
    );
  }

  /// As the desktop sends it to the phone (see remote/protocol.dart).
  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'used': used,
        if (resetsAt != null) 'resets_at': resetsAt!.millisecondsSinceEpoch,
        if (scope != null) 'scope': scope,
        if (minutes != null) 'minutes': minutes,
      };

  /// A window the desktop sent, or null when it is not one.
  static UsageWindow? fromJson(Object? j) {
    if (j is! Map || j['used'] is! num) return null;
    return UsageWindow(
      kind: UsageKind.values.where((k) => k.name == j['kind']).firstOrNull ?? UsageKind.other,
      used: _percent(j['used']),
      resetsAt: j['resets_at'] is int ? DateTime.fromMillisecondsSinceEpoch(j['resets_at'] as int) : null,
      scope: j['scope'] is String ? j['scope'] as String : null,
      minutes: (j['minutes'] as num?)?.toInt(),
    );
  }

  @override
  String toString() => 'UsageWindow(${kind.name}${scope == null ? '' : ' $scope'}, $used%, resets $resetsAt)';
}

/// Whether a limit lasts until its reset: [good] (green) it does with room to spare (spending
/// less is never a problem), [fair] (orange) it ends close to the limit, [bad] (red) at this pace
/// it runs out before the reset, or it already has.
enum UsageLevel { good, fair, bad }

/// A limit's spending projected to the end of its window, at the pace so far: [projected] is
/// the percent it would reach by the reset (null when it can't tell: no reset time, or the window
/// has barely started), [runsOutAt] when it would reach 100 % if that is before the reset.
/// [spent]: it already ran out.
class UsageProjection {
  const UsageProjection(this.level, {this.projected, this.runsOutAt, this.spent = false});

  final UsageLevel level;
  final double? projected;
  final DateTime? runsOutAt;
  final bool spent;

  /// Before this fraction of the window has gone by, the pace is not projected (a little use
  /// early on would read as a lot): the level goes by what is spent.
  static const earliest = 0.10;

  /// Orange above this projected percent, red above [badAbove].
  static const fairAbove = 90.0;
  static const badAbove = 110.0;

  static UsageLevel levelOf(double percent) => percent > badAbove
      ? UsageLevel.bad
      : percent > fairAbove
          ? UsageLevel.fair
          : UsageLevel.good;

  @override
  String toString() => 'UsageProjection(${level.name}, $projected%, runs out $runsOutAt)';
}

/// A provider's limits as last read.
class ProviderUsage {
  const ProviderUsage(this.provider, this.windows, {required this.readAt});

  final BrainProvider provider;
  final List<UsageWindow> windows;
  final DateTime readAt;

  Map<String, Object?> toJson() => {
        'provider': provider.name,
        'read_at': readAt.millisecondsSinceEpoch,
        'windows': [for (final w in windows) w.toJson()],
      };

  /// A provider's usage the desktop sent, or null when it is not one (or names a provider this
  /// app does not know).
  static ProviderUsage? fromJson(Object? j) {
    if (j is! Map) return null;
    final provider = BrainProvider.values.where((p) => p.name == j['provider']).firstOrNull;
    if (provider == null) return null;
    final windows = [
      for (final w in j['windows'] is List ? j['windows'] as List : const []) ?UsageWindow.fromJson(w),
    ];
    final readAt = j['read_at'];
    return ProviderUsage(provider, windows,
        readAt: readAt is int ? DateTime.fromMillisecondsSinceEpoch(readAt) : DateTime.now());
  }
}

/// What the usage rings show: the desktop's [UsageMonitor], or on the phone [SentUsage].
abstract interface class UsageSource implements Listenable {
  /// The providers with a reading, in order.
  List<ProviderUsage> get shown;
}

/// The phone's copy of the usage the desktop last sent (its `usage` message).
class SentUsage extends ChangeNotifier implements UsageSource {
  @override
  List<ProviderUsage> shown = const [];

  /// The providers in a `usage` message (see remote/protocol.dart).
  void apply(Object? providers) {
    shown = [
      for (final p in providers is List ? providers : const [])
        if (ProviderUsage.fromJson(p) case final u? when u.windows.isNotEmpty) u,
    ];
    notifyListeners();
  }
}

/// The provider answered "too many requests": read again after [retryAfter] (or the usual wait).
class UsageThrottled implements Exception {
  const UsageThrottled([this.retryAfter]);
  final Duration? retryAfter;

  @override
  String toString() => 'usage read throttled (retry after $retryAfter)';
}

double _percent(Object? v) => v is num ? v.toDouble().clamp(0, 100).toDouble() : 0;

DateTime? _time(Object? v) {
  if (v is num) return v <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000);
  if (v is! String) return null;
  final t = DateTime.tryParse(v);
  // Antigravity sends the epoch for a bucket that has nothing to reset.
  return t == null || t.year < 2000 ? null : t.toLocal();
}

/// Claude's plan usage (`GET /api/oauth/usage`, the answer behind Claude Code's `/usage`): its
/// `limits` (the five-hour session, the weekly limit and the weekly limit of one model), else
/// the older `five_hour` and `seven_day*` fields. Utilization is already a percent.
List<UsageWindow> claudeWindows(Map<String, dynamic> j) {
  final limits = j['limits'];
  if (limits is List && limits.isNotEmpty) {
    return [
      for (final l in limits)
        if (l is Map && l['percent'] is num)
          if (_claudeKind(l) case final kind?)
            UsageWindow(
              kind: kind,
              used: _percent(l['percent']),
              resetsAt: _time(l['resets_at']),
              scope: switch (l['scope']) {
                {'model': {'display_name': final String name}} => name,
                _ => null,
              },
            ),
    ];
  }
  UsageWindow? window(String key, UsageKind kind, [String? scope]) {
    final w = j[key];
    if (w is! Map || w['utilization'] is! num) return null;
    return UsageWindow(kind: kind, used: _percent(w['utilization']), resetsAt: _time(w['resets_at']), scope: scope);
  }

  return [
    ?window('five_hour', UsageKind.session),
    ?window('seven_day', UsageKind.week),
    ?window('seven_day_opus', UsageKind.week, 'Opus'),
    ?window('seven_day_sonnet', UsageKind.week, 'Sonnet'),
  ];
}

UsageKind? _claudeKind(Map l) => switch (l['group'] ?? l['kind']) {
      'session' => UsageKind.session,
      'weekly' => UsageKind.week,
      _ => null,
    };

/// Codex's rate limits (the app server's `account/rateLimits/read`): each limit's primary
/// (usually five hours) and secondary (usually weekly) window. A limit other than the plan's
/// own (`codex`) is scoped by its name.
List<UsageWindow> codexWindows(Map<String, dynamic> j) {
  final byId = j['rateLimitsByLimitId'];
  final snapshots = [
    if (byId is Map)
      for (final s in byId.values)
        if (s is Map) s,
  ];
  if (snapshots.isEmpty && j['rateLimits'] is Map) snapshots.add(j['rateLimits'] as Map);
  return [
    for (final s in snapshots)
      for (final w in [s['primary'], s['secondary']])
        if (w is Map && w['usedPercent'] is num)
          UsageWindow(
            kind: switch (w['windowDurationMins']) {
              300 => UsageKind.session,
              10080 => UsageKind.week,
              _ => UsageKind.other,
            },
            used: _percent(w['usedPercent']),
            resetsAt: _time(w['resetsAt']),
            minutes: (w['windowDurationMins'] as num?)?.toInt(),
            scope: s['limitId'] == null || s['limitId'] == 'codex' ? null : '${s['limitName'] ?? s['limitId']}',
          ),
  ];
}

/// Antigravity's quota (`agy -p /usage --output-format json`, its `command.data`): model groups
/// that each share a five-hour and a weekly limit. The Gemini group is the plan's own; another
/// group (Claude and GPT models) shows only once some of it is spent.
List<UsageWindow> antigravityWindows(Map<String, dynamic> j) {
  final groups = j['groups'];
  if (groups is! List) return const [];
  final windows = <UsageWindow>[];
  for (final g in groups) {
    if (g is! Map || g['buckets'] is! List) continue;
    final name = '${g['name'] ?? ''}';
    final gemini = RegExp(r'^gemini\b', caseSensitive: false).hasMatch(name);
    final group = [
      for (final b in g['buckets'] as List)
        if (b is Map && b['remaining_fraction'] is num)
          UsageWindow(
            kind: switch (b['window']) {
              '5h' => UsageKind.session,
              'weekly' => UsageKind.week,
              _ => UsageKind.other,
            },
            used: _percent(100 * (1 - (b['remaining_fraction'] as num))),
            resetsAt: _time(b['reset_time']),
            scope: gemini ? null : shortGroupName(name),
          ),
    ];
    group.sort((a, b) => a.kind.index.compareTo(b.kind.index));
    if (gemini || group.any((w) => w.used > 0)) windows.addAll(group);
  }
  return windows;
}

/// "Claude and GPT models" → "Claude/GPT".
String shortGroupName(String name) =>
    name.replaceAll(RegExp(r'\s+models?$', caseSensitive: false), '').replaceAll(' and ', '/').trim();

/// Reads one provider's limits: null when it can't (not signed in, not installed, offline).
typedef UsageReader = Future<List<UsageWindow>?> Function();

/// The usage limits of the providers Minerva runs on, read every [interval] and kept for the
/// status bar. Each provider is read on its own; after a failed read it waits longer each time
/// (up to [longestWait]), as Claude's usage endpoint is shared with Claude Code and answers 429
/// for a long while when asked too often. A provider whose reading fails keeps it for
/// [keepFailed], then it is hidden.
class UsageMonitor extends ChangeNotifier implements UsageSource {
  UsageMonitor({required this.providers, Map<BrainProvider, UsageReader>? readers, DateTime Function()? clock})
      : readers = readers ?? defaultReaders,
        _clock = clock ?? DateTime.now;

  /// The providers to show: the ones Minerva's brain and workers are set to run on.
  final Set<BrainProvider> Function() providers;
  final Map<BrainProvider, UsageReader> readers;
  final DateTime Function() _clock;

  static const interval = Duration(minutes: 5);
  static const longestWait = Duration(hours: 1);
  static const keepFailed = Duration(minutes: 30);

  static final defaultReaders = <BrainProvider, UsageReader>{
    BrainProvider.claude: readClaudeUsage,
    BrainProvider.codex: readCodexUsage,
    BrainProvider.antigravity: readAntigravityUsage,
  };

  final _usage = <BrainProvider, ProviderUsage>{};
  final _next = <BrainProvider, DateTime>{};
  final _failures = <BrainProvider, int>{};
  final _reading = <BrainProvider>{};
  Timer? _timer;
  bool _disposed = false;

  /// What to show, in the providers' order: the configured ones with a reading.
  @override
  List<ProviderUsage> get shown {
    final want = providers();
    return [
      for (final p in BrainProvider.values)
        if (want.contains(p) && _usage[p] != null && _usage[p]!.windows.isNotEmpty) _usage[p]!,
    ];
  }

  /// Reads now, then checks every minute which provider is due.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  /// Reads each configured provider that is due (all of them with [force]).
  Future<void> refresh({bool force = false}) async {
    final now = _clock();
    await Future.wait([
      for (final p in providers())
        if (readers[p] != null && !_reading.contains(p) && (force || !(_next[p]?.isAfter(now) ?? false))) _read(p),
    ]);
  }

  Future<void> _read(BrainProvider p) async {
    _reading.add(p);
    Duration? retryAfter;
    List<UsageWindow>? windows;
    try {
      windows = await readers[p]!();
    } on UsageThrottled catch (e) {
      retryAfter = e.retryAfter;
    } catch (e) {
      debugPrint('usage: ${p.name} read failed: ${e.runtimeType}');
    } finally {
      _reading.remove(p);
    }
    if (_disposed) return;
    final now = _clock();
    if (windows != null) {
      _failures.remove(p);
      _usage[p] = ProviderUsage(p, windows, readAt: now);
      _next[p] = now.add(interval);
    } else {
      final n = _failures[p] = (_failures[p] ?? 0) + 1;
      // 5, 10, 20, 40 minutes, then an hour.
      final wait = interval * (1 << (n - 1).clamp(0, 4));
      _next[p] = now.add(retryAfter ?? (wait > longestWait ? longestWait : wait));
      final last = _usage[p];
      if (last != null && now.difference(last.readAt) > keepFailed) _usage.remove(p);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

// ---------------------------------------------------------------- readers

/// Claude's plan usage with Claude Code's own sign-in (its OAuth token in the login Keychain,
/// or in `~/.claude/.credentials.json`). An expired token is left for Claude Code to refresh:
/// refreshing it here would replace the one Claude Code keeps.
Future<List<UsageWindow>?> readClaudeUsage() async {
  final token = await _claudeToken();
  if (token == null) return null;
  final r = await http.get(Uri.parse('https://api.anthropic.com/api/oauth/usage'), headers: {
    'Authorization': 'Bearer $token',
    'anthropic-beta': 'oauth-2025-04-20',
    'Accept': 'application/json',
  }).timeout(const Duration(seconds: 20));
  if (r.statusCode == 429) {
    final s = int.tryParse(r.headers['retry-after'] ?? '');
    throw UsageThrottled(s == null ? null : Duration(seconds: s));
  }
  if (r.statusCode != 200) return null;
  final body = jsonDecode(r.body);
  return body is Map<String, dynamic> ? claudeWindows(body) : null;
}

Future<String?> _claudeToken() async {
  final user = Platform.environment['USER'];
  for (final args in [
    if (user != null) ['find-generic-password', '-s', 'Claude Code-credentials', '-a', user, '-w'],
    ['find-generic-password', '-s', 'Claude Code-credentials', '-w'],
  ]) {
    final r = await Process.run('/usr/bin/security', args).timeout(const Duration(seconds: 10));
    if (r.exitCode != 0) continue;
    final token = claudeOAuthToken('${r.stdout}');
    if (token != null) return token;
  }
  final file = File('${Platform.environment['HOME']}/.claude/.credentials.json');
  return file.existsSync() ? claudeOAuthToken(await file.readAsString()) : null;
}

/// The access token in Claude Code's stored credentials, if it has one that has not expired.
@visibleForTesting
String? claudeOAuthToken(String credentials, {DateTime? now}) {
  try {
    final oauth = (jsonDecode(credentials) as Map)['claudeAiOauth'];
    if (oauth is! Map || oauth['accessToken'] is! String) return null;
    final expires = oauth['expiresAt'];
    if (expires is num && expires < (now ?? DateTime.now()).millisecondsSinceEpoch) return null;
    return oauth['accessToken'] as String;
  } catch (_) {
    return null;
  }
}

/// Codex's rate limits through its app server, signed in with ChatGPT.
Future<List<UsageWindow>?> readCodexUsage() async {
  final j = await CodexSession.readRateLimits();
  return j == null ? null : codexWindows(j);
}

/// Antigravity's quota through its CLI's `/usage` (answered without a model turn).
Future<List<UsageWindow>?> readAntigravityUsage() async {
  final j = await AntigravitySession.readUsage();
  return j == null ? null : antigravityWindows(j);
}
