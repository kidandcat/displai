import 'package:displai/app/assistant.dart';
import 'package:displai/tools/command_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isReadOnlyCommand', () {
    for (final c in [
      'ls -la ~/Downloads',
      'git status && git log --oneline -5',
      'df -h | grep disk',
      'du -sh * 2>/dev/null | sort -h',
      'curl -s https://example.com',
      'open -a Safari',
      'find . -name "*.dart"',
      'defaults read com.apple.dock',
    ]) {
      test('read-only: $c', () => expect(CommandTools.isReadOnlyCommand(c), isTrue));
    }
    for (final c in [
      'rm -rf ~/tmp',
      'echo hi > file.txt',
      'git push',
      'git branch -D old',
      'sed -i "" s/a/b/ f',
      'find . -name x -delete',
      'curl -X POST https://x.y',
      'sudo ls',
      'ls; rm x',
      'osascript -e "beep"',
      r'echo $(rm x)',
      'brew install wget',
      'mv a b',
    ]) {
      test('changes: $c', () => expect(CommandTools.isReadOnlyCommand(c), isFalse));
    }
  });

  group('parseYesNo', () {
    test('yes', () {
      for (final t in ['Sí.', 'sí, hazlo', 'Vale', 'adelante', 'Sí, claro.', 'OK']) {
        expect(Assistant.parseYesNo(t), isTrue, reason: t);
      }
    });
    test('no', () {
      for (final t in ['No.', 'no, espera', 'Cancela', 'sí no']) {
        expect(Assistant.parseYesNo(t), isFalse, reason: t);
      }
    });
    test('other', () {
      for (final t in ['¿Qué hora es?', 'Mejor envíaselo a Pedro', 'silencio']) {
        expect(Assistant.parseYesNo(t), isNull, reason: t);
      }
    });
  });
}
