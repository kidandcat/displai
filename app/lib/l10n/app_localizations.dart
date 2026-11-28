import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
  ];

  /// First run: the voice models failed to download.
  ///
  /// In en, this message translates to:
  /// **'Could not download the voice models.'**
  String get modelsDownloadFailed;

  /// First run: before the first download starts.
  ///
  /// In en, this message translates to:
  /// **'Preparing…'**
  String get modelsPreparing;

  /// First run: under the download progress.
  ///
  /// In en, this message translates to:
  /// **'Only the first time. Everything is processed on this Mac.'**
  String get modelsFirstRunNote;

  /// First run: a voice model is downloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading {model}…'**
  String modelDownloading(String model);

  /// First run: a downloaded voice model is unpacking.
  ///
  /// In en, this message translates to:
  /// **'Installing {model}…'**
  String modelInstalling(String model);

  /// Name of the voice activity detection model.
  ///
  /// In en, this message translates to:
  /// **'Voice detector'**
  String get modelVad;

  /// Name of the speech recognition model.
  ///
  /// In en, this message translates to:
  /// **'Speech recognition (Parakeet v3)'**
  String get modelStt;

  /// Name of the text-to-speech model.
  ///
  /// In en, this message translates to:
  /// **'Voice (Supertonic 3)'**
  String get modelVoice;

  /// The assistant failed to start.
  ///
  /// In en, this message translates to:
  /// **'Could not start: {error}'**
  String startFailed(String error);

  /// Status bar while the assistant starts.
  ///
  /// In en, this message translates to:
  /// **'Loading the voice…'**
  String get loadingVoice;

  /// Status bar: workers running in the background.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 worker working} other{{count} workers working}}'**
  String backgroundJobs(int count);

  /// Status bar while the mic is muted.
  ///
  /// In en, this message translates to:
  /// **'Microphone muted · space to unmute'**
  String get micMuted;

  /// Status bar while the mic is muted, with the mute key.
  ///
  /// In en, this message translates to:
  /// **'Microphone muted · {key} to unmute'**
  String micMutedKey(String key);

  /// Setting: the key that mutes and unmutes the mic, and the tooltip of its button.
  ///
  /// In en, this message translates to:
  /// **'Mute key'**
  String get muteKey;

  /// Mute key dialog: the current key.
  ///
  /// In en, this message translates to:
  /// **'Mutes and unmutes the mic: {key}'**
  String muteKeyCurrent(String key);

  /// Mute key dialog: where each kind of key works.
  ///
  /// In en, this message translates to:
  /// **'A key on its own works while Minerva is on screen and you are not typing. Caps Lock and combos with ⌘ or ⌃ work in any app, also while Minerva is closed.'**
  String get muteKeyHint;

  /// Mute key dialog: waiting for the key.
  ///
  /// In en, this message translates to:
  /// **'Press the new key or combo… (Esc cancels)'**
  String get muteKeyRecording;

  /// Mute key dialog: record a new key.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get muteKeyChange;

  /// Mute key dialog: make Caps Lock the mute key.
  ///
  /// In en, this message translates to:
  /// **'Use Caps Lock'**
  String get muteKeyCapsLock;

  /// Mute key dialog: back to the default key.
  ///
  /// In en, this message translates to:
  /// **'Reset to Space'**
  String get muteKeyReset;

  /// Mute key dialog: the permission is missing.
  ///
  /// In en, this message translates to:
  /// **'To use it in other apps, Minerva needs Accessibility (and maybe Input Monitoring) in System Settings → Privacy & Security.'**
  String get muteKeyNoAccess;

  /// Mute key dialog: ask for the permission.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get muteKeyGrant;

  /// Name of the space bar.
  ///
  /// In en, this message translates to:
  /// **'Space'**
  String get keySpace;

  /// Name of the Caps Lock key.
  ///
  /// In en, this message translates to:
  /// **'Caps Lock'**
  String get keyCapsLock;

  /// Status bar on the Mac while the phone remote is connected.
  ///
  /// In en, this message translates to:
  /// **'Phone connected · the Mac is silent'**
  String get linkNoteOnPhone;

  /// Tooltip of the phone button while a phone is connected.
  ///
  /// In en, this message translates to:
  /// **'Phone connected'**
  String get phoneConnected;

  /// Tooltip of the phone button and title of the pairing dialog.
  ///
  /// In en, this message translates to:
  /// **'Connect the phone'**
  String get phoneConnect;

  /// Pairing dialog status.
  ///
  /// In en, this message translates to:
  /// **'Phone connected. While it is, the Mac neither listens nor speaks.'**
  String get pairingConnected;

  /// Pairing dialog status.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the phone…'**
  String get pairingWaiting;

  /// Pairing and webhooks status: reaching the relay server.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the relay…'**
  String get connectingToRelay;

  /// Pairing dialog, under the QR code.
  ///
  /// In en, this message translates to:
  /// **'Scan it with the Minerva app on the phone. The phone will be the microphone, the speaker and the screen; everything is still processed on this Mac.'**
  String get pairingInstructions;

  /// Pairing dialog button: forget the old pairing and make a new QR code.
  ///
  /// In en, this message translates to:
  /// **'New code'**
  String get pairingNewCode;

  /// Dialog button.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// Dialog button.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// Webhooks button tooltip and dialog title.
  ///
  /// In en, this message translates to:
  /// **'Webhooks'**
  String get webhooks;

  /// Webhooks button tooltip while they can be received.
  ///
  /// In en, this message translates to:
  /// **'Webhooks active'**
  String get webhooksActive;

  /// Webhooks dialog.
  ///
  /// In en, this message translates to:
  /// **'Other services can notify Minerva by calling a webhook\'s address (with any path after it). Each webhook has its own secret address; ask Minerva to create one for each service. The encryption ends on this Mac: the relay does not see what arrives. Keep the addresses private: whoever has one can write to Minerva.'**
  String get webhooksExplanation;

  /// Webhooks dialog, when none is registered.
  ///
  /// In en, this message translates to:
  /// **'No webhooks yet. Ask Minerva to create one.'**
  String get webhooksNone;

  /// Snack bar after copying the webhook address.
  ///
  /// In en, this message translates to:
  /// **'Address copied'**
  String get addressCopied;

  /// Webhooks status.
  ///
  /// In en, this message translates to:
  /// **'The minerva-webhooks helper is missing from the app.'**
  String get webhooksHelperMissing;

  /// Webhooks status.
  ///
  /// In en, this message translates to:
  /// **'The webhooks helper quits at startup (code {code}).'**
  String webhooksHelperCrashes(int code);

  /// Webhooks status.
  ///
  /// In en, this message translates to:
  /// **'Could not start minerva-webhooks: {error}'**
  String webhooksHelperFailed(String error);

  /// Webhooks status.
  ///
  /// In en, this message translates to:
  /// **'Starting…'**
  String get webhooksStarting;

  /// Webhooks status.
  ///
  /// In en, this message translates to:
  /// **'Requesting the certificate…'**
  String get webhooksRequestingCert;

  /// Webhooks status.
  ///
  /// In en, this message translates to:
  /// **'No certificate yet: {error}'**
  String webhooksNoCert(String error);

  /// Webhooks status.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get webhooksOn;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Thinking…'**
  String get activityThinking;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Summarizing the conversation…'**
  String get activityCompacting;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Searching the web…'**
  String get activityWebSearch;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Reading a page…'**
  String get activityWebFetch;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Looking at the screen…'**
  String get activityLookingAtScreen;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Preparing the display…'**
  String get activityPreparingDisplay;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Remembering…'**
  String get activityRemembering;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Searching the history…'**
  String get activitySearchingHistory;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Going over how it\'s done…'**
  String get activityReadingSkill;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Starting a background job…'**
  String get activityStartingWorker;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Checking the running jobs…'**
  String get activityCheckingWorkers;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Scheduling…'**
  String get activityScheduling;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Setting up webhooks…'**
  String get activityWebhooks;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Sending it on Telegram…'**
  String get activitySendingFile;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Taking a photo…'**
  String get activityTakingPhoto;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Running a command…'**
  String get activityRunningCommand;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Reading files…'**
  String get activityReadingFiles;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Writing a file…'**
  String get activityWritingFile;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Reading the interface…'**
  String get activityReadingUi;

  /// What the assistant is doing (spoken aloud).
  ///
  /// In en, this message translates to:
  /// **'Using the computer…'**
  String get activityUsingComputer;

  /// Spoken when the brain's turn fails.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong with the brain. Please try again.'**
  String get brainError;

  /// How the assistant starts a reminder said aloud (the brain is told to use it).
  ///
  /// In en, this message translates to:
  /// **'Just a reminder'**
  String get reminderLead;

  /// Phone menu item.
  ///
  /// In en, this message translates to:
  /// **'Unpair from the computer'**
  String get unpair;

  /// Phone pairing screen: the scanned QR is not a pairing code.
  ///
  /// In en, this message translates to:
  /// **'That code is not from Minerva.'**
  String get notMinervaCode;

  /// Phone pairing screen.
  ///
  /// In en, this message translates to:
  /// **'On the computer, press the phone button in the bottom bar and scan the code.'**
  String get pairScreenInstructions;

  /// Phone pairing screen.
  ///
  /// In en, this message translates to:
  /// **'The phone will be the microphone, the speaker and the screen; everything is processed on the computer.'**
  String get pairScreenNote;

  /// Phone pairing screen button.
  ///
  /// In en, this message translates to:
  /// **'Scan the code'**
  String get scanCode;

  /// Phone status.
  ///
  /// In en, this message translates to:
  /// **'Another phone is connected to this computer'**
  String get remoteReplaced;

  /// Phone status.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get remoteConnecting;

  /// Phone status.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the computer… (open Minerva on it)'**
  String get remoteWaitingHost;

  /// Phone error.
  ///
  /// In en, this message translates to:
  /// **'Could not use the microphone: {error}'**
  String micFailed(String error);

  /// Display form: default submit button.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get displaySubmit;

  /// Display form: after submitting.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get displaySubmitted;

  /// Display form: required field.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get displayRequired;

  /// Display form: empty date field.
  ///
  /// In en, this message translates to:
  /// **'Pick a date'**
  String get displayPickDate;

  /// Display: video failed.
  ///
  /// In en, this message translates to:
  /// **'Can\'t play the video'**
  String get displayVideoError;

  /// Display form: switch on.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get displayYes;

  /// Display form: switch off.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get displayNo;

  /// Title of the form that asks for a credential.
  ///
  /// In en, this message translates to:
  /// **'Credential: {name}'**
  String vaultFormTitle(String name);

  /// Note under the credential form's description.
  ///
  /// In en, this message translates to:
  /// **'Saved in Minerva\'s encrypted vault on this Mac. The assistant never sees what you type here.'**
  String get vaultFormNote;

  /// Credential form: submit button.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get vaultSave;

  /// Credential form: after saving (followed by a check mark).
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get vaultSaved;

  /// Cancel button.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// Tooltip: reveal a secret field.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get vaultShowSecret;

  /// Tooltip: hide a secret field.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get vaultHideSecret;

  /// Vault button tooltip and dialog title.
  ///
  /// In en, this message translates to:
  /// **'Credentials'**
  String get vaultCredentials;

  /// Intro of the credentials dialog.
  ///
  /// In en, this message translates to:
  /// **'Logins and tokens the assistant can use without seeing them. To add one, ask the assistant; it shows a form for it.'**
  String get vaultDialogIntro;

  /// Credentials dialog, no credentials.
  ///
  /// In en, this message translates to:
  /// **'No credentials saved yet.'**
  String get vaultEmpty;

  /// Delete button / tooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// Confirmation before deleting a credential.
  ///
  /// In en, this message translates to:
  /// **'Delete the credential \"{name}\"?'**
  String vaultDeleteConfirm(String name);

  /// Field names of a saved credential, comma-separated.
  ///
  /// In en, this message translates to:
  /// **'Fields: {names}'**
  String vaultFields(String names);

  /// Credentials dialog when the vault failed to open.
  ///
  /// In en, this message translates to:
  /// **'The vault is not available: {error}'**
  String vaultUnavailable(String error);

  /// Tooltip of the language button in the bottom bar.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// Language menu item: follow the operating system's language.
  ///
  /// In en, this message translates to:
  /// **'System language'**
  String get languageSystem;

  /// Tooltip and title of the picker of the Claude model Minerva runs on.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get modelTitle;

  /// No description provided for @modelConversation.
  ///
  /// In en, this message translates to:
  /// **'Conversation'**
  String get modelConversation;

  /// No description provided for @modelWorkers.
  ///
  /// In en, this message translates to:
  /// **'Workers'**
  String get modelWorkers;

  /// No description provided for @modelSearch.
  ///
  /// In en, this message translates to:
  /// **'Search models'**
  String get modelSearch;

  /// No description provided for @modelDefault.
  ///
  /// In en, this message translates to:
  /// **'default'**
  String get modelDefault;

  /// No description provided for @modelPrevious.
  ///
  /// In en, this message translates to:
  /// **'Previous models ({count})'**
  String modelPrevious(int count);

  /// No description provided for @modelNoMatch.
  ///
  /// In en, this message translates to:
  /// **'No model matches'**
  String get modelNoMatch;

  /// No description provided for @modelLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading {agent}\'s models…'**
  String modelLoading(String agent);

  /// No description provided for @modelUnavailable.
  ///
  /// In en, this message translates to:
  /// **'{agent} is not installed or not signed in. Install it and sign in from a terminal (for Antigravity: run agy; for Codex: run codex login).'**
  String modelUnavailable(String agent);

  /// No description provided for @modelProviderNote.
  ///
  /// In en, this message translates to:
  /// **'Each provider keeps its own conversation.'**
  String get modelProviderNote;

  /// No description provided for @modelEffort.
  ///
  /// In en, this message translates to:
  /// **'Effort'**
  String get modelEffort;

  /// No description provided for @effortLow.
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get effortLow;

  /// No description provided for @effortMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get effortMedium;

  /// No description provided for @effortHigh.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get effortHigh;

  /// No description provided for @effortXhigh.
  ///
  /// In en, this message translates to:
  /// **'Very high'**
  String get effortXhigh;

  /// No description provided for @effortMax.
  ///
  /// In en, this message translates to:
  /// **'Max'**
  String get effortMax;

  /// No description provided for @effortUltra.
  ///
  /// In en, this message translates to:
  /// **'Ultra'**
  String get effortUltra;

  /// No description provided for @modelSpeed.
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get modelSpeed;

  /// No description provided for @speedStandard.
  ///
  /// In en, this message translates to:
  /// **'Standard'**
  String get speedStandard;

  /// No description provided for @speedFast.
  ///
  /// In en, this message translates to:
  /// **'Fast'**
  String get speedFast;

  /// No description provided for @fastUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Fast mode is not available: {reason}'**
  String fastUnavailable(String reason);

  /// No description provided for @fastExtraUsageDisabled.
  ///
  /// In en, this message translates to:
  /// **'extra usage is turned off on your Claude account'**
  String get fastExtraUsageDisabled;

  /// No description provided for @modelConversationNote.
  ///
  /// In en, this message translates to:
  /// **'The conversation goes on with the new model.'**
  String get modelConversationNote;

  /// No description provided for @modelWorkersNote.
  ///
  /// In en, this message translates to:
  /// **'Applies to workers started from now on.'**
  String get modelWorkersNote;

  /// Model picker tab: the AI providers (Claude, Antigravity, Codex) and their status.
  ///
  /// In en, this message translates to:
  /// **'Providers'**
  String get modelProviders;

  /// No description provided for @providerReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get providerReady;

  /// No description provided for @providerChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get providerChecking;

  /// No description provided for @providerUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not installed or not signed in'**
  String get providerUnavailable;

  /// No description provided for @providerLimited.
  ///
  /// In en, this message translates to:
  /// **'Usage limit until {time}'**
  String providerLimited(String time);

  /// No description provided for @providerSignedOut.
  ///
  /// In en, this message translates to:
  /// **'Signed out: sign in again from a terminal (retrying at {time})'**
  String providerSignedOut(String time);

  /// No description provided for @providerUsedBy.
  ///
  /// In en, this message translates to:
  /// **'In use: {uses}'**
  String providerUsedBy(String uses);

  /// No description provided for @providersNote.
  ///
  /// In en, this message translates to:
  /// **'Minerva runs on the subscriptions of the agents installed on this Mac: Claude Code (claude), Antigravity (agy) and Codex (codex login). Connect several and add backups: when one hits its usage limit, Minerva goes on with the next.'**
  String get providersNote;

  /// No description provided for @fallbacks.
  ///
  /// In en, this message translates to:
  /// **'Backups, in order'**
  String get fallbacks;

  /// No description provided for @fallbacksNote.
  ///
  /// In en, this message translates to:
  /// **'When a provider hits its usage limit, Minerva goes on with the next backup, and back to the first choice once the limit is over.'**
  String get fallbacksNote;

  /// No description provided for @fallbacksNone.
  ///
  /// In en, this message translates to:
  /// **'No backups: if the provider is out, Minerva says so and waits.'**
  String get fallbacksNone;

  /// No description provided for @fallbackAdd.
  ///
  /// In en, this message translates to:
  /// **'Add backup'**
  String get fallbackAdd;

  /// No description provided for @fallbackRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get fallbackRemove;

  /// No description provided for @fallbackUp.
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get fallbackUp;

  /// No description provided for @fallbackDown.
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get fallbackDown;

  /// No description provided for @modelOnBackup.
  ///
  /// In en, this message translates to:
  /// **'{provider} is out: the conversation is on {model} until it is back.'**
  String modelOnBackup(String provider, String model);

  /// Spoken (or sent on Telegram) when the brain's provider hits its usage limit and Minerva moves to the next backup.
  ///
  /// In en, this message translates to:
  /// **'{from} can\'t answer right now. I\'ll go on with {to}.'**
  String providerFellBack(String from, String to);

  /// Phone: title of the settings screen and tooltip of its button.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// Phone settings screen while the computer is not connected.
  ///
  /// In en, this message translates to:
  /// **'Connect to the computer to change its settings.'**
  String get settingsOffline;

  /// Phone settings screen: note at the top.
  ///
  /// In en, this message translates to:
  /// **'These are the computer\'s settings: changes apply to Minerva there.'**
  String get settingsAppliedOnComputer;

  /// Setting: the voice Minerva reads its replies with.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get voice;

  /// One of the female voices.
  ///
  /// In en, this message translates to:
  /// **'Female {n}'**
  String voiceFemale(int n);

  /// One of the male voices.
  ///
  /// In en, this message translates to:
  /// **'Male {n}'**
  String voiceMale(int n);

  /// Phone settings item: Android's "display over other apps" permission for Minerva's floating orb.
  ///
  /// In en, this message translates to:
  /// **'Orb over other apps'**
  String get phoneOverlay;

  /// Floating orb status line.
  ///
  /// In en, this message translates to:
  /// **'On: Minerva\'s orb floats over other apps while it is linked'**
  String get phoneOverlayOn;

  /// Floating orb status line.
  ///
  /// In en, this message translates to:
  /// **'Off: allow display over other apps to see Minerva\'s orb outside the app'**
  String get phoneOverlayOff;

  /// Telegram reply to a message Minerva can't read.
  ///
  /// In en, this message translates to:
  /// **'I can\'t take video, stickers or locations here yet. Write it to me, please.'**
  String get telegramUnsupported;

  /// Telegram reply when a photo or file fails to download.
  ///
  /// In en, this message translates to:
  /// **'I couldn\'t download that from Telegram. Try sending it again.'**
  String get telegramDownloadFailed;

  /// Telegram reply when a voice note or audio file can't be decoded or transcribed.
  ///
  /// In en, this message translates to:
  /// **'I couldn\'t transcribe that audio. Try again, or write it to me.'**
  String get telegramTranscribeFailed;

  /// Telegram reply when a voice note or audio file has no recognizable speech.
  ///
  /// In en, this message translates to:
  /// **'I couldn\'t make out any speech in that audio.'**
  String get telegramNoSpeech;

  /// Telegram channel status.
  ///
  /// In en, this message translates to:
  /// **'Telegram rejected the bot token: save a valid one as the credential telegram (field token).'**
  String get telegramBadToken;

  /// Telegram channel status.
  ///
  /// In en, this message translates to:
  /// **'This Telegram bot has a webhook set or another program reads it: Minerva needs a bot of its own.'**
  String get telegramConflict;

  /// Usage rings tooltip (status bar): a provider's plan limit.
  ///
  /// In en, this message translates to:
  /// **'5-hour limit'**
  String get usageSessionLimit;

  /// Usage rings tooltip (status bar): a provider's plan limit.
  ///
  /// In en, this message translates to:
  /// **'Weekly limit'**
  String get usageWeekLimit;

  /// Usage rings tooltip (status bar): a provider's plan limit.
  ///
  /// In en, this message translates to:
  /// **'{hours}-hour limit'**
  String usageOtherLimit(int hours);

  /// Usage rings tooltip (status bar): a provider's plan limit.
  ///
  /// In en, this message translates to:
  /// **'{percent}% left'**
  String usageLeft(int percent);

  /// Usage rings tooltip (status bar): a provider's plan limit.
  ///
  /// In en, this message translates to:
  /// **'resets {when}'**
  String usageResets(String when);

  /// Usage card (status bar): a limit's projection at the current pace.
  ///
  /// In en, this message translates to:
  /// **'projected {percent}% by the reset'**
  String usageProjection(int percent);

  /// Usage card (status bar): a limit's projection at the current pace.
  ///
  /// In en, this message translates to:
  /// **'runs out around {time}'**
  String usageRunsOutAt(String time);

  /// Usage card (status bar): a limit's projection at the current pace.
  ///
  /// In en, this message translates to:
  /// **'runs out around {when}'**
  String usageRunsOutOn(String when);

  /// Usage card (status bar): a limit's projection at the current pace.
  ///
  /// In en, this message translates to:
  /// **'limit reached'**
  String get usageSpent;

  /// Workers panel: a worker's status while it runs.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get workerRunning;

  /// Workers panel: a worker that finished.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get workerDone;

  /// Workers panel: a worker that failed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get workerFailed;

  /// Workers panel: a worker that was stopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get workerStopped;

  /// Workers panel: a worker cut short when the app closed.
  ///
  /// In en, this message translates to:
  /// **'Interrupted'**
  String get workerInterrupted;

  /// Workers panel: a running worker with no progress note yet.
  ///
  /// In en, this message translates to:
  /// **'Getting started…'**
  String get workerStarting;

  /// Workers panel: workers that do not fit.
  ///
  /// In en, this message translates to:
  /// **'+{count} more'**
  String workersMore(int count);

  /// Projects panel (left of the orb): when a project's folder last changed, for a project no worker ran in.
  ///
  /// In en, this message translates to:
  /// **'Edited {when}'**
  String projectEdited(String when);

  /// Projects panel: something that happened less than a minute ago.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get timeJustNow;

  /// Projects panel: something that happened minutes ago.
  ///
  /// In en, this message translates to:
  /// **'{count} min ago'**
  String timeMinutesAgo(int count);

  /// Projects panel: something that happened hours ago.
  ///
  /// In en, this message translates to:
  /// **'{count} h ago'**
  String timeHoursAgo(int count);

  /// Projects panel: something that happened days ago.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{yesterday} other{{count} days ago}}'**
  String timeDaysAgo(int count);

  /// Name of the speaker-embedding model.
  ///
  /// In en, this message translates to:
  /// **'Voice identification (CAM++)'**
  String get modelSpeaker;

  /// Setting: Minerva only reacts to what begins with "Minerva".
  ///
  /// In en, this message translates to:
  /// **'Wake word'**
  String get wakeMode;

  /// Wake word mode: off, Minerva takes everything said.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get wakeModeOff;

  /// Wake word mode: always on.
  ///
  /// In en, this message translates to:
  /// **'Always'**
  String get wakeModeOn;

  /// Wake word mode: on while another voice than the owner's is around.
  ///
  /// In en, this message translates to:
  /// **'By voice'**
  String get wakeModeAuto;

  /// Tooltip while wake word mode is filtering.
  ///
  /// In en, this message translates to:
  /// **'Wake word on: say \"Minerva…\"'**
  String get wakeActive;

  /// Setting: minutes automatic wake word mode stays on after another voice.
  ///
  /// In en, this message translates to:
  /// **'Back off after'**
  String get wakeTimeout;

  /// Menu item: automatic wake word mode turns off after this many minutes without another voice.
  ///
  /// In en, this message translates to:
  /// **'Back off after {minutes} min'**
  String wakeTimeoutMinutes(int minutes);

  /// A number of minutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String minutes(int minutes);

  /// Voice profile: the model is loading.
  ///
  /// In en, this message translates to:
  /// **'Loading voice identification…'**
  String get voiceIdLoading;

  /// Voice profile: enrolling.
  ///
  /// In en, this message translates to:
  /// **'Learning your voice ({done}/{total})'**
  String voiceIdEnrolling(int done, int total);

  /// Voice profile: ready.
  ///
  /// In en, this message translates to:
  /// **'Your voice is learned'**
  String get voiceIdReady;

  /// Voice profile: the model failed.
  ///
  /// In en, this message translates to:
  /// **'Voice identification unavailable'**
  String get voiceIdFailed;

  /// Action: forget the owner's voice profile and enroll it again.
  ///
  /// In en, this message translates to:
  /// **'Learn my voice again'**
  String get voiceIdReset;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
