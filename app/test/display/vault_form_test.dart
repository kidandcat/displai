import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/display/display.dart';
import 'package:minerva/vault/vault_tools.dart';

const _secret = 'S3cr3t-Test-123';

Future<DisplayController> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = DisplayController();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(backgroundColor: Colors.black, body: DisplayView(controller: controller)),
    ),
  );
  return controller;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _done(WidgetTester tester, DisplayController c) async {
  await tester.pumpWidget(const SizedBox());
  c.dispose();
}

Map<String, dynamic> _githubForm() =>
    VaultTools.requestForm({
          'name': 'github',
          'description': 'GitHub login',
          'fields': [
            {'name': 'username', 'label': 'User', 'secret': false},
            {'name': 'password', 'label': 'Password'},
          ],
        })
        as Map<String, dynamic>;

void main() {
  testWidgets('a vault form hands its values to the vault, never to the brain', (tester) async {
    final c = await _pump(tester);
    final events = <String>[];
    final submissions = <VaultSubmission>[];
    c.userEvents.listen(events.add);
    c.vaultSubmissions.listen(submissions.add);

    expect(c.callTool('form', _githubForm()), startsWith('ok:'));
    await _settle(tester);
    expect(find.text('Credential: github'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('field-username')), 'jdoe');
    await tester.enterText(find.byKey(const ValueKey('field-password')), _secret);
    await tester.pump();

    // Obscured on screen, with a reveal toggle.
    final field = tester.widget<TextField>(
      find.descendant(of: find.byKey(const ValueKey('field-password')), matching: find.byType(TextField)),
    );
    expect(field.obscureText, isTrue);
    await tester.tap(find.byKey(const ValueKey('reveal-password')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.descendant(of: find.byKey(const ValueKey('field-password')), matching: find.byType(TextField)),
          )
          .obscureText,
      isFalse,
    );

    // The readback hides every field of a credential form.
    var state = c.getState();
    expect(state, contains('credential github for the vault'));
    expect(state, contains('password (secret, required) = •••'));
    expect(state.contains(_secret), isFalse);
    expect(state.contains('jdoe'), isFalse);

    // The brain cannot change the form or fill it.
    expect(
      c.callTool('update', {
        'id': 'vault-github',
        'set': {'vault': ''},
      }),
      startsWith('error:'),
    );

    await tester.ensureVisible(find.byKey(const ValueKey('form-submit')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('form-submit')));
    await _settle(tester);

    expect(events, isEmpty);
    expect(submissions, hasLength(1));
    final s = submissions.single;
    expect(s.name, 'github');
    expect(s.description, 'GitHub login');
    expect(s.fields, [('username', 'jdoe', false), ('password', _secret, true)]);
    // It travels to the desktop as JSON over the remote link.
    final back = VaultSubmission.fromJson(s.toJson())!;
    expect(back.fields, s.fields);

    // Wiped from the display after the submission.
    state = c.getState();
    expect(state, contains('submitted'));
    expect(state.contains(_secret), isFalse);
    expect(state, contains('the values went to the vault'));
    expect(find.text(_secret), findsNothing);
    expect(find.textContaining('Saved ✓'), findsOneWidget);
    expect(find.byKey(const ValueKey('form-cancel')), findsNothing);

    await _done(tester, c);
  });

  testWidgets('cancelling a vault form tells the brain, without values', (tester) async {
    final c = await _pump(tester);
    final events = <String>[];
    c.userEvents.listen(events.add);
    c.callTool('form', _githubForm());
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('field-password')), _secret);
    await tester.ensureVisible(find.byKey(const ValueKey('form-cancel')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('form-cancel')));
    await _settle(tester);
    expect(events, ['[display] credential request github cancelled']);
    await _done(tester, c);
  });

  testWidgets('a plain form leaves secret fields out of its submission', (tester) async {
    final c = await _pump(tester);
    final events = <String>[];
    final submissions = <VaultSubmission>[];
    c.userEvents.listen(events.add);
    c.vaultSubmissions.listen(submissions.add);
    c.callTool('form', {
      'title': 'Login',
      'id': 'login',
      'fields': [
        {'name': 'user', 'type': 'text'},
        {'name': 'pin', 'type': 'secret'},
      ],
    });
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('field-user')), 'ana');
    await tester.enterText(find.byKey(const ValueKey('field-pin')), _secret);
    await tester.pump();
    expect(c.getState().contains(_secret), isFalse);
    await tester.ensureVisible(find.byKey(const ValueKey('form-submit')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('form-submit')));
    await _settle(tester);
    expect(events, hasLength(1));
    expect(events.single, contains('"user":"ana"'));
    expect(events.single.contains(_secret), isFalse);
    expect(submissions, isEmpty);
    await _done(tester, c);
  });
}
