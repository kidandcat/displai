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
      expect(p.percent, p.projected);
      expect(paceColor(p.percent), paceColor(0));
      expect(p.runsOutAt, isNull);
    });

    test('the color goes by the projection: green to 70 %, amber at 85 %, red from 100 %', () {
      final half = DateTime(2026, 11, 26, 12, 30);
      expect([for (final used in <double>[10, 35, 45, 50, 55]) session(used).projectAt(half).percent.round()],
          [20, 70, 90, 100, 110]);
      expect(paceColor(70), paceColor(0));
      expect(paceColor(85), const Color(0xFFFFB020));
      expect(paceColor(100), const Color(0xFFFF5C5C));
      expect(paceColor(273), paceColor(100));
      // Redder (less green) the closer it gets to 100 %.
      final greens = [for (final p in <double>[70, 78, 85, 92, 99, 100]) paceColor(p).g];
      for (var i = 1; i < greens.length; i++) {
        expect(greens[i], lessThan(greens[i - 1]));
      }
    });

    test('when it would run out, if before the reset', () {
      // An hour in (a fifth of the window), 40 % spent: 200 % by the reset, out at 12:30.
      final p = session(40).projectAt(DateTime(2026, 11, 26, 11));
      expect(p.projected, closeTo(200, 0.01));
      expect(paceColor(p.percent), paceColor(100));
      expect(p.runsOutAt, DateTime(2026, 11, 26, 12, 30));
      // Exactly 100 % at the reset: it does not run out before it, but it is red.
      final exact = session(50).projectAt(DateTime(2026, 11, 26, 12, 30));
      expect((exact.runsOutAt, paceColor(exact.percent)), (null, paceColor(100)));
    });

    test('a spent limit is red; early in a window or with no reset, what is spent decides', () {
      final spent = session(100).projectAt(DateTime(2026, 11, 26, 14));
      expect((spent.percent, spent.spent, spent.projected), (100, true, null));
      // Twenty minutes in (under a tenth of the window): 15 % spent is no projection yet.
      final early = session(15).projectAt(DateTime(2026, 11, 26, 10, 20));
      expect((early.percent, early.projected), (15, null));
      expect(session(95).projectAt(DateTime(2026, 11, 26, 10, 20)).percent, 95);
      expect(const UsageWindow(kind: UsageKind.week, used: 50).projectAt(DateTime(2026, 11, 26)).percent, 50);
      // After the reset the window reads as unused.
      expect(session(99).projectAt(DateTime(2026, 11, 26, 16)).percent, 0);
    });

    test('rings show what is left', () {
      final now = DateTime(2026, 11, 26, 12);
      expect(session(30).leftAt(now), 70);
      expect(session(100).leftAt(now), 0);
      expect(session(99).leftAt(DateTime(2026, 11, 26, 16)), 100);
    });

    test("Antigravity's small week with plenty left but 273 % projected is red, its fresh five hours green", () {
      // Friday 18:33: the five hours reset at 22:35 with 3 % spent, the week on Thursday 08:41 with
      // 45 % left (the phone's card that showed both green).
      final now = DateTime(2026, 11, 27, 18, 33);
      final rings = dialRings([
        UsageWindow(kind: UsageKind.week, used: 55, resetsAt: DateTime(2026, 12, 3, 8, 41)),
        UsageWindow(kind: UsageKind.session, used: 3, resetsAt: DateTime(2026, 11, 27, 22, 35)),
      ], now);
      expect([for (final (w, pace) in rings) (w.kind, pace.round())], [(UsageKind.session, 16), (UsageKind.week, 273)]);
      expect([for (final (w, pace) in rings) (w.leftAt(now).round(), paceColor(pace))], [
        (97, paceColor(0)),
        (45, paceColor(100)),
      ]);
    });

    test("a dial's ring shows the worst of its limit and of the ones without a ring", () {
      final now = DateTime(2026, 11, 26, 12, 30);
      final rings = dialRings([
        session(10), // 20 %
        week(10), // 3 days 3.5 hours into the week: about 22 %
        UsageWindow(kind: UsageKind.week, used: 70, resetsAt: resetWeek, scope: 'Fable'), // about 156 %
        const UsageWindow(kind: UsageKind.other, used: 95, minutes: 1440, scope: 'Spark'), // 95 %, no reset
      ], now);
      expect([for (final (w, pace) in rings) (w.kind, w.scope, pace.round())], [
        (UsageKind.session, null, 95),
        (UsageKind.week, null, 156),
      ]);
      // Only a model's limit, no ring of the plan's: no rings.
      expect(dialRings([UsageWindow(kind: UsageKind.week, used: 70, resetsAt: resetWeek, scope: 'Fable')], now), isEmpty);
    });
  });

  test('rings from the outside in: the plan\'s limits, shortest first, then a model\'s', () {
    final w = ringOrder(claudeWindows(_json(_claude)).reversed.toList());
    expect([for (final x in w) (x.kind, x.scope)], [
      (UsageKind.session, null),
      (UsageKind.week, null),
      (UsageKind.week, 'Fable'),
    ]);
    // Only the plan's five hours and week get a ring; a model's week and other lengths are in the card.
    expect([for (final x in w) if (hasRing(x)) (x.kind, x.scope)], [(UsageKind.session, null), (UsageKind.week, null)]);
    expect(hasRing(const UsageWindow(kind: UsageKind.other, used: 0, minutes: 60)), isFalse);
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
      // Colored by the projection, not by what is left: 60 % left is red at 200 %, 70 % left of a
      // week four days in (about 52 %) is green.
      expect(tester.widget<Text>(find.text('60% left')).style?.color, paceColor(100));
      expect(tester.widget<Text>(find.text('70% left')).style?.color, paceColor(0));

      await mouse.moveTo(const Offset(600, 10));
      await tester.pumpAndSettle();
      expect(find.text('5-hour limit'), findsNothing);
      m.dispose();
    });
  });

  test('the desktop sends each provider\'s usage to the phone as it read it', () {
    final readAt = DateTime(2026, 11, 26, 10);
    final windows = [
      UsageWindow(kind: UsageKind.session, used: 40, resetsAt: DateTime(2026, 11, 26, 13)),
      const UsageWindow(kind: UsageKind.week, used: 5, scope: 'Fable'),
      const UsageWindow(kind: UsageKind.other, used: 12, minutes: 60),
    ];
    final sent = SentUsage()
      ..apply(jsonDecode(jsonEncode([
        ProviderUsage(BrainProvider.claude, windows, readAt: readAt).toJson(),
        ProviderUsage(BrainProvider.codex, const [], readAt: readAt).toJson(),
        {'provider': 'someday', 'windows': []},
      ])));
    final u = sent.shown.single;
    expect(u.provider, BrainProvider.claude);
    expect(u.readAt, readAt);
    expect([for (final w in u.windows) (w.kind, w.used, w.resetsAt, w.scope, w.minutes)], [
      for (final w in windows) (w.kind, w.used, w.resetsAt, w.scope, w.minutes),
    ]);
    sent.dispose();
  });

  testWidgets('on the phone a tap opens the card, on screen, and the next tap closes it', (tester) async {
    tester.view.physicalSize = const Size(377, 702);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    final window = UsageWindow(kind: UsageKind.session, used: 40, resetsAt: now.add(const Duration(hours: 4)));
    final sent = SentUsage()
      ..apply([
        for (final p in BrainProvider.values) ProviderUsage(p, [window], readAt: now).toJson(),
      ]);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Align(alignment: Alignment.bottomLeft, child: UsageRings(monitor: sent, dialSize: 34))),
    ));
    expect(find.byType(UsageDial), findsNWidgets(3));

    await tester.tap(find.byType(UsageDial).last);
    await tester.pumpAndSettle();
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('60% left'), findsOneWidget);
    final card = tester.getRect(find.ancestor(of: find.text('Codex'), matching: find.byType(Material)).first);
    expect(card.left, greaterThanOrEqualTo(0));
    expect(card.right, lessThanOrEqualTo(377));

    await tester.tapAt(const Offset(200, 100));
    await tester.pumpAndSettle();
    expect(find.text('60% left'), findsNothing);
    sent.dispose();
  });
}
