import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/brain/models.dart';
import 'package:minerva/l10n/l10n.dart';
import 'package:minerva/usage/usage.dart';
import 'package:minerva/usage/usage_rings.dart';

/// Claude's `/api/oauth/usage` answer, trimmed (shape as of Claude Code 2.1.302).
const _claude = '''
{"five_hour":{"utilization":7.0,"resets_at":"2026-11-26T13:00:00.765937+00:00"},
 "seven_day":{"utilization":92.0,"resets_at":"2026-11-26T15:00:00.765956+00:00"},
 "seven_day_opus":null,"seven_day_sonnet":null,
 "extra_usage":{"is_enabled":false},
 "limits":[
  {"kind":"session","group":"session","percent":7,"severity":"normal","resets_at":"2026-11-26T13:00:00.765937+00:00","scope":null},
  {"kind":"weekly_all","group":"weekly","percent":92,"severity":"critical","resets_at":"2026-11-26T15:00:00.765956+00:00","scope":null},
  {"kind":"weekly_scoped","group":"weekly","percent":5,"severity":"normal","resets_at":"2026-11-26T14:59:59.766114+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},
  {"kind":"spend","group":"spend","percent":null}
 ]}''';

/// `agy -p /usage --output-format json`'s `command.data` (Antigravity CLI 1.5.17).
const _antigravity = '''
{"description":"Within each group, models share a weekly limit and a 5-hour limit.",
 "groups":[
  {"name":"Gemini Models","description":"Models within this group: Gemini 4 Neon, Gemini 3.8 Flash","buckets":[
   {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.92,"reset_time":"2026-12-03T07:41:07Z"},
   {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.69,"reset_time":"2026-11-26T12:41:07Z"}]},
  {"name":"Claude and GPT models","description":"Models within this group: Claude Opus 5.5, GPT-OSS 120B","buckets":[
   {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"},
   {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"}]}
 ]}''';

Map<String, dynamic> _json(String s) => jsonDecode(s) as Map<String, dynamic>;

void main() {
  test("Claude's limits: the session, the week and a model's week", () {
    final w = claudeWindows(_json(_claude));
    expect([for (final x in w) (x.kind, x.used, x.scope)], [
      (UsageKind.session, 7.0, null),
      (UsageKind.week, 92.0, null),
      (UsageKind.week, 5.0, 'Fable'),
    ]);
    expect(w.first.resetsAt!.toUtc(), DateTime.utc(2026, 11, 26, 13, 0, 0, 765, 937));
  });

  test("Claude's older answer without limits reads five_hour and seven_day", () {
    final w = claudeWindows(_json('''
      {"five_hour":{"utilization":40.5,"resets_at":"2026-11-26T13:00:00Z"},
       "seven_day":{"utilization":10,"resets_at":null},
       "seven_day_opus":{"utilization":3,"resets_at":null},"seven_day_sonnet":null}'''));
    expect([for (final x in w) (x.kind, x.used, x.scope)], [
      (UsageKind.session, 40.5, null),
      (UsageKind.week, 10.0, null),
      (UsageKind.week, 3.0, 'Opus'),
    ]);
    expect(w[1].resetsAt, isNull);
    expect(claudeWindows(const {}), isEmpty);
  });

  test("Codex's windows by length, and a limit other than the plan's by name", () {
    final w = codexWindows(_json('''
      {"rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1795700000}},
       "rateLimitsByLimitId":{
        "codex":{"limitId":"codex","limitName":null,
          "primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1795700000},
          "secondary":{"usedPercent":48.5,"windowDurationMins":10080,"resetsAt":1796200000}},
        "codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-6 Spark",
          "primary":{"usedPercent":3,"windowDurationMins":1440,"resetsAt":null},"secondary":null}}}'''));
    expect([for (final x in w) (x.kind, x.used, x.scope, x.minutes)], [
      (UsageKind.session, 12.0, null, 300),
      (UsageKind.week, 48.5, null, 10080),
      (UsageKind.other, 3.0, 'GPT-6 Spark', 1440),
    ]);
    expect(w.first.resetsAt, DateTime.fromMillisecondsSinceEpoch(1795700000 * 1000));
    expect(usageLabel(w[2]), 'GPT-6 Spark 1d');
  });

  test('Codex without the multi-limit view reads its single snapshot', () {
    final w = codexWindows(_json('''
      {"rateLimits":{"limitId":null,"primary":{"usedPercent":150,"windowDurationMins":300,"resetsAt":null},
       "secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":null}},"rateLimitsByLimitId":null}'''));
    expect([for (final x in w) (x.kind, x.used)], [(UsageKind.session, 100.0), (UsageKind.week, 20.0)]);
  });

  test("Antigravity's Gemini group, and other groups only once used", () {
    final data = _json(_antigravity);
    var w = antigravityWindows(data);
    expect([for (final x in w) (x.kind, x.used.round(), x.scope)], [
      (UsageKind.session, 31, null),
      (UsageKind.week, 8, null),
    ]);
    expect(w.last.resetsAt!.toUtc(), DateTime.utc(2026, 12, 3, 7, 41, 7));

    ((data['groups'] as List)[1]['buckets'] as List)[1]['remaining_fraction'] = 0.75;
    w = antigravityWindows(data);
    expect([for (final x in w.skip(2)) (x.kind, x.used.round(), x.scope, x.resetsAt)], [
      (UsageKind.session, 25, 'Claude/GPT', null),
      (UsageKind.week, 0, 'Claude/GPT', null),
    ]);
    expect(antigravityWindows(const {}), isEmpty);
  });

  test("Claude Code's stored token, unless it has expired", () {
    final now = DateTime(2026, 11, 26, 10);
    String creds(int expires) => jsonEncode({
          'claudeAiOauth': {'accessToken': 'test-token', 'expiresAt': expires},
        });
    expect(claudeOAuthToken(creds(now.millisecondsSinceEpoch + 60000), now: now), 'test-token');
    expect(claudeOAuthToken(creds(now.millisecondsSinceEpoch - 1), now: now), isNull);
    expect(claudeOAuthToken('{"mcpOAuth":{}}', now: now), isNull);
    expect(claudeOAuthToken('not json', now: now), isNull);
  });

  test('a window that has started over reads as unused', () {
    final w = UsageWindow(kind: UsageKind.session, used: 80, resetsAt: DateTime(2026, 11, 26, 12));
    expect(w.usedAt(DateTime(2026, 11, 26, 11)), 80);
    expect(w.usedAt(DateTime(2026, 11, 26, 12)), 0);
    expect(usageLabel(w), '5h');
    expect(usageColor(50), isNot(usageColor(80)));
    expect(usageColor(95), Colors.redAccent);
  });

  group('UsageMonitor', () {
    late DateTime now;
    late Map<BrainProvider, Object?> answers;
    late Map<BrainProvider, int> reads;
    late Set<BrainProvider> configured;

    UsageMonitor monitor() => UsageMonitor(
          providers: () => configured,
          clock: () => now,
          readers: {
            for (final p in BrainProvider.values)
              p: () async {
                reads[p] = (reads[p] ?? 0) + 1;
                final a = answers[p];
                if (a is Exception) throw a;
                return a as List<UsageWindow>?;
              },
          },
        );

    const window = UsageWindow(kind: UsageKind.session, used: 40);

    setUp(() {
      now = DateTime(2026, 11, 26, 10);
      answers = {BrainProvider.claude: [window], BrainProvider.codex: null, BrainProvider.antigravity: [window]};
      reads = {};
      configured = {BrainProvider.claude, BrainProvider.codex};
    });

    test('shows only configured providers it could read, and reads each every interval', () async {
      final m = monitor();
      await m.refresh();
      expect([for (final u in m.shown) u.provider], [BrainProvider.claude]);
      expect(reads, {BrainProvider.claude: 1, BrainProvider.codex: 1});

      now = now.add(const Duration(minutes: 1));
      await m.refresh();
      expect(reads, {BrainProvider.claude: 1, BrainProvider.codex: 1});

      configured = {BrainProvider.claude, BrainProvider.antigravity};
      now = now.add(UsageMonitor.interval);
      await m.refresh();
      expect(reads, {BrainProvider.claude: 2, BrainProvider.codex: 1, BrainProvider.antigravity: 1});
      expect([for (final u in m.shown) u.provider], [BrainProvider.claude, BrainProvider.antigravity]);
      m.dispose();
    });

    test('waits longer after each failure, keeps the last reading a while, then hides it', () async {
      final m = monitor();
      await m.refresh();
      answers[BrainProvider.claude] = null;
      final waits = <Duration>[];
      var at = now;
      for (var i = 0; i < 6; i++) {
        // Step a minute at a time until it reads again.
        final before = reads[BrainProvider.claude]!;
        while (reads[BrainProvider.claude] == before) {
          now = now.add(const Duration(minutes: 1));
          await m.refresh();
        }
        waits.add(now.difference(at));
        at = now;
      }
      expect(waits.map((d) => d.inMinutes), [5, 5, 10, 20, 40, 60]);
      expect(m.shown, isEmpty);
      // Codex never read: its failures do not show anything either.
      expect(reads[BrainProvider.codex], greaterThan(1));
      m.dispose();
    });

    test('a throttled read waits as long as the provider says', () async {
      answers[BrainProvider.claude] = const UsageThrottled(Duration(minutes: 50));
      final m = monitor();
      await m.refresh();
      now = now.add(const Duration(minutes: 49));
      await m.refresh();
      expect(reads[BrainProvider.claude], 1);
      now = now.add(const Duration(minutes: 1));
      await m.refresh();
      expect(reads[BrainProvider.claude], 2);
      m.dispose();
    });

    testWidgets('the rings show each limit with its percent', (tester) async {
      answers[BrainProvider.claude] = claudeWindows(_json(_claude));
      final m = monitor();
      await m.refresh();
      // Before the resets in the fixture.
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: UsageRings(monitor: m)),
      ));
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('5h'), findsOneWidget);
      expect(find.text('Fable 7d'), findsOneWidget);
      m.dispose();
    });
  });
}
