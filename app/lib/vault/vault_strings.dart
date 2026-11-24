/// User-facing strings of the vault (the credential form and the management dialog), kept in
/// one place so they can move into the localization files.
abstract final class VaultStrings {
  // Credential form on the display.
  static String formTitle(String name) => 'Credential: $name';
  static const formNote = 'Saved in Minerva\'s encrypted vault on this Mac. The assistant never sees '
      'what you type here.';
  static const save = 'Save';
  static const saved = 'Saved';
  static const cancel = 'Cancel';
  static const show = 'Show';
  static const hide = 'Hide';

  // Management dialog.
  static const button = 'Credentials';
  static const dialogTitle = 'Credentials';
  static const dialogIntro = 'Logins and tokens the assistant can use without seeing them. To add one, '
      'ask the assistant; it shows a form for it.';
  static const empty = 'No credentials saved yet.';
  static const delete = 'Delete';
  static String deleteConfirm(String name) => 'Delete the credential "$name"?';
  static String fields(List<String> names) => 'Fields: ${names.join(', ')}';
  static const close = 'Close';
  static String unavailable(String why) => 'The vault is not available: $why';
}
