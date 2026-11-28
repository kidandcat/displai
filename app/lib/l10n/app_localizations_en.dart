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
      other: '$count workers working',
      one: '1 worker working',
    );
    return '$_temp0';
  }

  @override
  String get micMuted => 'Microphone muted · space to unmute';

  @override
  String micMutedKey(String key) {
    return 'Microphone muted · $key to unmute';
  }

  @override
  String get muteKey => 'Mute key';

  @override
  String muteKeyCurrent(String key) {
    return 'Mutes and unmutes the mic: $key';
  }

  @override
  String get muteKeyHint =>
      'A key on its own works while Minerva is on screen and you are not typing. Caps Lock and combos with ⌘ or ⌃ work in any app, also while Minerva is closed.';

  @override
  String get muteKeyRecording => 'Press the new key or combo… (Esc cancels)';

  @override
  String get muteKeyChange => 'Change';

  @override
  String get muteKeyCapsLock => 'Use Caps Lock';

  @override
  String get muteKeyReset => 'Reset to Space';

  @override
  String get muteKeyNoAccess =>
      'To use it in other apps, Minerva needs Accessibility (and maybe Input Monitoring) in System Settings → Privacy & Security.';

  @override
  String get muteKeyGrant => 'Open settings';

  @override
  String get keySpace => 'Space';

  @override
  String get keyCapsLock => 'Caps Lock';

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
      'Other services can notify Minerva by calling a webhook\'s address (with any path after it). Each webhook has its own secret address; ask Minerva to create one for each service. The encryption ends on this Mac: the relay does not see what arrives. Keep the addresses private: whoever has one can write to Minerva.';

  @override
  String get webhooksNone => 'No webhooks yet. Ask Minerva to create one.';

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
  String get activityWebhooks => 'Setting up webhooks…';

  @override
  String get activitySendingFile => 'Sending it on Telegram…';

  @override
  String get activityTakingPhoto => 'Taking a photo…';

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

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'System language';

  @override
  String get modelTitle => 'Model';

  @override
  String get modelConversation => 'Conversation';

  @override
  String get modelWorkers => 'Workers';

  @override
  String get modelSearch => 'Search models';

  @override
  String get modelDefault => 'default';

  @override
  String modelPrevious(int count) {
    return 'Previous models ($count)';
  }

  @override
  String get modelNoMatch => 'No model matches';

  @override
  String modelLoading(String agent) {
    return 'Loading $agent\'s models…';
  }

  @override
  String modelUnavailable(String agent) {
    return '$agent is not installed or not signed in. Install it and sign in from a terminal (for Antigravity: run agy; for Codex: run codex login).';
  }

  @override
  String get modelProviderNote => 'Each provider keeps its own conversation.';

  @override
  String get modelEffort => 'Effort';

  @override
  String get effortLow => 'Low';

  @override
  String get effortMedium => 'Medium';

  @override
  String get effortHigh => 'High';

  @override
  String get effortXhigh => 'Very high';

  @override
  String get effortMax => 'Max';

  @override
  String get effortUltra => 'Ultra';

  @override
  String get modelSpeed => 'Speed';

  @override
  String get speedStandard => 'Standard';

  @override
  String get speedFast => 'Fast';

  @override
  String fastUnavailable(String reason) {
    return 'Fast mode is not available: $reason';
  }

  @override
  String get fastExtraUsageDisabled =>
      'extra usage is turned off on your Claude account';

  @override
  String get modelConversationNote =>
      'The conversation goes on with the new model.';

  @override
  String get modelWorkersNote => 'Applies to workers started from now on.';

  @override
  String get modelProviders => 'Providers';

  @override
  String get providerReady => 'Ready';

  @override
  String get providerChecking => 'Checking…';

  @override
  String get providerUnavailable => 'Not installed or not signed in';

  @override
  String providerLimited(String time) {
    return 'Usage limit until $time';
  }

  @override
  String providerSignedOut(String time) {
    return 'Signed out: sign in again from a terminal (retrying at $time)';
  }

  @override
  String providerUsedBy(String uses) {
    return 'In use: $uses';
  }

  @override
  String get providersNote =>
      'Minerva runs on the subscriptions of the agents installed on this Mac: Claude Code (claude), Antigravity (agy) and Codex (codex login). Connect several and add backups: when one hits its usage limit, Minerva goes on with the next.';

  @override
  String get fallbacks => 'Backups, in order';

  @override
  String get fallbacksNote =>
      'When a provider hits its usage limit, Minerva goes on with the next backup, and back to the first choice once the limit is over.';

  @override
  String get fallbacksNone =>
      'No backups: if the provider is out, Minerva says so and waits.';

  @override
  String get fallbackAdd => 'Add backup';

  @override
  String get fallbackRemove => 'Remove';

  @override
  String get fallbackUp => 'Move up';

  @override
  String get fallbackDown => 'Move down';

  @override
  String modelOnBackup(String provider, String model) {
    return '$provider is out: the conversation is on $model until it is back.';
  }

  @override
  String providerFellBack(String from, String to) {
    return '$from can\'t answer right now. I\'ll go on with $to.';
  }

  @override
  String get settings => 'Settings';

  @override
  String get settingsOffline =>
      'Connect to the computer to change its settings.';

  @override
  String get settingsAppliedOnComputer =>
      'These are the computer\'s settings: changes apply to Minerva there.';

  @override
  String get voice => 'Voice';

  @override
  String voiceFemale(int n) {
    return 'Female $n';
  }

  @override
  String voiceMale(int n) {
    return 'Male $n';
  }

  @override
  String get phoneOverlay => 'Orb over other apps';

  @override
  String get phoneOverlayOn =>
      'On: Minerva\'s orb floats over other apps while it is linked';

  @override
  String get phoneOverlayOff =>
      'Off: allow display over other apps to see Minerva\'s orb outside the app';

  @override
  String get telegramUnsupported =>
      'I can\'t take video, stickers or locations here yet. Write it to me, please.';

  @override
  String get telegramDownloadFailed =>
      'I couldn\'t download that from Telegram. Try sending it again.';

  @override
  String get telegramTranscribeFailed =>
      'I couldn\'t transcribe that audio. Try again, or write it to me.';

  @override
  String get telegramNoSpeech =>
      'I couldn\'t make out any speech in that audio.';

  @override
  String get telegramBadToken =>
      'Telegram rejected the bot token: save a valid one as the credential telegram (field token).';

  @override
  String get telegramConflict =>
      'This Telegram bot has a webhook set or another program reads it: Minerva needs a bot of its own.';

  @override
  String get usageSessionLimit => '5-hour limit';

  @override
  String get usageWeekLimit => 'Weekly limit';

  @override
  String usageOtherLimit(int hours) {
    return '$hours-hour limit';
  }

  @override
  String usageLeft(int percent) {
    return '$percent% left';
  }

  @override
  String usageResets(String when) {
    return 'resets $when';
  }

  @override
  String usageProjection(int percent) {
    return 'projected $percent% by the reset';
  }

  @override
  String usageRunsOutAt(String time) {
    return 'runs out around $time';
  }

  @override
  String usageRunsOutOn(String when) {
    return 'runs out around $when';
  }

  @override
  String get usageSpent => 'limit reached';

  @override
  String get workerRunning => 'Working';

  @override
  String get workerDone => 'Done';

  @override
  String get workerFailed => 'Failed';

  @override
  String get workerStopped => 'Stopped';

  @override
  String get workerInterrupted => 'Interrupted';

  @override
  String get workerStarting => 'Getting started…';

  @override
  String workersMore(int count) {
    return '+$count more';
  }

  @override
  String projectEdited(String when) {
    return 'Edited $when';
  }

  @override
  String get timeJustNow => 'just now';

  @override
  String timeMinutesAgo(int count) {
    return '$count min ago';
  }

  @override
  String timeHoursAgo(int count) {
    return '$count h ago';
  }

  @override
  String timeDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days ago',
      one: 'yesterday',
    );
    return '$_temp0';
  }

  @override
  String get modelSpeaker => 'Voice identification (CAM++)';

  @override
  String get wakeMode => 'Wake word';

  @override
  String get wakeModeOff => 'Off';

  @override
  String get wakeModeOn => 'Always';

  @override
  String get wakeModeAuto => 'By voice';

  @override
  String get wakeActive => 'Wake word on: say \"Minerva…\"';

  @override
  String get wakeTimeout => 'Back off after';

  @override
  String wakeTimeoutMinutes(int minutes) {
    return 'Back off after $minutes min';
  }

  @override
  String minutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get voiceIdLoading => 'Loading voice identification…';

  @override
  String voiceIdEnrolling(int done, int total) {
    return 'Learning your voice ($done/$total)';
  }

  @override
  String get voiceIdReady => 'Your voice is learned';

  @override
  String get voiceIdFailed => 'Voice identification unavailable';

  @override
  String get voiceIdReset => 'Learn my voice again';
}
