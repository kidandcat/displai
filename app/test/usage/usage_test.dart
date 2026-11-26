import 'dart:convert';

import 'package:flutter/gestures.dart';
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
    expect(w[2].length, const Duration(days: 1));
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
  });

  group('projection', () {
    // A five-hour window that started at 10:00 and a week that started a Monday at 9:00.
    final reset5h = DateTime(2026, 11, 26, 15);
    final resetWeek = DateTime(2026, 11, 30, 9);
    UsageWindow session(double used) => UsageWindow(kind: UsageKind.session, used: used, resetsAt: reset5h);
    UsageWindow week(double used) => UsageWindow(kind: UsageKind.week, used: used, resetsAt: resetWeek);

    test("underuse is fine: day 6 of 7 with 30 % spent is green (about 35 % by the reset)", () {
      final p = week(30).projectAt(DateTime(2026, 11, 29, 9));
      expect(p.projected, closeTo(35, 0.01));
      expect(p.level, UsageLevel.good);
      expect(p.runsOutAt, isNull);
    });

    test('green up to 90 % projected, orange to 110 %, red beyond', () {
      final half = DateTime(2026, 11, 26, 12, 30);
      expect([
        for (final used in <double>[10, 45, 46, 50, 55, 56])
          if (session(used).projectAt(half) case final p) (p.projected!.round(), p.level),
      ], [
        (20, UsageLevel.good),
        (90, UsageLevel.good),
        (92, UsageLevel.fair),
        (100, UsageLevel.fair),
        (110, UsageLevel.fair),
        (112, UsageLevel.bad),
      ]);
    });

    test('when it would run out, if before the reset', () {
      // An hour in (a fifth of the window), 40 % spent: 200 % by the reset, out at 12:30.
      final p = session(40).projectAt(DateTime(2026, 11, 26, 11));
      expect(p.projected, closeTo(200, 0.01));
      expect(p.level, UsageLevel.bad);
      expect(p.runsOutAt, DateTime(2026, 11, 26, 12, 30));
      // Exactly 100 % at the reset: it does not run out before it.
      expect(session(50).projectAt(DateTime(2026, 11, 26, 12, 30)).runsOutAt, isNull);
    });

    test('a spent limit is red; early in a window or with no reset, what is spent decides', () {
      final spent = session(100).projectAt(DateTime(2026, 11, 26, 14));
      expect((spent.level, spent.spent, spent.projected), (UsageLevel.bad, true, null));
      // Twenty minutes in (under a tenth of the window): 15 % spent is no projection yet.
      final early = session(15).projectAt(DateTime(2026, 11, 26, 10, 20));
      expect((early.level, early.projected), (UsageLevel.good, null));
      expect(session(95).projectAt(DateTime(2026, 11, 26, 10, 20)).level, UsageLevel.fair);
      expect(const UsageWindow(kind: UsageKind.week, used: 50).projectAt(DateTime(2026, 11, 26)).level, UsageLevel.good);
      // After the reset the window reads as unused.
      expect(session(99).projectAt(DateTime(2026, 11, 26, 16)).level, UsageLevel.good);
      expect(usageColor(UsageLevel.good), isNot(usageColor(UsageLevel.bad)));
    });

    test('rings show what is left: green while plenty, amber, then red as it runs out', () {
      final now = DateTime(2026, 11, 26, 12);
      expect(session(30).leftAt(now), 70);
      expect(session(100).leftAt(now), 0);
      expect(session(99).leftAt(DateTime(2026, 11, 26, 16)), 100);
      expect(leftColor(100), leftColor(50));
      expect(leftColor(25), isNot(leftColor(50)));
      expect(leftColor(0), isNot(leftColor(25)));
      expect(leftColor(0), usageColor(UsageLevel.bad));
    });
  });

  test('rings from the outside in: the plan\'s limits, shortest first, then a model\'s', () {
    final w = ringOrder(claudeWindows(_json(_claude)).reversed.toList());
    expect([for (final x in w) (x.kind, x.scope)], [
      (UsageKind.session, null),
      (UsageKind.week, null),
      (UsageKind.week, 'Fable'),
    ]);
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

    testWidgets('a dial per provider; hovering it opens the card with each limit', (tester) async {
      final now = DateTime.now();
      answers[BrainProvider.claude] = [
        UsageWindow(kind: UsageKind.session, used: 40, resetsAt: now.add(const Duration(hours: 4))),
        UsageWindow(kind: UsageKind.week, used: 30, resetsAt: now.add(const Duration(days: 3))),
        UsageWindow(kind: UsageKind.week, used: 5, resetsAt: now.add(const Duration(days: 3)), scope: 'Fable'),
      ];
      configured = {BrainProvider.claude, BrainProvider.antigravity};
      final m = monitor();
      await m.refresh();
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Align(alignment: Alignment.bottomLeft, child: UsageRings(monitor: m))),
      ));
      expect(find.byType(UsageDial), findsNWidgets(2));
      expect(find.text('5-hour limit'), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(UsageDial).first));
      await tester.pumpAndSettle();
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('5-hour limit'), findsOneWidget);
      expect(find.text('Weekly limit'), findsOneWidget);
      expect(find.text('Fable · Weekly limit'), findsOneWidget);
      expect(find.text('60% left'), findsOneWidget);
      // An hour into the five hours with 40 % spent: 200 %, out in an hour and a half.
      expect(find.textContaining('projected 200% by the reset · runs out around'), findsOneWidget);

      await mouse.moveTo(const Offset(600, 10));
      await tester.pumpAndSettle();
      expect(find.text('5-hour limit'), findsNothing);
      m.dispose();
    });
  });
}
