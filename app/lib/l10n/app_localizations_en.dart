// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get modelsDownloadFailed => 'Could not download the voice models.';

  @override
  String get modelsPreparing => 'Preparing…';

  @override
  String get modelsFirstRunNote =>
      'Only the first time. Everything is processed on this Mac.';

  @override
  String modelDownloading(String model) {
    return 'Downloading $model…';
  }

  @override
  String modelInstalling(String model) {
    return 'Installing $model…';
  }

  @override
  String get modelVad => 'Voice detector';

  @override
  String get modelStt => 'Speech recognition (Parakeet v3)';

  @override
  String get modelVoice => 'Voice (Supertonic 3)';

  @override
  String startFailed(String error) {
    return 'Could not start: $error';
  }

  @override
  String get loadingVoice => 'Loading the voice…';

  @override
  String backgroundJobs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count background jobs',
      one: '1 background job',
    );
    return '$_temp0';
  }

  @override
  String get micMuted => 'Microphone muted · space to unmute';

  @override
  String get linkNoteOnPhone => 'Phone connected · the Mac is silent';

  @override
  String get phoneConnected => 'Phone connected';

  @override
  String get phoneConnect => 'Connect the phone';

  @override
  String get pairingConnected =>
      'Phone connected. While it is, the Mac neither listens nor speaks.';

  @override
  String get pairingWaiting => 'Waiting for the phone…';

  @override
  String get connectingToRelay => 'Connecting to the relay…';

  @override
  String get pairingInstructions =>
      'Scan it with the Minerva app on the phone. The phone will be the microphone, the speaker and the screen; everything is still processed on this Mac.';

  @override
  String get pairingNewCode => 'New code';

  @override
  String get close => 'Close';

  @override
  String get copy => 'Copy';

  @override
  String get webhooks => 'Webhooks';

  @override
  String get webhooksActive => 'Webhooks active';

  @override
  String get webhooksExplanation =>
      'Other services can notify Minerva by calling this address (with any path after it). The encryption ends on this Mac: the relay does not see what arrives. Keep it private: whoever has it can write to Minerva.';

  @override
  String get addressCopied => 'Address copied';

  @override
  String get webhooksHelperMissing =>
      'The minerva-webhooks helper is missing from the app.';

  @override
  String webhooksHelperCrashes(int code) {
    return 'The webhooks helper quits at startup (code $code).';
  }

  @override
  String webhooksHelperFailed(String error) {
    return 'Could not start minerva-webhooks: $error';
  }

  @override
  String get webhooksStarting => 'Starting…';

  @override
  String get webhooksRequestingCert => 'Requesting the certificate…';

  @override
  String webhooksNoCert(String error) {
    return 'No certificate yet: $error';
  }

  @override
  String get webhooksOn => 'Active';

  @override
  String get activityThinking => 'Thinking…';

  @override
  String get activityCompacting => 'Summarizing the conversation…';

  @override
  String get activityWebSearch => 'Searching the web…';

  @override
  String get activityWebFetch => 'Reading a page…';

  @override
  String get activityLookingAtScreen => 'Looking at the screen…';

  @override
  String get activityPreparingDisplay => 'Preparing the display…';

  @override
  String get activityRemembering => 'Remembering…';

  @override
  String get activitySearchingHistory => 'Searching the history…';

  @override
  String get activityReadingSkill => 'Going over how it\'s done…';

  @override
  String get activityStartingWorker => 'Starting a background job…';

  @override
  String get activityCheckingWorkers => 'Checking the running jobs…';

  @override
  String get activityScheduling => 'Scheduling…';

  @override
  String get activityRunningCommand => 'Running a command…';

  @override
  String get activityReadingFiles => 'Reading files…';

  @override
  String get activityWritingFile => 'Writing a file…';

  @override
  String get activityReadingUi => 'Reading the interface…';

  @override
  String get activityUsingComputer => 'Using the computer…';

  @override
  String get brainError =>
      'Something went wrong with the brain. Please try again.';

  @override
  String get reminderLead => 'Just a reminder';

  @override
  String get unpair => 'Unpair from the computer';

  @override
  String get notMinervaCode => 'That code is not from Minerva.';

  @override
  String get pairScreenInstructions =>
      'On the computer, press the phone button in the bottom bar and scan the code.';

  @override
  String get pairScreenNote =>
      'The phone will be the microphone, the speaker and the screen; everything is processed on the computer.';

  @override
  String get scanCode => 'Scan the code';

  @override
  String get remoteReplaced => 'Another phone is connected to this computer';

  @override
  String get remoteConnecting => 'Connecting…';

  @override
  String get remoteWaitingHost =>
      'Waiting for the computer… (open Minerva on it)';

  @override
  String micFailed(String error) {
    return 'Could not use the microphone: $error';
  }

  @override
  String get displaySubmit => 'Send';

  @override
  String get displaySubmitted => 'Sent';

  @override
  String get displayRequired => 'Required';

  @override
  String get displayPickDate => 'Pick a date';

  @override
  String get displayVideoError => 'Can\'t play the video';

  @override
  String get displayYes => 'Yes';

  @override
  String get displayNo => 'No';

  @override
  String vaultFormTitle(String name) {
    return 'Credential: $name';
  }

  @override
  String get vaultFormNote =>
      'Saved in Minerva\'s encrypted vault on this Mac. The assistant never sees what you type here.';

  @override
  String get vaultSave => 'Save';

  @override
  String get vaultSaved => 'Saved';

  @override
  String get cancel => 'Cancel';

  @override
  String get vaultShowSecret => 'Show';

  @override
  String get vaultHideSecret => 'Hide';

  @override
  String get vaultCredentials => 'Credentials';

  @override
  String get vaultDialogIntro =>
      'Logins and tokens the assistant can use without seeing them. To add one, ask the assistant; it shows a form for it.';

  @override
  String get vaultEmpty => 'No credentials saved yet.';

  @override
  String get delete => 'Delete';

  @override
  String vaultDeleteConfirm(String name) {
    return 'Delete the credential \"$name\"?';
  }

  @override
  String vaultFields(String names) {
    return 'Fields: $names';
  }

  @override
  String vaultUnavailable(String error) {
    return 'The vault is not available: $error';
  }
}
