import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/brain/brain_session.dart';
import 'package:minerva/brain/fallback.dart';
import 'package:minerva/brain/models.dart';
import 'package:minerva/store/store.dart';

const _claude = ModelChoice(provider: BrainProvider.claude, model: 'opus', effort: 'low');
const _agy = ModelChoice(provider: BrainProvider.antigravity, model: 'gemini-4-neon', effort: 'low');
const _codex = ModelChoice(provider: BrainProvider.codex, model: 'gpt-6-astra', effort: 'low');

void main() {
  final now = DateTime(2026, 11, 25, 10, 30);

  test("each agent's limit errors are limits; other errors are not", () {
    for (final e in [
      "You've hit your limit · resets 3pm (Europe/Madrid)",
      'Claude AI usage limit reached|1764090000',
      'RESOURCE_EXHAUSTED: quota exceeded for model',
      "You've hit your usage limit. Upgrade to Pro or try again at 3:45 PM.",
      'stream error: 429 Too Many Requests',
      'rate_limit_error: Number of request tokens has exceeded your per-minute rate limit',
    ]) {
      expect(limitIn(e, now: now)?.reason, LimitReason.usage, reason: e);
    }
    for (final e in [
      'Your access token could not be refreshed. Please log out and sign in again.',
      'Invalid API key · Please run /login',
      'Codex is not signed in: run codex login in a terminal and sign in with ChatGPT.',
      'antigravity start failed: 401 Unauthorized',
    ]) {
      expect(limitIn(e, now: now)?.reason, LimitReason.signIn, reason: e);
    }
    for (final e in [null, '', 'claude exited (1): boom', 'Prompt is too long', 'context window exceeded']) {
      expect(limitIn(e, now: now), isNull, reason: e);
    }
  });

  test('the reset time is read from the error when it says', () {
    expect(resetIn('Claude AI usage limit reached|1764090000', now: now),
        DateTime.fromMillisecondsSinceEpoch(1764090000 * 1000));
    expect(resetIn("You've hit your limit · resets 3pm (Europe/Madrid)", now: now), DateTime(2026, 11, 25, 15));
    expect(resetIn('try again at 3:45 PM', now: now), DateTime(2026, 11, 25, 15, 45));
    // A time already past today is tomorrow's.
    expect(resetIn('resets 9am', now: now), DateTime(2026, 11, 26, 9));
    expect(resetIn('try again until 10:15', now: now), DateTime(2026, 11, 26, 10, 15));
    expect(resetIn('Please try again in 2 hours 30 minutes', now: now), now.add(const Duration(hours: 2, minutes: 30)));
    expect(resetIn('try again in 45m', now: now), now.add(const Duration(minutes: 45)));
    expect(resetIn('quota exceeded', now: now), isNull);
    expect(resetIn('retry in 3 seconds or so, resets eventually', now: now), isNull);
  });

  test('the chain runs on the first provider not out, and goes back once it is', () {
    final limits = ProviderLimits();
    final chain = fallbackChain(_claude, [_codex, _agy]);
    expect(limits.pick(chain, now: now), _claude);

    limits.hit(BrainProvider.claude, ProviderLimit(LimitReason.usage, resetsAt: now.add(const Duration(hours: 1))),
        now: now);
    expect(limits.until(BrainProvider.claude, now: now), now.add(const Duration(hours: 1)));
    expect(limits.next(chain, BrainProvider.claude, now: now), _codex);
    expect(limits.pick(chain, now: now), _codex);
    // Codex not installed: Antigravity.
    expect(limits.pick(chain, unavailable: {BrainProvider.codex}, now: now), _agy);
    expect(limits.next(chain, BrainProvider.claude, unavailable: {BrainProvider.codex}, now: now), _agy);

    // The limit is over: back to Claude.
    expect(limits.pick(chain, now: now.add(const Duration(hours: 1, minutes: 1))), _claude);

    // Not saying when: a while. Signed out: a shorter while.
    limits.hit(BrainProvider.codex, const ProviderLimit(LimitReason.usage), now: now);
    expect(limits.until(BrainProvider.codex, now: now), now.add(ProviderLimits.usageRetry));
    limits.hit(BrainProvider.antigravity, const ProviderLimit(LimitReason.signIn), now: now);
    expect(limits.until(BrainProvider.antigravity, now: now), now.add(ProviderLimits.signInRetry));
    expect(limits.reason(BrainProvider.antigravity, now: now), LimitReason.signIn);

    // All out: none to go on with, and it runs on the one back soonest.
    expect(limits.next(chain, BrainProvider.claude, now: now), isNull);
    expect(limits.pick(chain, now: now), _agy);

    limits.clear(BrainProvider.claude);
    expect(limits.pick(chain, now: now), _claude);
    expect(limits.all(now: now).keys, {BrainProvider.codex, BrainProvider.antigravity});
  });

  test('a reset in the past or too far away is taken as a while', () {
    final limits = ProviderLimits();
    limits.hit(BrainProvider.claude, ProviderLimit(LimitReason.usage, resetsAt: now.subtract(const Duration(hours: 1))),
        now: now);
    expect(limits.until(BrainProvider.claude, now: now), now.add(ProviderLimits.usageRetry));
    limits.hit(BrainProvider.claude, ProviderLimit(LimitReason.usage, resetsAt: now.add(const Duration(days: 40))),
        now: now);
    expect(limits.until(BrainProvider.claude, now: now), now.add(ProviderLimits.usageRetry));
  });

  test('a provider appears once in a chain', () {
    expect(fallbackChain(_claude, [_claude.copyWith(model: 'sonnet'), _codex, _codex.copyWith(model: 'gpt-5.5')]),
        [_claude, _codex]);
  });

  test('limits and fallbacks survive a restart', () {
    final dir = Directory.systemTemp.createTempSync('minerva_fallback');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.memory(dir.path);
    addTearDown(store.close);

    var changes = 0;
    final until = DateTime.now().add(const Duration(hours: 2));
    ProviderLimits(store: store, onChange: () => changes++)
        .hit(BrainProvider.codex, ProviderLimit(LimitReason.usage, resetsAt: until));
    expect(changes, 1);
    final back = ProviderLimits(store: store);
    expect(back.until(BrainProvider.codex)!.millisecondsSinceEpoch, until.millisecondsSinceEpoch);
    back.clear(BrainProvider.codex);
    expect(ProviderLimits(store: store).until(BrainProvider.codex), isNull);

    expect(loadFallbacks(store, 'brain'), isEmpty);
    saveFallbacks(store, 'brain', [_codex, _agy]);
    expect(loadFallbacks(store, 'brain'), [_codex, _agy]);
    expect(loadFallbacks(store, 'workers'), isEmpty);
    saveFallbacks(store, 'brain', const []);
    expect(loadFallbacks(store, 'brain'), isEmpty);
    expect(fallbacksFromJson([_codex.toJson(), 'bad', 3]), [_codex]);
    expect(fallbacksFromJson(null), isNull);
  });

  test('a turn that failed on a limit says so; an interrupted one does not', () {
    expect(TurnDone(interrupted: false, error: "You've hit your limit · resets 3pm").limit?.reason, LimitReason.usage);
    expect(TurnDone(interrupted: true, error: "You've hit your limit").limit, isNull);
    expect(TurnDone(interrupted: false, error: 'boom').limit, isNull);
    expect(TurnDone(interrupted: false).limit, isNull);
    const given = ProviderLimit(LimitReason.signIn);
    expect(TurnDone(interrupted: false, error: 'x', limit: given).limit, given);
  });
}
