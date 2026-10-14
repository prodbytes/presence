import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
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

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
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
    Locale('pt'),
  ];

  /// No description provided for @aboutLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied'**
  String get aboutLinkCopied;

  /// No description provided for @aboutOpenSource.
  ///
  /// In en, this message translates to:
  /// **'Presence is open source:'**
  String get aboutOpenSource;

  /// No description provided for @aboutParagraph.
  ///
  /// In en, this message translates to:
  /// **'Presence turns a phone, tablet, laptop or Raspberry Pi into an always-on camera for a place you look after: live feeds, clips that include the moments before, and clips on motion. Only record where you\'re allowed to.'**
  String get aboutParagraph;

  /// No description provided for @authAccessAdmin.
  ///
  /// In en, this message translates to:
  /// **'Admin Access'**
  String get authAccessAdmin;

  /// No description provided for @authAccessFree.
  ///
  /// In en, this message translates to:
  /// **'Free Access'**
  String get authAccessFree;

  /// No description provided for @authAccessPremium.
  ///
  /// In en, this message translates to:
  /// **'Premium Access'**
  String get authAccessPremium;

  /// No description provided for @authBackedUp.
  ///
  /// In en, this message translates to:
  /// **'Clips and events are backed up'**
  String get authBackedUp;

  /// No description provided for @authBackedUpBoth.
  ///
  /// In en, this message translates to:
  /// **'Backed up ({up} uploaded, {down} restored)'**
  String authBackedUpBoth(int up, int down);

  /// No description provided for @authBackedUpRestored.
  ///
  /// In en, this message translates to:
  /// **'Backed up ({down} restored)'**
  String authBackedUpRestored(int down);

  /// No description provided for @authBackedUpUploaded.
  ///
  /// In en, this message translates to:
  /// **'Backed up ({up} uploaded)'**
  String authBackedUpUploaded(int up);

  /// No description provided for @authBackupOff.
  ///
  /// In en, this message translates to:
  /// **'Cloud backup is off'**
  String get authBackupOff;

  /// No description provided for @authCheckAgain.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get authCheckAgain;

  /// No description provided for @authCheckingRoles.
  ///
  /// In en, this message translates to:
  /// **'Checking roles…'**
  String get authCheckingRoles;

  /// The account sheet's last button, and the confirmation dialog's delete button.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get authDeleteAccount;

  /// No description provided for @authDeleteAccountCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get authDeleteAccountCancel;

  /// No description provided for @authDeleteAccountChanged.
  ///
  /// In en, this message translates to:
  /// **'Your account\'s profile changed. Close this and try again.'**
  String get authDeleteAccountChanged;

  /// No description provided for @authDeleteAccountConfirm.
  ///
  /// In en, this message translates to:
  /// **'I understand that this can\'t be undone'**
  String get authDeleteAccountConfirm;

  /// No description provided for @authDeleteAccountDevice.
  ///
  /// In en, this message translates to:
  /// **'This device\'s copies of the profile\'s events and clips are deleted too, and you\'re signed out. This can\'t be undone.'**
  String get authDeleteAccountDevice;

  /// No description provided for @authDeleteAccountDone.
  ///
  /// In en, this message translates to:
  /// **'Your account and its profile were deleted'**
  String get authDeleteAccountDone;

  /// No description provided for @authDeleteAccountFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t delete the account ({error}). Try again.'**
  String authDeleteAccountFailed(String error);

  /// No description provided for @authDeleteAccountLinked.
  ///
  /// In en, this message translates to:
  /// **'{email} is linked to the profile {profile}, owned by {owner}. Deleting your account unlinks it and deletes your Feedback & Help messages; the profile and its data stay its owner\'s.'**
  String authDeleteAccountLinked(String email, String profile, String owner);

  /// No description provided for @authDeleteAccountManage.
  ///
  /// In en, this message translates to:
  /// **'How to cancel a subscription'**
  String get authDeleteAccountManage;

  /// No description provided for @authDeleteAccountOthers.
  ///
  /// In en, this message translates to:
  /// **'These accounts linked to it lose access too: {emails}.'**
  String authDeleteAccountOthers(String emails);

  /// No description provided for @authDeleteAccountOwner.
  ///
  /// In en, this message translates to:
  /// **'You own the profile {profile}. Deleting your account deletes the whole profile: its events, clips, recordings and settings in the cloud, its Feedback & Help messages, its recognition labels and its devices\' stream keys.'**
  String authDeleteAccountOwner(String profile);

  /// No description provided for @authDeleteAccountSignInAgain.
  ///
  /// In en, this message translates to:
  /// **'Sign in again, then delete the account.'**
  String get authDeleteAccountSignInAgain;

  /// No description provided for @authDeleteAccountSubscription.
  ///
  /// In en, this message translates to:
  /// **'Deleting your account doesn\'t cancel a Premium subscription: cancel it first, from the link in your Stripe receipt, or ask us.'**
  String get authDeleteAccountSubscription;

  /// No description provided for @authDeleteAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete your account?'**
  String get authDeleteAccountTitle;

  /// No description provided for @authDeleteAccountUnfinished.
  ///
  /// In en, this message translates to:
  /// **'The cloud data is still being deleted. Try again in a minute to finish.'**
  String get authDeleteAccountUnfinished;

  /// No description provided for @authDeleteAccountUnlinked.
  ///
  /// In en, this message translates to:
  /// **'Your account was deleted and unlinked from the profile'**
  String get authDeleteAccountUnlinked;

  /// No description provided for @authDeleteDevice.
  ///
  /// In en, this message translates to:
  /// **'Delete {device}'**
  String authDeleteDevice(String device);

  /// No description provided for @authDeviceCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 device} other{{count} devices}}'**
  String authDeviceCount(int count);

  /// No description provided for @authDevicesHidden.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 device\'s events are hidden: {plan} shows your first {limit} devices.} other{{count} devices\' events are hidden: {plan} shows your first {limit} devices.}}'**
  String authDevicesHidden(int count, String plan, int limit);

  /// No description provided for @authFeedback.
  ///
  /// In en, this message translates to:
  /// **'Feedback'**
  String get authFeedback;

  /// No description provided for @authFeedbackIntro.
  ///
  /// In en, this message translates to:
  /// **'Members\' messages from the Help tab, the latest active first. Your replies show there.'**
  String get authFeedbackIntro;

  /// No description provided for @authFeedbackLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load feedback ({error}).'**
  String authFeedbackLoadFailed(String error);

  /// No description provided for @authHaveCode.
  ///
  /// In en, this message translates to:
  /// **'Have a code from your other account? Enter it to link this one to it.'**
  String get authHaveCode;

  /// A device whose events are hidden
  ///
  /// In en, this message translates to:
  /// **'hidden'**
  String get authHidden;

  /// No description provided for @authHiddenTooltip.
  ///
  /// In en, this message translates to:
  /// **'Past the plan\'s device limit: it syncs, but its events are hidden here'**
  String get authHiddenTooltip;

  /// No description provided for @authHideDevice.
  ///
  /// In en, this message translates to:
  /// **'Hide {device}\'s events'**
  String authHideDevice(String device);

  /// No description provided for @authLinkAnother.
  ///
  /// In en, this message translates to:
  /// **'Link another account'**
  String get authLinkAnother;

  /// No description provided for @authLinkCode.
  ///
  /// In en, this message translates to:
  /// **'Link code'**
  String get authLinkCode;

  /// No description provided for @authLinkCodeHelp.
  ///
  /// In en, this message translates to:
  /// **'Within 10 minutes, sign in with the other Google account and enter this code under Linked accounts.'**
  String get authLinkCodeHelp;

  /// No description provided for @authLinkCodeWrong.
  ///
  /// In en, this message translates to:
  /// **'That code is wrong, already used or expired.'**
  String get authLinkCodeWrong;

  /// No description provided for @authLinkConflict.
  ///
  /// In en, this message translates to:
  /// **'This account can\'t be linked: it has cloud data of its own, or other accounts are linked to it.'**
  String get authLinkConflict;

  /// No description provided for @authLinkNoBackup.
  ///
  /// In en, this message translates to:
  /// **'Cloud backup isn\'t set up, so accounts can\'t be linked.'**
  String get authLinkNoBackup;

  /// No description provided for @authLinkOtherAccount.
  ///
  /// In en, this message translates to:
  /// **'Have access with another Google account? Link it'**
  String get authLinkOtherAccount;

  /// No description provided for @authLinkThis.
  ///
  /// In en, this message translates to:
  /// **'Link this account'**
  String get authLinkThis;

  /// No description provided for @authLinkTooMany.
  ///
  /// In en, this message translates to:
  /// **'Too many tries. Wait a minute and try again.'**
  String get authLinkTooMany;

  /// No description provided for @authLinkedAccounts.
  ///
  /// In en, this message translates to:
  /// **'Linked accounts'**
  String get authLinkedAccounts;

  /// No description provided for @authLinkedIntro.
  ///
  /// In en, this message translates to:
  /// **'Any of these Google accounts reaches the same clips and events.'**
  String get authLinkedIntro;

  /// No description provided for @authLinkedTo.
  ///
  /// In en, this message translates to:
  /// **'Linked to {owner}.'**
  String authLinkedTo(String owner);

  /// No description provided for @authLinkedToProfile.
  ///
  /// In en, this message translates to:
  /// **'Linked to the profile.'**
  String get authLinkedToProfile;

  /// No description provided for @authMoreHidden.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 more device syncs, but its events are hidden: {plan} shows your first {limit}.} other{{count} more devices sync, but their events are hidden: {plan} shows your first {limit}.}}'**
  String authMoreHidden(int count, String plan, int limit);

  /// No description provided for @authNoEvents.
  ///
  /// In en, this message translates to:
  /// **'No events'**
  String get authNoEvents;

  /// No description provided for @authNoFeedback.
  ///
  /// In en, this message translates to:
  /// **'No feedback yet.'**
  String get authNoFeedback;

  /// No description provided for @authNoRoles.
  ///
  /// In en, this message translates to:
  /// **'No roles yet'**
  String get authNoRoles;

  /// No description provided for @authNoVerifiedEmail.
  ///
  /// In en, this message translates to:
  /// **'This account has no verified email.'**
  String get authNoVerifiedEmail;

  /// No description provided for @authNotSignedIn.
  ///
  /// In en, this message translates to:
  /// **'Not signed in.'**
  String get authNotSignedIn;

  /// No description provided for @authOpenHost.
  ///
  /// In en, this message translates to:
  /// **'Open {host}'**
  String authOpenHost(String host);

  /// No description provided for @authOsUnknown.
  ///
  /// In en, this message translates to:
  /// **'Operating system unknown'**
  String get authOsUnknown;

  /// No description provided for @authOthersHidden.
  ///
  /// In en, this message translates to:
  /// **'Your other devices\' events are hidden on this one: {plan} shows your first {limit} devices.'**
  String authOthersHidden(String plan, int limit);

  /// The profile's owner account
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get authOwner;

  /// No description provided for @authPastLimit.
  ///
  /// In en, this message translates to:
  /// **'This device is past your first {limit}: it syncs, but its events are hidden on your other devices, and theirs here.'**
  String authPastLimit(int limit);

  /// No description provided for @authPaymentsDefaults.
  ///
  /// In en, this message translates to:
  /// **'Not saved yet: these are the deploy\'s links.'**
  String get authPaymentsDefaults;

  /// No description provided for @authPaymentsIntro.
  ///
  /// In en, this message translates to:
  /// **'The Stripe Payment Links free members upgrade to Premium with. Leave one empty not to offer that plan.'**
  String get authPaymentsIntro;

  /// No description provided for @authPaymentsInvalid.
  ///
  /// In en, this message translates to:
  /// **'Empty, or an https link on stripe.com'**
  String get authPaymentsInvalid;

  /// No description provided for @authPaymentsMonthly.
  ///
  /// In en, this message translates to:
  /// **'Monthly plan link'**
  String get authPaymentsMonthly;

  /// No description provided for @authPaymentsSave.
  ///
  /// In en, this message translates to:
  /// **'Save links'**
  String get authPaymentsSave;

  /// No description provided for @authPaymentsSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the links ({error})'**
  String authPaymentsSaveFailed(String error);

  /// No description provided for @authPaymentsSaved.
  ///
  /// In en, this message translates to:
  /// **'Payment links saved'**
  String get authPaymentsSaved;

  /// No description provided for @authPaymentsTitle.
  ///
  /// In en, this message translates to:
  /// **'Payments'**
  String get authPaymentsTitle;

  /// No description provided for @authPaymentsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The payments API didn\'t answer.'**
  String get authPaymentsUnavailable;

  /// No description provided for @authPaymentsYearly.
  ///
  /// In en, this message translates to:
  /// **'Yearly plan link'**
  String get authPaymentsYearly;

  /// The free plan's name
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get authPlanFree;

  /// No description provided for @authPlanFreeText.
  ///
  /// In en, this message translates to:
  /// **'Free: up to {free} devices sync with each other while online. Premium adds cloud backup and up to {premium} devices: US\$20 a month, the first week free.'**
  String authPlanFreeText(int free, int premium);

  /// The paid plan's name
  ///
  /// In en, this message translates to:
  /// **'Premium'**
  String get authPlanPremium;

  /// No description provided for @authPlanPremiumText.
  ///
  /// In en, this message translates to:
  /// **'Premium: cloud backup, and up to {limit} devices sync.'**
  String authPlanPremiumText(int limit);

  /// No description provided for @authPremiumMonthly.
  ///
  /// In en, this message translates to:
  /// **'Premium monthly'**
  String get authPremiumMonthly;

  /// No description provided for @authPremiumShowsUpTo.
  ///
  /// In en, this message translates to:
  /// **'{text} Premium shows up to {limit}.'**
  String authPremiumShowsUpTo(String text, int limit);

  /// No description provided for @authPremiumYearly.
  ///
  /// In en, this message translates to:
  /// **'Premium yearly'**
  String get authPremiumYearly;

  /// Account sheet: label above the profile ID
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get authProfile;

  /// No description provided for @authProviderNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'This sign-in isn\'t set up on the server yet.'**
  String get authProviderNotConfigured;

  /// No description provided for @authRbacrText.
  ///
  /// In en, this message translates to:
  /// **'Voucher codes and maintenance mode are managed in rbacr, which keeps every role. Members redeem codes on the Sign up sheet.'**
  String get authRbacrText;

  /// No description provided for @authRedeem.
  ///
  /// In en, this message translates to:
  /// **'Redeem'**
  String get authRedeem;

  /// No description provided for @authReload.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get authReload;

  /// No description provided for @authReplyFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reply to {email} ({error})'**
  String authReplyFailed(String email, String error);

  /// No description provided for @authRequestFailed.
  ///
  /// In en, this message translates to:
  /// **'The request failed (HTTP {status}).'**
  String authRequestFailed(int status);

  /// No description provided for @authRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get authRetry;

  /// The root role's name
  ///
  /// In en, this message translates to:
  /// **'Root'**
  String get authRoleRoot;

  /// No description provided for @authRolesSemantics.
  ///
  /// In en, this message translates to:
  /// **'Roles: {roles}'**
  String authRolesSemantics(String roles);

  /// Message when a Sign in with Apple session can't be renewed
  ///
  /// In en, this message translates to:
  /// **'Your session ended. Sign in again.'**
  String get authSessionEnded;

  /// No description provided for @authSessionRefused.
  ///
  /// In en, this message translates to:
  /// **'Presence didn\'t accept this sign-in.'**
  String get authSessionRefused;

  /// No description provided for @authSessionUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach Presence. Try again.'**
  String get authSessionUnreachable;

  /// No description provided for @authShowDevice.
  ///
  /// In en, this message translates to:
  /// **'Show {device}\'s events'**
  String authShowDevice(String device);

  /// Account button tooltip, signed out; on iOS also the app bar's button that opens the sheet with Apple and Google sign-in
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get authSignIn;

  /// No description provided for @authSignInToPresence.
  ///
  /// In en, this message translates to:
  /// **'Sign in to Presence'**
  String get authSignInToPresence;

  /// Apple's sign-in button (iOS); Apple's standard wording
  ///
  /// In en, this message translates to:
  /// **'Sign in with Apple'**
  String get authSignInWithApple;

  /// No description provided for @authSignInWithGoogle.
  ///
  /// In en, this message translates to:
  /// **'Sign in with Google'**
  String get authSignInWithGoogle;

  /// No description provided for @authSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get authSignOut;

  /// No description provided for @authSignUp.
  ///
  /// In en, this message translates to:
  /// **'Sign up'**
  String get authSignUp;

  /// No description provided for @authSignedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in as {identity}'**
  String authSignedInAs(String identity);

  /// No description provided for @authSomethingWrong.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong ({error}).'**
  String authSomethingWrong(String error);

  /// No description provided for @authStreamerBody.
  ///
  /// In en, this message translates to:
  /// **'Paste this in a terminal on a Raspberry Pi with a camera (Raspberry Pi OS, 32- or 64-bit), even one without a screen. It installs the Presence streamer as a new device of this profile, which records from every boot and keeps the clips with people and animals. Nobody signs in on the Pi.'**
  String get authStreamerBody;

  /// No description provided for @authStreamerCopied.
  ///
  /// In en, this message translates to:
  /// **'Command copied: paste it on the Raspberry Pi'**
  String get authStreamerCopied;

  /// No description provided for @authStreamerCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy command'**
  String get authStreamerCopy;

  /// No description provided for @authStreamerCreate.
  ///
  /// In en, this message translates to:
  /// **'Create command'**
  String get authStreamerCreate;

  /// No description provided for @authStreamerFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t create the command ({error})'**
  String authStreamerFailed(String error);

  /// No description provided for @authStreamerKeyOnce.
  ///
  /// In en, this message translates to:
  /// **'It holds this device\'s key, shown only now: keep it private. Deleting the device stops it; creating another command makes another device.'**
  String get authStreamerKeyOnce;

  /// No description provided for @authStreamerTitle.
  ///
  /// In en, this message translates to:
  /// **'Stream from a Raspberry Pi'**
  String get authStreamerTitle;

  /// No description provided for @authSubscribe.
  ///
  /// In en, this message translates to:
  /// **'Subscribe'**
  String get authSubscribe;

  /// No description provided for @authSubscribeButton.
  ///
  /// In en, this message translates to:
  /// **'Subscribe at nu01.com'**
  String get authSubscribeButton;

  /// No description provided for @authSubscribeText.
  ///
  /// In en, this message translates to:
  /// **'{email} doesn\'t have access to Presence yet. Subscribe at nu01.com: Free, or Premium for cloud backup and more devices. Then check again here.'**
  String authSubscribeText(String email);

  /// No description provided for @authSyncFree.
  ///
  /// In en, this message translates to:
  /// **'Your devices sync with each other while online'**
  String get authSyncFree;

  /// No description provided for @authThisAccount.
  ///
  /// In en, this message translates to:
  /// **'This account'**
  String get authThisAccount;

  /// No description provided for @authThisDevice.
  ///
  /// In en, this message translates to:
  /// **'this device'**
  String get authThisDevice;

  /// No description provided for @authUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Sign-in is unavailable.'**
  String get authUnavailable;

  /// No description provided for @authUnlink.
  ///
  /// In en, this message translates to:
  /// **'Unlink'**
  String get authUnlink;

  /// No description provided for @authUnlinked.
  ///
  /// In en, this message translates to:
  /// **'{email} was unlinked.'**
  String authUnlinked(String email);

  /// No description provided for @authUpgrade.
  ///
  /// In en, this message translates to:
  /// **'Upgrade'**
  String get authUpgrade;

  /// No description provided for @authUpgradePremium.
  ///
  /// In en, this message translates to:
  /// **'Upgrade to Premium'**
  String get authUpgradePremium;

  /// No description provided for @authUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Upload failed'**
  String get authUploadFailed;

  /// No description provided for @authUploading.
  ///
  /// In en, this message translates to:
  /// **'Uploading…'**
  String get authUploading;

  /// No description provided for @authVoucherDiscount.
  ///
  /// In en, this message translates to:
  /// **'That code gives {discount}% off. Paying the rest isn\'t available yet, so it can\'t let you in.'**
  String authVoucherDiscount(int discount);

  /// No description provided for @authVoucherFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t redeem the code.'**
  String get authVoucherFailed;

  /// No description provided for @authVoucherFailedDetail.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t redeem the code ({error}).'**
  String authVoucherFailedDetail(String error);

  /// No description provided for @authVoucherInvalid.
  ///
  /// In en, this message translates to:
  /// **'That code is invalid, expired or used up.'**
  String get authVoucherInvalid;

  /// No description provided for @authVoucherLabel.
  ///
  /// In en, this message translates to:
  /// **'Voucher code'**
  String get authVoucherLabel;

  /// No description provided for @authVoucherPayment.
  ///
  /// In en, this message translates to:
  /// **'That code needs a payment, which isn\'t available yet, so it can\'t let you in.'**
  String get authVoucherPayment;

  /// No description provided for @authVoucherPrompt.
  ///
  /// In en, this message translates to:
  /// **'Have a voucher code? Redeem it to get in right away.'**
  String get authVoucherPrompt;

  /// No description provided for @authVoucherTooMany.
  ///
  /// In en, this message translates to:
  /// **'Too many tries. Wait a while and try again.'**
  String get authVoucherTooMany;

  /// No description provided for @authVouchersTitle.
  ///
  /// In en, this message translates to:
  /// **'Vouchers and maintenance'**
  String get authVouchersTitle;

  /// No description provided for @authYourAccount.
  ///
  /// In en, this message translates to:
  /// **'Your account'**
  String get authYourAccount;

  /// No description provided for @cameraActionAll.
  ///
  /// In en, this message translates to:
  /// **'Show all devices'**
  String get cameraActionAll;

  /// No description provided for @cameraActionNormal.
  ///
  /// In en, this message translates to:
  /// **'Back to normal: this camera'**
  String get cameraActionNormal;

  /// No description provided for @cameraActionStopped.
  ///
  /// In en, this message translates to:
  /// **'Stop: no capturing or syncing'**
  String get cameraActionStopped;

  /// No description provided for @cameraActionUnattended.
  ///
  /// In en, this message translates to:
  /// **'Go unattended: screen off, still capturing'**
  String get cameraActionUnattended;

  /// No description provided for @cameraAgeDays.
  ///
  /// In en, this message translates to:
  /// **'{days} d ago'**
  String cameraAgeDays(int days);

  /// No description provided for @cameraAgeHours.
  ///
  /// In en, this message translates to:
  /// **'{hours} h ago'**
  String cameraAgeHours(int hours);

  /// No description provided for @cameraAgeJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get cameraAgeJustNow;

  /// No description provided for @cameraAgeMinutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min ago'**
  String cameraAgeMinutes(int minutes);

  /// No description provided for @cameraAgeSeconds.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s ago'**
  String cameraAgeSeconds(int seconds);

  /// No description provided for @cameraAskedFreshGrab.
  ///
  /// In en, this message translates to:
  /// **'Asked for a fresh grab'**
  String get cameraAskedFreshGrab;

  /// The Clip button's label
  ///
  /// In en, this message translates to:
  /// **'Clip'**
  String get cameraClip;

  /// No description provided for @cameraClipCameraOff.
  ///
  /// In en, this message translates to:
  /// **'Camera off'**
  String get cameraClipCameraOff;

  /// No description provided for @cameraClipCountdown.
  ///
  /// In en, this message translates to:
  /// **'Clip · {time}'**
  String cameraClipCountdown(String time);

  /// No description provided for @cameraClipLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load this clip'**
  String get cameraClipLoadFailed;

  /// No description provided for @cameraClipNextIn.
  ///
  /// In en, this message translates to:
  /// **'Next automatic clip in {countdown}'**
  String cameraClipNextIn(String countdown);

  /// No description provided for @cameraClipNoCamera.
  ///
  /// In en, this message translates to:
  /// **'No camera'**
  String get cameraClipNoCamera;

  /// No description provided for @cameraClipNotReady.
  ///
  /// In en, this message translates to:
  /// **'Camera not ready'**
  String get cameraClipNotReady;

  /// No description provided for @cameraClipPreview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get cameraClipPreview;

  /// No description provided for @cameraClipReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get cameraClipReady;

  /// No description provided for @cameraClipRecordingNext.
  ///
  /// In en, this message translates to:
  /// **'Recording the next {seconds} s…'**
  String cameraClipRecordingNext(int seconds);

  /// No description provided for @cameraClipSaving.
  ///
  /// In en, this message translates to:
  /// **'Clip saving…'**
  String get cameraClipSaving;

  /// No description provided for @cameraClipSavingNext.
  ///
  /// In en, this message translates to:
  /// **'Clip saving… {next}'**
  String cameraClipSavingNext(String next);

  /// No description provided for @cameraClipStarting.
  ///
  /// In en, this message translates to:
  /// **'Camera starting…'**
  String get cameraClipStarting;

  /// No description provided for @cameraClipUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Camera unavailable'**
  String get cameraClipUnavailable;

  /// No description provided for @cameraCouldNotOpen.
  ///
  /// In en, this message translates to:
  /// **'Could not open the camera\n{reason}'**
  String cameraCouldNotOpen(String reason);

  /// No description provided for @cameraErrorBlocked.
  ///
  /// In en, this message translates to:
  /// **'Camera access is blocked for this site. Allow the camera in the browser\'s site settings, then retry.'**
  String get cameraErrorBlocked;

  /// No description provided for @cameraErrorDenied.
  ///
  /// In en, this message translates to:
  /// **'Camera permission was denied. Allow it in Settings.'**
  String get cameraErrorDenied;

  /// No description provided for @cameraErrorGeneric.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong while starting the camera.'**
  String get cameraErrorGeneric;

  /// No description provided for @cameraErrorInUse.
  ///
  /// In en, this message translates to:
  /// **'The camera is in use by another app, or couldn\'t start. Close other apps using it, then retry.'**
  String get cameraErrorInUse;

  /// No description provided for @cameraErrorInsecure.
  ///
  /// In en, this message translates to:
  /// **'The camera only works on a secure page. Open Presence over HTTPS.'**
  String get cameraErrorInsecure;

  /// No description provided for @cameraErrorNoneFound.
  ///
  /// In en, this message translates to:
  /// **'No camera was found. Connect one, then retry.'**
  String get cameraErrorNoneFound;

  /// No description provided for @cameraErrorStopped.
  ///
  /// In en, this message translates to:
  /// **'The camera stopped (unplugged or taken away)'**
  String get cameraErrorStopped;

  /// No description provided for @cameraFlip.
  ///
  /// In en, this message translates to:
  /// **'Flip camera'**
  String get cameraFlip;

  /// No description provided for @cameraLiveLabel.
  ///
  /// In en, this message translates to:
  /// **'{device} · live'**
  String cameraLiveLabel(String device);

  /// Camera mode: every device in a grid
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get cameraModeAll;

  /// Camera mode: this device's camera
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get cameraModeNormal;

  /// Camera mode: nothing captured or synced
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get cameraModeStopped;

  /// Camera mode: screen off, still capturing
  ///
  /// In en, this message translates to:
  /// **'Unattended'**
  String get cameraModeUnattended;

  /// No description provided for @cameraNight.
  ///
  /// In en, this message translates to:
  /// **'Night'**
  String get cameraNight;

  /// No description provided for @cameraNightTooltip.
  ///
  /// In en, this message translates to:
  /// **'Night mode: as bright as it goes, and lit while a clip records'**
  String get cameraNightTooltip;

  /// No description provided for @cameraNotFound.
  ///
  /// In en, this message translates to:
  /// **'No camera found'**
  String get cameraNotFound;

  /// No description provided for @cameraOffMessage.
  ///
  /// In en, this message translates to:
  /// **'Camera off\nNothing is recorded until you turn it on.'**
  String get cameraOffMessage;

  /// No description provided for @cameraRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get cameraRetry;

  /// No description provided for @cameraThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get cameraThisDevice;

  /// No description provided for @cameraTurnOn.
  ///
  /// In en, this message translates to:
  /// **'Turn on'**
  String get cameraTurnOn;

  /// No description provided for @clipAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get clipAuto;

  /// No description provided for @clipAutoAllTagged.
  ///
  /// In en, this message translates to:
  /// **'Every subject named before is already on this clip.'**
  String get clipAutoAllTagged;

  /// After a requested recognition run, when the cloud's breeds and coats request failed; {subjects} is the on-device result message.
  ///
  /// In en, this message translates to:
  /// **'{subjects} Cloud recognition didn\'t answer (breeds and coats); try again.'**
  String clipAutoCloudFailed(String subjects);

  /// No description provided for @clipAutoDeferred.
  ///
  /// In en, this message translates to:
  /// **'The phone is low on memory: try again in a moment.'**
  String get clipAutoDeferred;

  /// No description provided for @clipAutoFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t run recognition; try again.'**
  String get clipAutoFailed;

  /// No description provided for @clipAutoFound.
  ///
  /// In en, this message translates to:
  /// **'Found {names}.'**
  String clipAutoFound(String names);

  /// No description provided for @clipAutoLooking.
  ///
  /// In en, this message translates to:
  /// **'Looking for the subjects named before…'**
  String get clipAutoLooking;

  /// No description provided for @clipAutoNoReferences.
  ///
  /// In en, this message translates to:
  /// **'No subjects to look for yet: name someone on another clip first.'**
  String get clipAutoNoReferences;

  /// No description provided for @clipAutoNone.
  ///
  /// In en, this message translates to:
  /// **'No subjects recognized.'**
  String get clipAutoNone;

  /// No description provided for @clipAutoNotSureMany.
  ///
  /// In en, this message translates to:
  /// **'Not sure about {names}: answer the questions in the events.'**
  String clipAutoNotSureMany(String names);

  /// No description provided for @clipAutoNotSureOne.
  ///
  /// In en, this message translates to:
  /// **'Not sure about {names}: answer \"Is this {name}?\" in the events.'**
  String clipAutoNotSureOne(String names, String name);

  /// No description provided for @clipAutoTags.
  ///
  /// In en, this message translates to:
  /// **'{subjects} Tags: {tags}.'**
  String clipAutoTags(String subjects, String tags);

  /// No description provided for @clipAutoTooltip.
  ///
  /// In en, this message translates to:
  /// **'Find the subjects named before, and tag the things seen, on this device'**
  String get clipAutoTooltip;

  /// No description provided for @clipAutoUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not available on this device yet'**
  String get clipAutoUnavailable;

  /// No description provided for @clipAutoUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Recognition is not available on this device yet.'**
  String get clipAutoUnsupported;

  /// No description provided for @clipAutoWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the clip to finish recording…'**
  String get clipAutoWaiting;

  /// No description provided for @clipCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get clipCancel;

  /// No description provided for @clipClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get clipClose;

  /// No description provided for @clipDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get clipDone;

  /// No description provided for @clipFrameTagLabel.
  ///
  /// In en, this message translates to:
  /// **'Frame to name subjects on: click a person or pet to name them'**
  String get clipFrameTagLabel;

  /// No description provided for @clipGrabFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t grab this frame; try again'**
  String get clipGrabFailed;

  /// No description provided for @clipIdentifyHint.
  ///
  /// In en, this message translates to:
  /// **'{label}: click them on the video to name them, or try Auto.'**
  String clipIdentifyHint(String label);

  /// No description provided for @clipNameAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get clipNameAdd;

  /// No description provided for @clipNameFrameHint.
  ///
  /// In en, this message translates to:
  /// **'Name someone on this frame'**
  String get clipNameFrameHint;

  /// No description provided for @clipNameHint.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get clipNameHint;

  /// No description provided for @clipNameMore.
  ///
  /// In en, this message translates to:
  /// **'Name more subjects on this frame'**
  String get clipNameMore;

  /// No description provided for @clipNameSpotHint.
  ///
  /// In en, this message translates to:
  /// **'Who is at the ring?'**
  String get clipNameSpotHint;

  /// No description provided for @clipNameSubject.
  ///
  /// In en, this message translates to:
  /// **'Name subject'**
  String get clipNameSubject;

  /// No description provided for @clipNamesAnd.
  ///
  /// In en, this message translates to:
  /// **'{first} and {last}'**
  String clipNamesAnd(String first, String last);

  /// No description provided for @clipNoSubjects.
  ///
  /// In en, this message translates to:
  /// **'No subjects yet. Click a person or pet on the video to name them.'**
  String get clipNoSubjects;

  /// No description provided for @clipNoTags.
  ///
  /// In en, this message translates to:
  /// **'No tags: nothing was seen on this clip.'**
  String get clipNoTags;

  /// No description provided for @clipNoTagsYet.
  ///
  /// In en, this message translates to:
  /// **'No tags yet. Things seen on the clip, like bottle or bicycle, show here once it has been searched.'**
  String get clipNoTagsYet;

  /// No description provided for @clipNoTagsYetTryAuto.
  ///
  /// In en, this message translates to:
  /// **'No tags yet. Things seen on the clip, like bottle or bicycle, show here once it has been searched (try Auto).'**
  String get clipNoTagsYetTryAuto;

  /// No description provided for @clipNoVideo.
  ///
  /// In en, this message translates to:
  /// **'No video recorded'**
  String get clipNoVideo;

  /// No description provided for @clipNotRecordedClosed.
  ///
  /// In en, this message translates to:
  /// **'Not recorded: the app closed while recording'**
  String get clipNotRecordedClosed;

  /// No description provided for @clipNotSaved.
  ///
  /// In en, this message translates to:
  /// **'{status} · not saved: {error}'**
  String clipNotSaved(String status, String error);

  /// No description provided for @clipPlay.
  ///
  /// In en, this message translates to:
  /// **'Play the clip'**
  String get clipPlay;

  /// No description provided for @clipPreviousOnly.
  ///
  /// In en, this message translates to:
  /// **'Previous {before} s only: the app closed before the next {after} s were recorded'**
  String clipPreviousOnly(int before, int after);

  /// No description provided for @clipPreviousReady.
  ///
  /// In en, this message translates to:
  /// **'Previous {before} s ready · recording next {after} s…'**
  String clipPreviousReady(int before, int after);

  /// No description provided for @clipReady.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s clip ready'**
  String clipReady(int seconds);

  /// No description provided for @clipRecordingElsewhere.
  ///
  /// In en, this message translates to:
  /// **'Recording on another device…'**
  String get clipRecordingElsewhere;

  /// No description provided for @clipRecordingFailed.
  ///
  /// In en, this message translates to:
  /// **'Recording failed'**
  String get clipRecordingFailed;

  /// No description provided for @clipRecordingNext.
  ///
  /// In en, this message translates to:
  /// **'Recording next {after} s…'**
  String clipRecordingNext(int after);

  /// No description provided for @clipRemoveSubject.
  ///
  /// In en, this message translates to:
  /// **'Remove subject'**
  String get clipRemoveSubject;

  /// No description provided for @clipRemoveSubjectFromEvent.
  ///
  /// In en, this message translates to:
  /// **'Remove subject {label} from this event'**
  String clipRemoveSubjectFromEvent(String label);

  /// No description provided for @clipRemoveTagFromEvent.
  ///
  /// In en, this message translates to:
  /// **'Remove tag {label} from this event'**
  String clipRemoveTagFromEvent(String label);

  /// No description provided for @clipRenameSubject.
  ///
  /// In en, this message translates to:
  /// **'Rename subject'**
  String get clipRenameSubject;

  /// No description provided for @clipSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get clipSave;

  /// No description provided for @clipSavingPrevious.
  ///
  /// In en, this message translates to:
  /// **'Saving previous {before} s…'**
  String clipSavingPrevious(int before);

  /// No description provided for @clipShowAt.
  ///
  /// In en, this message translates to:
  /// **'Show at {time}'**
  String clipShowAt(String time);

  /// No description provided for @clipShowEveryEvent.
  ///
  /// In en, this message translates to:
  /// **'Show every event'**
  String get clipShowEveryEvent;

  /// No description provided for @clipShowEveryHold.
  ///
  /// In en, this message translates to:
  /// **'Show every event (hold to rename)'**
  String get clipShowEveryHold;

  /// No description provided for @clipShowOnlyHold.
  ///
  /// In en, this message translates to:
  /// **'Show only events with {name} (hold to rename)'**
  String clipShowOnlyHold(String name);

  /// No description provided for @clipShowOnlyWith.
  ///
  /// In en, this message translates to:
  /// **'Show only events with {label}'**
  String clipShowOnlyWith(String label);

  /// No description provided for @clipSubjects.
  ///
  /// In en, this message translates to:
  /// **'Subjects'**
  String get clipSubjects;

  /// No description provided for @clipTagHint.
  ///
  /// In en, this message translates to:
  /// **'Click where a person or pet is on the picture, then type their name below; or just type the name for this frame (at {time}).'**
  String clipTagHint(String time);

  /// No description provided for @clipTags.
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get clipTags;

  /// No description provided for @clipUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Video clips aren\'t supported on this platform'**
  String get clipUnsupported;

  /// No description provided for @clipWhoIsThis.
  ///
  /// In en, this message translates to:
  /// **'Who is this?'**
  String get clipWhoIsThis;

  /// No description provided for @connectivityAllGood.
  ///
  /// In en, this message translates to:
  /// **'Online · live sync connected'**
  String get connectivityAllGood;

  /// No description provided for @connectivityChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking the connection…'**
  String get connectivityChecking;

  /// No description provided for @connectivityCloudFailed.
  ///
  /// In en, this message translates to:
  /// **'Cloud sync failed'**
  String get connectivityCloudFailed;

  /// No description provided for @connectivityCloudNotSet.
  ///
  /// In en, this message translates to:
  /// **'Cloud sync isn\'t set up in this build'**
  String get connectivityCloudNotSet;

  /// No description provided for @connectivityCloudOn.
  ///
  /// In en, this message translates to:
  /// **'Cloud sync on'**
  String get connectivityCloudOn;

  /// No description provided for @connectivityCloudOneSide.
  ///
  /// In en, this message translates to:
  /// **'Cloud sync is set up on one side only'**
  String get connectivityCloudOneSide;

  /// No description provided for @connectivityFree.
  ///
  /// In en, this message translates to:
  /// **'Free: devices sync over live sync'**
  String get connectivityFree;

  /// No description provided for @connectivityLabel.
  ///
  /// In en, this message translates to:
  /// **'Connectivity: {headline}'**
  String connectivityLabel(String headline);

  /// No description provided for @connectivityLiveConnected.
  ///
  /// In en, this message translates to:
  /// **'Live sync connected'**
  String get connectivityLiveConnected;

  /// No description provided for @connectivityLiveConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to live sync…'**
  String get connectivityLiveConnecting;

  /// No description provided for @connectivityLiveFailed.
  ///
  /// In en, this message translates to:
  /// **'Live sync failed'**
  String get connectivityLiveFailed;

  /// No description provided for @connectivityLiveIdle.
  ///
  /// In en, this message translates to:
  /// **'Live sync idle · next in {next}'**
  String connectivityLiveIdle(String next);

  /// No description provided for @connectivityLiveNotSet.
  ///
  /// In en, this message translates to:
  /// **'Live sync isn\'t set up in this build'**
  String get connectivityLiveNotSet;

  /// No description provided for @connectivityLiveOff.
  ///
  /// In en, this message translates to:
  /// **'Live sync is off'**
  String get connectivityLiveOff;

  /// No description provided for @connectivityLiveOnceSynced.
  ///
  /// In en, this message translates to:
  /// **'Live sync connects once synced'**
  String get connectivityLiveOnceSynced;

  /// No description provided for @connectivityNote.
  ///
  /// In en, this message translates to:
  /// **'Other devices see this one live only while live sync is connected.'**
  String get connectivityNote;

  /// No description provided for @connectivityOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline: can\'t reach the server'**
  String get connectivityOffline;

  /// No description provided for @connectivityOnline.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get connectivityOnline;

  /// No description provided for @connectivityPresenceAnswered.
  ///
  /// In en, this message translates to:
  /// **'Live — answered {since}'**
  String connectivityPresenceAnswered(String since);

  /// No description provided for @connectivityPresenceLastSeen.
  ///
  /// In en, this message translates to:
  /// **'Last seen {since}{unavailable}'**
  String connectivityPresenceLastSeen(String since, String unavailable);

  /// No description provided for @connectivityPresenceNever.
  ///
  /// In en, this message translates to:
  /// **'Never seen{unavailable}'**
  String connectivityPresenceNever(String unavailable);

  /// No description provided for @connectivityPresenceThisLive.
  ///
  /// In en, this message translates to:
  /// **'Live — this device, connected to live sync'**
  String get connectivityPresenceThisLive;

  /// No description provided for @connectivityPresenceThisNotConnected.
  ///
  /// In en, this message translates to:
  /// **'This device — not connected to live sync now'**
  String get connectivityPresenceThisNotConnected;

  /// No description provided for @connectivityPresenceThisUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This device — live status unavailable'**
  String get connectivityPresenceThisUnavailable;

  /// Appended to a device's presence; starts with a space
  ///
  /// In en, this message translates to:
  /// **' · live status unavailable'**
  String get connectivityPresenceUnavailable;

  /// No description provided for @connectivityThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device — {headline}'**
  String connectivityThisDevice(String headline);

  /// No description provided for @consentAgree.
  ///
  /// In en, this message translates to:
  /// **'I agree'**
  String get consentAgree;

  /// GDPR: the EU General Data Protection Regulation (RGPD in Spanish)
  ///
  /// In en, this message translates to:
  /// **'Under the GDPR, faces used to identify people, as when naming them in clips, need care: clear consent, safe keeping, and deleting on request.'**
  String get consentBiometricsDetail;

  /// No description provided for @consentBiometricsTitle.
  ///
  /// In en, this message translates to:
  /// **'Faces are biometric data, and I am responsible.'**
  String get consentBiometricsTitle;

  /// No description provided for @consentFootnote.
  ///
  /// In en, this message translates to:
  /// **'Asked once on this device. Not legal advice.'**
  String get consentFootnote;

  /// No description provided for @consentIntro.
  ///
  /// In en, this message translates to:
  /// **'By continuing, you confirm:'**
  String get consentIntro;

  /// No description provided for @consentRightDetail.
  ///
  /// In en, this message translates to:
  /// **'I own or manage this place, or have permission, and people who may be filmed know about it.'**
  String get consentRightDetail;

  /// No description provided for @consentRightTitle.
  ///
  /// In en, this message translates to:
  /// **'I have the right to record here.'**
  String get consentRightTitle;

  /// No description provided for @consentTitle.
  ///
  /// In en, this message translates to:
  /// **'Before Presence starts recording'**
  String get consentTitle;

  /// No description provided for @devModeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Development mode: sign-in isn\'t configured, so everything is open to everyone.'**
  String get devModeTooltip;

  /// No description provided for @devModeTooltipVersion.
  ///
  /// In en, this message translates to:
  /// **'Development mode, version {version}: sign-in isn\'t configured, so everything is open to everyone.'**
  String devModeTooltipVersion(String version);

  /// No description provided for @eventAlreadyDeleted.
  ///
  /// In en, this message translates to:
  /// **'Event already deleted'**
  String get eventAlreadyDeleted;

  /// No description provided for @eventCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get eventCancel;

  /// No description provided for @eventCloudArchived.
  ///
  /// In en, this message translates to:
  /// **'Archived in the cloud (not on this device)'**
  String get eventCloudArchived;

  /// No description provided for @eventCloudDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get eventCloudDelete;

  /// No description provided for @eventCloudDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'Its recording, thumbnail and tags are deleted from the cloud. This device won\'t upload it again unless you put it back.'**
  String get eventCloudDeleteBody;

  /// No description provided for @eventCloudDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t delete it from the cloud'**
  String get eventCloudDeleteFailed;

  /// No description provided for @eventCloudDeleteOnlyCopy.
  ///
  /// In en, this message translates to:
  /// **'This device doesn\'t hold a full copy: unless another device does, it\'s gone for good.'**
  String get eventCloudDeleteOnlyCopy;

  /// No description provided for @eventCloudDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete from the cloud?'**
  String get eventCloudDeleteTitle;

  /// No description provided for @eventCloudDeleted.
  ///
  /// In en, this message translates to:
  /// **'Deleted from the cloud'**
  String get eventCloudDeleted;

  /// No description provided for @eventCloudNotSynced.
  ///
  /// In en, this message translates to:
  /// **'Not in the cloud'**
  String get eventCloudNotSynced;

  /// No description provided for @eventCloudPutFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t put it in the cloud: that takes a premium profile and a full copy on this device.'**
  String get eventCloudPutFailed;

  /// No description provided for @eventCloudPutting.
  ///
  /// In en, this message translates to:
  /// **'Putting it in the cloud…'**
  String get eventCloudPutting;

  /// No description provided for @eventCloudSynced.
  ///
  /// In en, this message translates to:
  /// **'In the cloud'**
  String get eventCloudSynced;

  /// No description provided for @eventCloudTapToDelete.
  ///
  /// In en, this message translates to:
  /// **'Tap to delete it from the cloud'**
  String get eventCloudTapToDelete;

  /// No description provided for @eventCloudTapToPut.
  ///
  /// In en, this message translates to:
  /// **'Tap to put it in the cloud'**
  String get eventCloudTapToPut;

  /// No description provided for @eventCopies.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 copy} other{{count} copies}}'**
  String eventCopies(int count);

  /// No description provided for @eventCopiesCloud.
  ///
  /// In en, this message translates to:
  /// **'Cloud'**
  String get eventCopiesCloud;

  /// No description provided for @eventCopiesLiveOff.
  ///
  /// In en, this message translates to:
  /// **'Live sync is off: other devices\' copies are unknown'**
  String get eventCopiesLiveOff;

  /// No description provided for @eventCopiesNone.
  ///
  /// In en, this message translates to:
  /// **'No copy known'**
  String get eventCopiesNone;

  /// No description provided for @eventCopiesNotSynced.
  ///
  /// In en, this message translates to:
  /// **'Not synced'**
  String get eventCopiesNotSynced;

  /// No description provided for @eventCopiesOnDevices.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{On no device} =1{On 1 device} other{On {count} devices}}'**
  String eventCopiesOnDevices(int count);

  /// No description provided for @eventCopiesShareFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach the other devices: live sync is off or not connected'**
  String get eventCopiesShareFailed;

  /// No description provided for @eventCopiesSharing.
  ///
  /// In en, this message translates to:
  /// **'Asked the other devices to take a copy'**
  String get eventCopiesSharing;

  /// No description provided for @eventCopiesTapToShare.
  ///
  /// In en, this message translates to:
  /// **'Tap to sync a copy to every device'**
  String get eventCopiesTapToShare;

  /// No description provided for @eventCopiesThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get eventCopiesThisDevice;

  /// No description provided for @eventDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete event'**
  String get eventDelete;

  /// No description provided for @eventDeleteClipNote.
  ///
  /// In en, this message translates to:
  /// **'Its clip stays in the cloud until it expires.'**
  String get eventDeleteClipNote;

  /// No description provided for @eventDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get eventDeleteConfirm;

  /// No description provided for @eventDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not delete the event'**
  String get eventDeleteFailed;

  /// No description provided for @eventDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete this event? It will be hidden on every device.'**
  String get eventDeleteMessage;

  /// No description provided for @eventDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete event?'**
  String get eventDeleteTitle;

  /// No description provided for @eventDeletedEverywhere.
  ///
  /// In en, this message translates to:
  /// **'Event deleted on every device'**
  String get eventDeletedEverywhere;

  /// No description provided for @eventDetailCaptureAll.
  ///
  /// In en, this message translates to:
  /// **'Every device takes a clip'**
  String get eventDetailCaptureAll;

  /// No description provided for @eventDetailClipMissing.
  ///
  /// In en, this message translates to:
  /// **'Clip recording missing'**
  String get eventDetailClipMissing;

  /// No description provided for @eventDetailSure.
  ///
  /// In en, this message translates to:
  /// **'{percent} % sure'**
  String eventDetailSure(int percent);

  /// No description provided for @eventDevice.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get eventDevice;

  /// No description provided for @eventDeviceUnknown.
  ///
  /// In en, this message translates to:
  /// **'Device unknown'**
  String get eventDeviceUnknown;

  /// No description provided for @eventFlagIdentify.
  ///
  /// In en, this message translates to:
  /// **'{label} · Identify'**
  String eventFlagIdentify(String label);

  /// No description provided for @eventFlagUnidentified.
  ///
  /// In en, this message translates to:
  /// **'Unidentified subject'**
  String get eventFlagUnidentified;

  /// No description provided for @eventFlagUnidentifiedTooltip.
  ///
  /// In en, this message translates to:
  /// **'Unidentified subject — identify'**
  String get eventFlagUnidentifiedTooltip;

  /// No description provided for @eventLocationDevice.
  ///
  /// In en, this message translates to:
  /// **'The device\'s position'**
  String get eventLocationDevice;

  /// No description provided for @eventLocationMap.
  ///
  /// In en, this message translates to:
  /// **'Set on the map'**
  String get eventLocationMap;

  /// No description provided for @eventLocationPinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get eventLocationPinned;

  /// No description provided for @eventNoLocation.
  ///
  /// In en, this message translates to:
  /// **'No location for this event'**
  String get eventNoLocation;

  /// No description provided for @eventOsUnknown.
  ///
  /// In en, this message translates to:
  /// **'Operating system unknown'**
  String get eventOsUnknown;

  /// No description provided for @eventRecognitionComplete.
  ///
  /// In en, this message translates to:
  /// **'Recognition ran in full'**
  String get eventRecognitionComplete;

  /// No description provided for @eventRecognitionFailed.
  ///
  /// In en, this message translates to:
  /// **'Recognition failed: {reason}'**
  String eventRecognitionFailed(String reason);

  /// No description provided for @eventRecognitionNotRun.
  ///
  /// In en, this message translates to:
  /// **'Recognition hasn\'t run'**
  String get eventRecognitionNotRun;

  /// No description provided for @eventRecognitionPartial.
  ///
  /// In en, this message translates to:
  /// **'Recognition ran in part'**
  String get eventRecognitionPartial;

  /// No description provided for @eventRecognitionRerunning.
  ///
  /// In en, this message translates to:
  /// **'Running recognition…'**
  String get eventRecognitionRerunning;

  /// No description provided for @eventRecognitionTapToRerun.
  ///
  /// In en, this message translates to:
  /// **'Tap to run recognition'**
  String get eventRecognitionTapToRerun;

  /// No description provided for @eventSubjectsAllTagged.
  ///
  /// In en, this message translates to:
  /// **'People and pets: everyone known is already named'**
  String get eventSubjectsAllTagged;

  /// No description provided for @eventSubjectsFound.
  ///
  /// In en, this message translates to:
  /// **'People and pets: {names}'**
  String eventSubjectsFound(String names);

  /// No description provided for @eventSubjectsNoReferences.
  ///
  /// In en, this message translates to:
  /// **'People and pets: no one named yet to look for'**
  String get eventSubjectsNoReferences;

  /// No description provided for @eventSubjectsNone.
  ///
  /// In en, this message translates to:
  /// **'People and pets: searched, no one recognized'**
  String get eventSubjectsNone;

  /// No description provided for @eventSubjectsNotSearched.
  ///
  /// In en, this message translates to:
  /// **'People and pets: not searched'**
  String get eventSubjectsNotSearched;

  /// No description provided for @eventSuggestionClipMissing.
  ///
  /// In en, this message translates to:
  /// **'The clip is missing'**
  String get eventSuggestionClipMissing;

  /// No description provided for @eventSuggestionNo.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get eventSuggestionNo;

  /// No description provided for @eventSuggestionNot.
  ///
  /// In en, this message translates to:
  /// **'Not {name}'**
  String eventSuggestionNot(String name);

  /// No description provided for @eventSuggestionTagged.
  ///
  /// In en, this message translates to:
  /// **'Tagged as {name}'**
  String eventSuggestionTagged(String name);

  /// No description provided for @eventSuggestionYes.
  ///
  /// In en, this message translates to:
  /// **'Yes, it\'s {name}'**
  String eventSuggestionYes(String name);

  /// No description provided for @eventTagsFound.
  ///
  /// In en, this message translates to:
  /// **'Object tags: {labels}'**
  String eventTagsFound(String labels);

  /// No description provided for @eventTagsNone.
  ///
  /// In en, this message translates to:
  /// **'Object tags: searched, nothing seen'**
  String get eventTagsNone;

  /// No description provided for @eventTagsNotSearched.
  ///
  /// In en, this message translates to:
  /// **'Object tags: not searched'**
  String get eventTagsNotSearched;

  /// No description provided for @eventThisDevice.
  ///
  /// In en, this message translates to:
  /// **'this device'**
  String get eventThisDevice;

  /// No description provided for @eventTitleAppStarted.
  ///
  /// In en, this message translates to:
  /// **'Application started'**
  String get eventTitleAppStarted;

  /// No description provided for @eventTitleCaptureAll.
  ///
  /// In en, this message translates to:
  /// **'Capture all'**
  String get eventTitleCaptureAll;

  /// No description provided for @eventTitleClipRequested.
  ///
  /// In en, this message translates to:
  /// **'Clip requested'**
  String get eventTitleClipRequested;

  /// No description provided for @eventTitleConsentGiven.
  ///
  /// In en, this message translates to:
  /// **'Recording consent given'**
  String get eventTitleConsentGiven;

  /// No description provided for @eventTitleGeneric.
  ///
  /// In en, this message translates to:
  /// **'Event'**
  String get eventTitleGeneric;

  /// No description provided for @eventTitleIsThis.
  ///
  /// In en, this message translates to:
  /// **'Is this {name}?'**
  String eventTitleIsThis(String name);

  /// No description provided for @eventTitleMotion.
  ///
  /// In en, this message translates to:
  /// **'Motion detected'**
  String get eventTitleMotion;

  /// No description provided for @eventTitleScheduled.
  ///
  /// In en, this message translates to:
  /// **'Scheduled clip'**
  String get eventTitleScheduled;

  /// No description provided for @eventTitleSignedIn.
  ///
  /// In en, this message translates to:
  /// **'Signed in'**
  String get eventTitleSignedIn;

  /// No description provided for @eventTitleSignedOut.
  ///
  /// In en, this message translates to:
  /// **'Signed out'**
  String get eventTitleSignedOut;

  /// No description provided for @eventTitleStartup.
  ///
  /// In en, this message translates to:
  /// **'Startup clip'**
  String get eventTitleStartup;

  /// No description provided for @eventWhere.
  ///
  /// In en, this message translates to:
  /// **'Where'**
  String get eventWhere;

  /// No description provided for @eventsCountTooltip.
  ///
  /// In en, this message translates to:
  /// **'{shown} of {all} events shown'**
  String eventsCountTooltip(int shown, int all);

  /// No description provided for @eventsDeleteAll.
  ///
  /// In en, this message translates to:
  /// **'Delete the events shown'**
  String get eventsDeleteAll;

  /// No description provided for @eventsDeleteAllClipNote.
  ///
  /// In en, this message translates to:
  /// **'Their clips stay in the cloud until they expire.'**
  String get eventsDeleteAllClipNote;

  /// No description provided for @eventsDeleteAllMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete all the events shown? They will be hidden on every device.'**
  String get eventsDeleteAllMessage;

  /// No description provided for @eventsDeleteAllTitle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete 1 event?} other{Delete {count} events?}}'**
  String eventsDeleteAllTitle(int count);

  /// No description provided for @eventsDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not delete the events'**
  String get eventsDeleteFailed;

  /// No description provided for @eventsDeletedEverywhere.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No events deleted} =1{1 event deleted on every device} other{{count} events deleted on every device}}'**
  String eventsDeletedEverywhere(int count);

  /// No description provided for @eventsHideSystem.
  ///
  /// In en, this message translates to:
  /// **'Hide system events'**
  String get eventsHideSystem;

  /// No description provided for @eventsNoGrabs.
  ///
  /// In en, this message translates to:
  /// **'No grabs yet: system events are hidden'**
  String get eventsNoGrabs;

  /// No description provided for @eventsNoMatch.
  ///
  /// In en, this message translates to:
  /// **'No events match \"{query}\"'**
  String eventsNoMatch(String query);

  /// No description provided for @eventsNone.
  ///
  /// In en, this message translates to:
  /// **'No events'**
  String get eventsNone;

  /// No description provided for @eventsSearch.
  ///
  /// In en, this message translates to:
  /// **'Search events'**
  String get eventsSearch;

  /// No description provided for @eventsSearchClear.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get eventsSearchClear;

  /// No description provided for @eventsShowDevice.
  ///
  /// In en, this message translates to:
  /// **'Show this device\'s events'**
  String get eventsShowDevice;

  /// No description provided for @eventsShowEveryDevice.
  ///
  /// In en, this message translates to:
  /// **'Show every device\'s events'**
  String get eventsShowEveryDevice;

  /// No description provided for @eventsShowSystem.
  ///
  /// In en, this message translates to:
  /// **'Show system events'**
  String get eventsShowSystem;

  /// No description provided for @feedbackAdmin.
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get feedbackAdmin;

  /// No description provided for @feedbackAnswered.
  ///
  /// In en, this message translates to:
  /// **'Answered'**
  String get feedbackAnswered;

  /// No description provided for @feedbackAwaitingReply.
  ///
  /// In en, this message translates to:
  /// **'Awaiting a reply'**
  String get feedbackAwaitingReply;

  /// No description provided for @feedbackMember.
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get feedbackMember;

  /// No description provided for @feedbackReply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get feedbackReply;

  /// No description provided for @feedbackSendFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t send it ({error}).'**
  String feedbackSendFailed(String error);

  /// No description provided for @feedbackSentTooMuch.
  ///
  /// In en, this message translates to:
  /// **'You\'ve sent a lot today. Try again tomorrow.'**
  String get feedbackSentTooMuch;

  /// No description provided for @feedbackTeam.
  ///
  /// In en, this message translates to:
  /// **'Presence team'**
  String get feedbackTeam;

  /// No description provided for @feedbackTooManyTries.
  ///
  /// In en, this message translates to:
  /// **'Too many tries. Wait a minute.'**
  String get feedbackTooManyTries;

  /// No description provided for @feedbackYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get feedbackYou;

  /// No description provided for @healthApiAnswered.
  ///
  /// In en, this message translates to:
  /// **'Auth API: answered ({mode} mode)'**
  String healthApiAnswered(String mode);

  /// No description provided for @healthApiChecking.
  ///
  /// In en, this message translates to:
  /// **'Auth API: checking'**
  String get healthApiChecking;

  /// No description provided for @healthApiUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Auth API: unreachable ({error})'**
  String healthApiUnreachable(String error);

  /// Health card title
  ///
  /// In en, this message translates to:
  /// **'Auth API'**
  String get healthAuthApiName;

  /// No description provided for @healthAwsOff.
  ///
  /// In en, this message translates to:
  /// **'events stay on this device'**
  String get healthAwsOff;

  /// No description provided for @healthAwsSet.
  ///
  /// In en, this message translates to:
  /// **'AWS: set; syncs once signed in'**
  String get healthAwsSet;

  /// No description provided for @healthAwsSyncFailed.
  ///
  /// In en, this message translates to:
  /// **'AWS: sync failed ({error})'**
  String healthAwsSyncFailed(String error);

  /// No description provided for @healthAwsSynced.
  ///
  /// In en, this message translates to:
  /// **'AWS: synced'**
  String get healthAwsSynced;

  /// No description provided for @healthAwsSyncing.
  ///
  /// In en, this message translates to:
  /// **'AWS: syncing'**
  String get healthAwsSyncing;

  /// No description provided for @healthChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get healthChecking;

  /// No description provided for @healthChecks.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 check} other{{count} checks}}'**
  String healthChecks(int count);

  /// No description provided for @healthDevicesHere.
  ///
  /// In en, this message translates to:
  /// **'In the events on this device'**
  String get healthDevicesHere;

  /// No description provided for @healthDevicesProfile.
  ///
  /// In en, this message translates to:
  /// **'In the profile\'s events'**
  String get healthDevicesProfile;

  /// No description provided for @healthDevicesSemantics.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 device in the events} other{{count} devices in the events}}'**
  String healthDevicesSemantics(int count);

  /// No description provided for @healthDevicesTitle.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get healthDevicesTitle;

  /// No description provided for @healthDevicesTooltip.
  ///
  /// In en, this message translates to:
  /// **'{what}, here and synced from the cloud'**
  String healthDevicesTooltip(String what);

  /// No description provided for @healthLastUpdate.
  ///
  /// In en, this message translates to:
  /// **'Last update {time}'**
  String healthLastUpdate(String time);

  /// No description provided for @healthLiveConnected.
  ///
  /// In en, this message translates to:
  /// **'Live: connected ({counts})'**
  String healthLiveConnected(String counts);

  /// No description provided for @healthLiveConnecting.
  ///
  /// In en, this message translates to:
  /// **'Live: connecting'**
  String get healthLiveConnecting;

  /// No description provided for @healthLiveCounts.
  ///
  /// In en, this message translates to:
  /// **'{received} received, {sent} sent'**
  String healthLiveCounts(int received, int sent);

  /// No description provided for @healthLiveFailed.
  ///
  /// In en, this message translates to:
  /// **'Live: failed ({error}); events arrive with each sync'**
  String healthLiveFailed(String error);

  /// No description provided for @healthLiveIdle.
  ///
  /// In en, this message translates to:
  /// **'Live: idle · next in {next} ({mode}; {counts})'**
  String healthLiveIdle(String next, String mode, String counts);

  /// Health card title: live sync
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get healthLiveName;

  /// No description provided for @healthLiveNever.
  ///
  /// In en, this message translates to:
  /// **'Live: off (Never); events arrive with each sync (15 s)'**
  String get healthLiveNever;

  /// No description provided for @healthLiveNotSet.
  ///
  /// In en, this message translates to:
  /// **'Live: not set; events arrive with each sync (15 s)'**
  String get healthLiveNotSet;

  /// No description provided for @healthLiveOff.
  ///
  /// In en, this message translates to:
  /// **'Live: set; connects once synced'**
  String get healthLiveOff;

  /// No description provided for @healthMinutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String healthMinutes(int minutes);

  /// No description provided for @healthOidcOff.
  ///
  /// In en, this message translates to:
  /// **'sign-in is off'**
  String get healthOidcOff;

  /// No description provided for @healthOidcSet.
  ///
  /// In en, this message translates to:
  /// **'OIDC: Google sign-in set'**
  String get healthOidcSet;

  /// No description provided for @healthRbacrDev.
  ///
  /// In en, this message translates to:
  /// **'RBACR: not used in DEV mode (nobody signs in)'**
  String get healthRbacrDev;

  /// No description provided for @healthRbacrFree.
  ///
  /// In en, this message translates to:
  /// **'RBACR: set; this profile is Free (its devices sync with each other)'**
  String get healthRbacrFree;

  /// No description provided for @healthRbacrMissing.
  ///
  /// In en, this message translates to:
  /// **'RBACR: not set on the auth API; nobody who signs in has a role'**
  String get healthRbacrMissing;

  /// No description provided for @healthRbacrPremium.
  ///
  /// In en, this message translates to:
  /// **'RBACR: set; this profile is Premium (cloud backup)'**
  String get healthRbacrPremium;

  /// No description provided for @healthRbacrSet.
  ///
  /// In en, this message translates to:
  /// **'RBACR: set; gives the roles'**
  String get healthRbacrSet;

  /// No description provided for @healthRbacrUnknown.
  ///
  /// In en, this message translates to:
  /// **'RBACR: the auth API doesn\'t say'**
  String get healthRbacrUnknown;

  /// No description provided for @healthRunFailed.
  ///
  /// In en, this message translates to:
  /// **'failed'**
  String get healthRunFailed;

  /// No description provided for @healthRunPassed.
  ///
  /// In en, this message translates to:
  /// **'all passed'**
  String get healthRunPassed;

  /// No description provided for @healthSeconds.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s'**
  String healthSeconds(int seconds);

  /// No description provided for @healthSettingNotInBuild.
  ///
  /// In en, this message translates to:
  /// **'{name}: not set in this build; {off}'**
  String healthSettingNotInBuild(String name, String off);

  /// No description provided for @healthSettingNotSet.
  ///
  /// In en, this message translates to:
  /// **'{name}: not set; {off}'**
  String healthSettingNotSet(String name, String off);

  /// No description provided for @healthSettingOnlyApi.
  ///
  /// In en, this message translates to:
  /// **'{name}: set in the auth API but not in this build; {off}'**
  String healthSettingOnlyApi(String name, String off);

  /// No description provided for @healthSettingOnlyBuild.
  ///
  /// In en, this message translates to:
  /// **'{name}: set in this build but not in the auth API'**
  String healthSettingOnlyBuild(String name);

  /// No description provided for @healthTapForDetails.
  ///
  /// In en, this message translates to:
  /// **'Tap for details.'**
  String get healthTapForDetails;

  /// No description provided for @healthTimeline.
  ///
  /// In en, this message translates to:
  /// **'Timeline'**
  String get healthTimeline;

  /// No description provided for @healthTimelineSummary.
  ///
  /// In en, this message translates to:
  /// **'{checks} · every {interval}'**
  String healthTimelineSummary(String checks, String interval);

  /// No description provided for @healthTitle.
  ///
  /// In en, this message translates to:
  /// **'Health'**
  String get healthTitle;

  /// No description provided for @healthToneChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking'**
  String get healthToneChecking;

  /// No description provided for @healthToneFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get healthToneFailed;

  /// No description provided for @healthToneIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get healthToneIdle;

  /// No description provided for @healthToneMismatch.
  ///
  /// In en, this message translates to:
  /// **'Mismatch'**
  String get healthToneMismatch;

  /// No description provided for @healthToneOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get healthToneOff;

  /// No description provided for @healthToneOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get healthToneOk;

  /// No description provided for @healthToneSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing'**
  String get healthToneSyncing;

  /// No description provided for @healthUnknownError.
  ///
  /// In en, this message translates to:
  /// **'unknown error'**
  String get healthUnknownError;

  /// No description provided for @healthWarningFailed.
  ///
  /// In en, this message translates to:
  /// **'Health check failed'**
  String get healthWarningFailed;

  /// No description provided for @helpIntro.
  ///
  /// In en, this message translates to:
  /// **'Questions, ideas or something not working? Send a message; an administrator will answer here.'**
  String get helpIntro;

  /// No description provided for @helpLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load messages ({error}).'**
  String helpLoadFailed(String error);

  /// No description provided for @helpMessage.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get helpMessage;

  /// No description provided for @helpNoMessages.
  ///
  /// In en, this message translates to:
  /// **'No messages yet.'**
  String get helpNoMessages;

  /// No description provided for @helpNotSignedIn.
  ///
  /// In en, this message translates to:
  /// **'Not signed in.'**
  String get helpNotSignedIn;

  /// No description provided for @helpReload.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get helpReload;

  /// No description provided for @helpSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get helpSend;

  /// No description provided for @helpTitle.
  ///
  /// In en, this message translates to:
  /// **'Write to the Presence team'**
  String get helpTitle;

  /// Message after opening the All grid
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Asked every device for a fresh grab} =1{Asked 1 device for a fresh grab…} other{Asked {count} devices for a fresh grab…}}'**
  String homeAskedGrabs(int count);

  /// No description provided for @homeBatteryCharging.
  ///
  /// In en, this message translates to:
  /// **'charging'**
  String get homeBatteryCharging;

  /// No description provided for @homeBatteryFull.
  ///
  /// In en, this message translates to:
  /// **'full'**
  String get homeBatteryFull;

  /// No description provided for @homeBatteryLevel.
  ///
  /// In en, this message translates to:
  /// **'Battery {level} %'**
  String homeBatteryLevel(int level);

  /// No description provided for @homeBatteryOnBattery.
  ///
  /// In en, this message translates to:
  /// **'on battery'**
  String get homeBatteryOnBattery;

  /// No description provided for @homeBatteryPlugged.
  ///
  /// In en, this message translates to:
  /// **'plugged in, not charging'**
  String get homeBatteryPlugged;

  /// No description provided for @homeBatteryTemperature.
  ///
  /// In en, this message translates to:
  /// **'Battery temperature {temperature}'**
  String homeBatteryTemperature(String temperature);

  /// No description provided for @homeBatteryTemperatureHot.
  ///
  /// In en, this message translates to:
  /// **'Battery temperature {temperature}, hot'**
  String homeBatteryTemperatureHot(String temperature);

  /// No description provided for @homeClipAll.
  ///
  /// In en, this message translates to:
  /// **'Capture all'**
  String get homeClipAll;

  /// No description provided for @homeClipManual.
  ///
  /// In en, this message translates to:
  /// **'Clip started'**
  String get homeClipManual;

  /// No description provided for @homeClipMotion.
  ///
  /// In en, this message translates to:
  /// **'Motion detected'**
  String get homeClipMotion;

  /// No description provided for @homeClipSaving.
  ///
  /// In en, this message translates to:
  /// **'{started} · saving the next {seconds} s'**
  String homeClipSaving(String started, int seconds);

  /// No description provided for @homeClipScheduled.
  ///
  /// In en, this message translates to:
  /// **'Scheduled clip'**
  String get homeClipScheduled;

  /// No description provided for @homeClipStartup.
  ///
  /// In en, this message translates to:
  /// **'Startup clip'**
  String get homeClipStartup;

  /// No description provided for @homeJoinedAccount.
  ///
  /// In en, this message translates to:
  /// **'This device is now one of {email}\'s: {deviceId}'**
  String homeJoinedAccount(String email, String deviceId);

  /// No description provided for @homeJoinedOpen.
  ///
  /// In en, this message translates to:
  /// **'Presence is open on this device: {deviceId}'**
  String homeJoinedOpen(String deviceId);

  /// Screen reader label of a message pill that opens its event
  ///
  /// In en, this message translates to:
  /// **'{label}. Tap to view it.'**
  String homeMessageTapToView(String label);

  /// No description provided for @homeScreenOffHint.
  ///
  /// In en, this message translates to:
  /// **'Unattended: capturing with the screen off. Tap to wake.'**
  String get homeScreenOffHint;

  /// No description provided for @homeSignInFailed.
  ///
  /// In en, this message translates to:
  /// **'Sign-in failed: {error}'**
  String homeSignInFailed(String error);

  /// No description provided for @homeUnattendedWoken.
  ///
  /// In en, this message translates to:
  /// **'Unattended: dark again 15 s after the last touch'**
  String get homeUnattendedWoken;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageLabel.
  ///
  /// In en, this message translates to:
  /// **'App language'**
  String get languageLabel;

  /// No description provided for @languageNote.
  ///
  /// In en, this message translates to:
  /// **'Names, tags and device IDs show as they were written.'**
  String get languageNote;

  /// No description provided for @languagePortuguese.
  ///
  /// In en, this message translates to:
  /// **'Português'**
  String get languagePortuguese;

  /// Settings: the language section's title
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageSection;

  /// No description provided for @languageSpanish.
  ///
  /// In en, this message translates to:
  /// **'Español'**
  String get languageSpanish;

  /// Language choice: follow the device's language
  ///
  /// In en, this message translates to:
  /// **'Same as the device'**
  String get languageSystem;

  /// No description provided for @legalPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get legalPrivacy;

  /// No description provided for @legalTerms.
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get legalTerms;

  /// No description provided for @logClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get logClear;

  /// No description provided for @logCopied.
  ///
  /// In en, this message translates to:
  /// **'Log copied'**
  String get logCopied;

  /// No description provided for @logCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get logCopy;

  /// No description provided for @logEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing logged yet.'**
  String get logEmpty;

  /// No description provided for @logTitle.
  ///
  /// In en, this message translates to:
  /// **'Log'**
  String get logTitle;

  /// No description provided for @logTitleCount.
  ///
  /// In en, this message translates to:
  /// **'Log · {count} latest'**
  String logTitleCount(int count);

  /// No description provided for @maintenanceBody.
  ///
  /// In en, this message translates to:
  /// **'We\'ll be back soon. This page comes back on its own.'**
  String get maintenanceBody;

  /// No description provided for @maintenanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Sorry, Presence is down for maintenance.'**
  String get maintenanceTitle;

  /// No description provided for @monitoringSyncAsked.
  ///
  /// In en, this message translates to:
  /// **'Syncing: this device now, and the others were asked to'**
  String get monitoringSyncAsked;

  /// No description provided for @monitoringSyncHere.
  ///
  /// In en, this message translates to:
  /// **'Syncing this device now; the others couldn\'t be asked (live sync is off or offline)'**
  String get monitoringSyncHere;

  /// No description provided for @monitoringSyncTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sync all devices'**
  String get monitoringSyncTooltip;

  /// Navigation bar: the Admin tab
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get navAdmin;

  /// Navigation bar: the Camera tab
  ///
  /// In en, this message translates to:
  /// **'Cams'**
  String get navCamera;

  /// Navigation bar: the Help tab
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get navHelp;

  /// App bar title of the Help tab
  ///
  /// In en, this message translates to:
  /// **'Feedback & Help'**
  String get navHelpTitle;

  /// Navigation bar: the Log tab
  ///
  /// In en, this message translates to:
  /// **'Log'**
  String get navLog;

  /// Navigation bar: the Monitoring tab
  ///
  /// In en, this message translates to:
  /// **'Events'**
  String get navMonitoring;

  /// Navigation bar: the Profile tab
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get navProfile;

  /// Navigation bar: the Settings tab
  ///
  /// In en, this message translates to:
  /// **'Setup'**
  String get navSettings;

  /// Profile tab tooltip
  ///
  /// In en, this message translates to:
  /// **'Signed in as {identity}'**
  String navSignedInAs(String identity);

  /// No description provided for @settingsAddDeviceCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get settingsAddDeviceCopy;

  /// No description provided for @settingsAddDeviceLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied'**
  String get settingsAddDeviceLinkCopied;

  /// No description provided for @settingsAddDeviceQr.
  ///
  /// In en, this message translates to:
  /// **'QR code for {link}'**
  String settingsAddDeviceQr(String link);

  /// No description provided for @settingsAddDeviceScan.
  ///
  /// In en, this message translates to:
  /// **'Scan with another device to open Presence there. It becomes a new device, with its own ID.'**
  String get settingsAddDeviceScan;

  /// No description provided for @settingsAddDeviceScanAs.
  ///
  /// In en, this message translates to:
  /// **'Scan with another device to open Presence there as {email}. It becomes a new device, with its own ID.'**
  String settingsAddDeviceScanAs(String email);

  /// No description provided for @settingsAddDeviceShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get settingsAddDeviceShare;

  /// No description provided for @settingsAddDeviceShareTitle.
  ///
  /// In en, this message translates to:
  /// **'Open Presence'**
  String get settingsAddDeviceShareTitle;

  /// No description provided for @settingsAddDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Add a device'**
  String get settingsAddDeviceTitle;

  /// No description provided for @settingsAdvancedSection.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get settingsAdvancedSection;

  /// No description provided for @settingsAskNote.
  ///
  /// In en, this message translates to:
  /// **'Less sure than that, it asks you whether it\'s them.'**
  String get settingsAskNote;

  /// No description provided for @settingsAutoTag.
  ///
  /// In en, this message translates to:
  /// **'Tag automatically when at least'**
  String get settingsAutoTag;

  /// No description provided for @settingsAutoTagValue.
  ///
  /// In en, this message translates to:
  /// **'{percent} % sure'**
  String settingsAutoTagValue(int percent);

  /// No description provided for @settingsBrightness.
  ///
  /// In en, this message translates to:
  /// **'Brightness'**
  String get settingsBrightness;

  /// No description provided for @settingsCameraSection.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get settingsCameraSection;

  /// No description provided for @settingsClipAfter.
  ///
  /// In en, this message translates to:
  /// **'After press'**
  String get settingsClipAfter;

  /// No description provided for @settingsClipBefore.
  ///
  /// In en, this message translates to:
  /// **'Before press'**
  String get settingsClipBefore;

  /// No description provided for @settingsClipsNote.
  ///
  /// In en, this message translates to:
  /// **'Clips play {seconds} s in total. Changing \"Before\" takes up to that long to apply, while the cameras build up enough history.'**
  String settingsClipsNote(int seconds);

  /// No description provided for @settingsClipsSection.
  ///
  /// In en, this message translates to:
  /// **'Clips'**
  String get settingsClipsSection;

  /// No description provided for @settingsCloudFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t train now; it tries again later.'**
  String get settingsCloudFailed;

  /// No description provided for @settingsCloudLastTrained.
  ///
  /// In en, this message translates to:
  /// **'Last trained {time}'**
  String settingsCloudLastTrained(String time);

  /// No description provided for @settingsCloudNoLabels.
  ///
  /// In en, this message translates to:
  /// **'Nothing to learn yet: tag people and pets.'**
  String get settingsCloudNoLabels;

  /// No description provided for @settingsCloudNotPremium.
  ///
  /// In en, this message translates to:
  /// **'Cloud recognition is Premium only.'**
  String get settingsCloudNotPremium;

  /// No description provided for @settingsCloudNotTrained.
  ///
  /// In en, this message translates to:
  /// **'Not trained yet'**
  String get settingsCloudNotTrained;

  /// No description provided for @settingsCloudStatus.
  ///
  /// In en, this message translates to:
  /// **'{when}. Learns from the people and pets you tag; checked daily.'**
  String settingsCloudStatus(String when);

  /// No description provided for @settingsCloudTitle.
  ///
  /// In en, this message translates to:
  /// **'Cloud recognition (Premium)'**
  String get settingsCloudTitle;

  /// No description provided for @settingsCloudTrain.
  ///
  /// In en, this message translates to:
  /// **'Train now'**
  String get settingsCloudTrain;

  /// No description provided for @settingsCloudTrained.
  ///
  /// In en, this message translates to:
  /// **'Trained.'**
  String get settingsCloudTrained;

  /// No description provided for @settingsCloudUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Up to date.'**
  String get settingsCloudUpToDate;

  /// No description provided for @settingsCoordinatesAxes.
  ///
  /// In en, this message translates to:
  /// **'Give one latitude (N or S) and one longitude (E or W)'**
  String get settingsCoordinatesAxes;

  /// No description provided for @settingsCoordinatesEmpty.
  ///
  /// In en, this message translates to:
  /// **'Paste a latitude and longitude'**
  String get settingsCoordinatesEmpty;

  /// No description provided for @settingsCoordinatesInvalid.
  ///
  /// In en, this message translates to:
  /// **'Not a position: use latitude, longitude, e.g. 38.7223, -9.1393'**
  String get settingsCoordinatesInvalid;

  /// No description provided for @settingsCoordinatesLatitudeRange.
  ///
  /// In en, this message translates to:
  /// **'Latitude must be between -90 and 90'**
  String get settingsCoordinatesLatitudeRange;

  /// No description provided for @settingsCoordinatesLongitudeRange.
  ///
  /// In en, this message translates to:
  /// **'Longitude must be between -180 and 180'**
  String get settingsCoordinatesLongitudeRange;

  /// No description provided for @settingsCoordinatesMinutes.
  ///
  /// In en, this message translates to:
  /// **'Minutes and seconds go up to 59'**
  String get settingsCoordinatesMinutes;

  /// No description provided for @settingsDeleteDeviceCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get settingsDeleteDeviceCancel;

  /// No description provided for @settingsDeleteDeviceChoice.
  ///
  /// In en, this message translates to:
  /// **'Keep videos: it leaves the list, its events and videos stay. Delete videos: its events and videos are hidden on every device too. Either way, it shows again if it records again.'**
  String get settingsDeleteDeviceChoice;

  /// No description provided for @settingsDeleteDeviceConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete videos'**
  String get settingsDeleteDeviceConfirm;

  /// No description provided for @settingsDeleteDeviceDone.
  ///
  /// In en, this message translates to:
  /// **'Deleted {deviceId}: {count, plural, =1{1 event} other{{count} events}} hidden'**
  String settingsDeleteDeviceDone(String deviceId, int count);

  /// No description provided for @settingsDeleteDeviceFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not delete {deviceId}'**
  String settingsDeleteDeviceFailed(String deviceId);

  /// No description provided for @settingsDeleteDeviceKeep.
  ///
  /// In en, this message translates to:
  /// **'Keep videos'**
  String get settingsDeleteDeviceKeep;

  /// No description provided for @settingsDeleteDeviceMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete {deviceId} from your devices? {count, plural, =0{It has no events here} =1{It has 1 event} other{It has {count} events}}.'**
  String settingsDeleteDeviceMessage(String deviceId, int count);

  /// No description provided for @settingsDeleteDeviceRemoved.
  ///
  /// In en, this message translates to:
  /// **'Removed {deviceId} from the list; its videos stay'**
  String settingsDeleteDeviceRemoved(String deviceId);

  /// No description provided for @settingsDeleteDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete device?'**
  String get settingsDeleteDeviceTitle;

  /// No description provided for @settingsDevice.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get settingsDevice;

  /// No description provided for @settingsDeviceLoading.
  ///
  /// In en, this message translates to:
  /// **'loading…'**
  String get settingsDeviceLoading;

  /// No description provided for @settingsHistoryNote.
  ///
  /// In en, this message translates to:
  /// **'Older events and their clips are deleted from this device when the app starts and every 3 hours.'**
  String get settingsHistoryNote;

  /// No description provided for @settingsHistorySection.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get settingsHistorySection;

  /// No description provided for @settingsJoinDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get settingsJoinDismiss;

  /// No description provided for @settingsJoinOtherUser.
  ///
  /// In en, this message translates to:
  /// **'The link was shared by another Google account than {email}. Sign out, and sign in with that one, to add this device.'**
  String settingsJoinOtherUser(String email);

  /// No description provided for @settingsJoinOtherUserUnknown.
  ///
  /// In en, this message translates to:
  /// **'The link was shared by another Google account than yours. Sign out, and sign in with that one, to add this device.'**
  String get settingsJoinOtherUserUnknown;

  /// No description provided for @settingsJoinSameDevice.
  ///
  /// In en, this message translates to:
  /// **'This is the device that shared the link. Open it on another device to add that one.'**
  String get settingsJoinSameDevice;

  /// No description provided for @settingsJoinSignIn.
  ///
  /// In en, this message translates to:
  /// **'To add this device, sign in with the Google account that shared the link.'**
  String get settingsJoinSignIn;

  /// No description provided for @settingsJoinSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get settingsJoinSignOut;

  /// No description provided for @settingsKeep.
  ///
  /// In en, this message translates to:
  /// **'Keep events for'**
  String get settingsKeep;

  /// No description provided for @settingsKeepDays.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day} other{{count} days}}'**
  String settingsKeepDays(int count);

  /// No description provided for @settingsKeepWeeks.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 week} other{{count} weeks}}'**
  String settingsKeepWeeks(int count);

  /// No description provided for @settingsLiveAdminNote.
  ///
  /// In en, this message translates to:
  /// **'Always connected for admins, so this device is always reachable: other devices\' events arrive within a second.'**
  String get settingsLiveAdminNote;

  /// No description provided for @settingsLiveAlways.
  ///
  /// In en, this message translates to:
  /// **'Always'**
  String get settingsLiveAlways;

  /// No description provided for @settingsLiveAlwaysNote.
  ///
  /// In en, this message translates to:
  /// **'Stays connected: other devices\' events arrive within a second.'**
  String get settingsLiveAlwaysNote;

  /// No description provided for @settingsLiveConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect to live sync'**
  String get settingsLiveConnect;

  /// No description provided for @settingsLiveEvery.
  ///
  /// In en, this message translates to:
  /// **'Every {interval}'**
  String settingsLiveEvery(String interval);

  /// No description provided for @settingsLiveNever.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get settingsLiveNever;

  /// No description provided for @settingsLiveNeverNote.
  ///
  /// In en, this message translates to:
  /// **'Other devices\' events arrive with each sync (15 s), and this device\'s reach them the same way.'**
  String get settingsLiveNeverNote;

  /// No description provided for @settingsLiveScheduledNote.
  ///
  /// In en, this message translates to:
  /// **'Connects about every {interval} for what other devices sent meanwhile, and at once to send this device\'s events.'**
  String settingsLiveScheduledNote(String interval);

  /// No description provided for @settingsLiveSection.
  ///
  /// In en, this message translates to:
  /// **'Live sync'**
  String get settingsLiveSection;

  /// No description provided for @settingsLocationDenied.
  ///
  /// In en, this message translates to:
  /// **'Location permission was denied'**
  String get settingsLocationDenied;

  /// No description provided for @settingsLocationFinding.
  ///
  /// In en, this message translates to:
  /// **'Finding this device…'**
  String get settingsLocationFinding;

  /// No description provided for @settingsLocationMoveMap.
  ///
  /// In en, this message translates to:
  /// **'{reason}. Move the map to set it.'**
  String settingsLocationMoveMap(String reason);

  /// No description provided for @settingsLocationMyLocation.
  ///
  /// In en, this message translates to:
  /// **'My location'**
  String get settingsLocationMyLocation;

  /// No description provided for @settingsLocationOff.
  ///
  /// In en, this message translates to:
  /// **'Location is turned off'**
  String get settingsLocationOff;

  /// No description provided for @settingsLocationPaste.
  ///
  /// In en, this message translates to:
  /// **'Paste position'**
  String get settingsLocationPaste;

  /// No description provided for @settingsLocationPin.
  ///
  /// In en, this message translates to:
  /// **'Pin position'**
  String get settingsLocationPin;

  /// No description provided for @settingsLocationPinThis.
  ///
  /// In en, this message translates to:
  /// **'Pin this position'**
  String get settingsLocationPinThis;

  /// No description provided for @settingsLocationPinnedLabel.
  ///
  /// In en, this message translates to:
  /// **'Pinned:'**
  String get settingsLocationPinnedLabel;

  /// No description provided for @settingsLocationPinnedStatus.
  ///
  /// In en, this message translates to:
  /// **'Pinned · used for every event'**
  String get settingsLocationPinnedStatus;

  /// No description provided for @settingsLocationPositionLabel.
  ///
  /// In en, this message translates to:
  /// **'Position (latitude, longitude)'**
  String get settingsLocationPositionLabel;

  /// No description provided for @settingsLocationSection.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get settingsLocationSection;

  /// No description provided for @settingsLocationSetOnMap.
  ///
  /// In en, this message translates to:
  /// **'Set on the map'**
  String get settingsLocationSetOnMap;

  /// No description provided for @settingsLocationSetThis.
  ///
  /// In en, this message translates to:
  /// **'Set this position'**
  String get settingsLocationSetThis;

  /// No description provided for @settingsLocationThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device\'s location'**
  String get settingsLocationThisDevice;

  /// No description provided for @settingsLocationUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Location unavailable'**
  String get settingsLocationUnavailable;

  /// No description provided for @settingsLocationUnknown.
  ///
  /// In en, this message translates to:
  /// **'Location unknown'**
  String get settingsLocationUnknown;

  /// No description provided for @settingsLocationUnpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get settingsLocationUnpin;

  /// No description provided for @settingsLocationUnpinToLocate.
  ///
  /// In en, this message translates to:
  /// **'Unpin to use my location'**
  String get settingsLocationUnpinToLocate;

  /// No description provided for @settingsMapAttribution.
  ///
  /// In en, this message translates to:
  /// **'© OpenStreetMap contributors'**
  String get settingsMapAttribution;

  /// No description provided for @settingsMapZoomIn.
  ///
  /// In en, this message translates to:
  /// **'Zoom in'**
  String get settingsMapZoomIn;

  /// No description provided for @settingsMapZoomOut.
  ///
  /// In en, this message translates to:
  /// **'Zoom out'**
  String get settingsMapZoomOut;

  /// No description provided for @settingsMemoryAbout.
  ///
  /// In en, this message translates to:
  /// **'about {amount}'**
  String settingsMemoryAbout(String amount);

  /// No description provided for @settingsMemoryFree.
  ///
  /// In en, this message translates to:
  /// **'{amount} free'**
  String settingsMemoryFree(String amount);

  /// No description provided for @settingsMotionCooldown.
  ///
  /// In en, this message translates to:
  /// **'At most one automatic clip every'**
  String get settingsMotionCooldown;

  /// No description provided for @settingsMotionNow.
  ///
  /// In en, this message translates to:
  /// **'Motion now: {percent} %'**
  String settingsMotionNow(int percent);

  /// No description provided for @settingsMotionNowWaiting.
  ///
  /// In en, this message translates to:
  /// **'Motion now: waiting for the camera…'**
  String get settingsMotionNowWaiting;

  /// No description provided for @settingsMotionSection.
  ///
  /// In en, this message translates to:
  /// **'Motion'**
  String get settingsMotionSection;

  /// No description provided for @settingsMotionSwitch.
  ///
  /// In en, this message translates to:
  /// **'Clip automatically on motion'**
  String get settingsMotionSwitch;

  /// No description provided for @settingsMotionThreshold.
  ///
  /// In en, this message translates to:
  /// **'Motion threshold'**
  String get settingsMotionThreshold;

  /// No description provided for @settingsMotionThresholdValue.
  ///
  /// In en, this message translates to:
  /// **'{percent} % of the picture'**
  String settingsMotionThresholdValue(int percent);

  /// No description provided for @settingsNextClipDue.
  ///
  /// In en, this message translates to:
  /// **'Next clip: due, once a camera is open'**
  String get settingsNextClipDue;

  /// No description provided for @settingsNextClipIn.
  ///
  /// In en, this message translates to:
  /// **'Next clip in {time}'**
  String settingsNextClipIn(String time);

  /// No description provided for @settingsNightMode.
  ///
  /// In en, this message translates to:
  /// **'Night mode'**
  String get settingsNightMode;

  /// No description provided for @settingsNightModeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When it\'s dark: the brightest picture, and a light while a clip records (the torch, or the screen facing the scene)'**
  String get settingsNightModeSubtitle;

  /// No description provided for @settingsObjectsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Human, cat, dog, bicycle, bottle… for search'**
  String get settingsObjectsSubtitle;

  /// No description provided for @settingsObjectsSwitch.
  ///
  /// In en, this message translates to:
  /// **'Tag objects in new clips'**
  String get settingsObjectsSwitch;

  /// No description provided for @settingsProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get settingsProfile;

  /// No description provided for @settingsProfileNone.
  ///
  /// In en, this message translates to:
  /// **'none until signed in'**
  String get settingsProfileNone;

  /// No description provided for @settingsRecognitionSection.
  ///
  /// In en, this message translates to:
  /// **'Recognition'**
  String get settingsRecognitionSection;

  /// No description provided for @settingsRecognitionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'People and pets tagged before, found on this device'**
  String get settingsRecognitionSubtitle;

  /// No description provided for @settingsRecognitionSwitch.
  ///
  /// In en, this message translates to:
  /// **'Recognize subjects in new clips'**
  String get settingsRecognitionSwitch;

  /// No description provided for @settingsRecognitionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not available on this device yet'**
  String get settingsRecognitionUnavailable;

  /// No description provided for @settingsSameAsClip.
  ///
  /// In en, this message translates to:
  /// **'Same as pressing Clip'**
  String get settingsSameAsClip;

  /// No description provided for @settingsScheduleEvery.
  ///
  /// In en, this message translates to:
  /// **'One clip every'**
  String get settingsScheduleEvery;

  /// No description provided for @settingsScheduleSection.
  ///
  /// In en, this message translates to:
  /// **'Scheduled clips'**
  String get settingsScheduleSection;

  /// No description provided for @settingsScheduleSwitch.
  ///
  /// In en, this message translates to:
  /// **'Clip at start and on a timer'**
  String get settingsScheduleSwitch;

  /// No description provided for @settingsShowLog.
  ///
  /// In en, this message translates to:
  /// **'Show the Log tab'**
  String get settingsShowLog;

  /// No description provided for @settingsShowLogSubtitle.
  ///
  /// In en, this message translates to:
  /// **'The app\'s latest messages and health'**
  String get settingsShowLogSubtitle;

  /// No description provided for @settingsStartupClip.
  ///
  /// In en, this message translates to:
  /// **'Startup clip: once the camera is ready'**
  String get settingsStartupClip;

  /// No description provided for @settingsSubjectEvents.
  ///
  /// In en, this message translates to:
  /// **'How many events to load at once'**
  String get settingsSubjectEvents;

  /// No description provided for @settingsSubjectsSection.
  ///
  /// In en, this message translates to:
  /// **'Subjects'**
  String get settingsSubjectsSection;

  /// A free trial's length
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day} other{{count} days}}'**
  String storeDays(int count);

  /// In the Delete account dialog on iOS and Android, instead of authDeleteAccountSubscription (which names Stripe)
  ///
  /// In en, this message translates to:
  /// **'Deleting your account doesn\'t cancel a Premium subscription: cancel it first in your {store, select, apple{App Store} google{Google Play} other{store}} subscription settings.'**
  String storeDeleteAccountSubscription(String store);

  /// A billing period of one day, after a price and a slash
  ///
  /// In en, this message translates to:
  /// **'day'**
  String get storeEveryDay;

  /// A billing period of several days, after a price and a slash
  ///
  /// In en, this message translates to:
  /// **'{count} days'**
  String storeEveryDays(int count);

  /// A billing period of one month, after a price and a slash
  ///
  /// In en, this message translates to:
  /// **'month'**
  String get storeEveryMonth;

  /// A billing period of several months, after a price and a slash
  ///
  /// In en, this message translates to:
  /// **'{count} months'**
  String storeEveryMonths(int count);

  /// A billing period of one week, after a price and a slash
  ///
  /// In en, this message translates to:
  /// **'week'**
  String get storeEveryWeek;

  /// A billing period of several weeks, after a price and a slash
  ///
  /// In en, this message translates to:
  /// **'{count} weeks'**
  String storeEveryWeeks(int count);

  /// A billing period of one year, after a price and a slash
  ///
  /// In en, this message translates to:
  /// **'year'**
  String get storeEveryYear;

  /// A billing period of several years, after a price and a slash
  ///
  /// In en, this message translates to:
  /// **'{count} years'**
  String storeEveryYears(int count);

  /// No description provided for @storeFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t confirm the purchase with Presence yet. It\'s tried again automatically.'**
  String get storeFailed;

  /// No description provided for @storeLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading the plans…'**
  String get storeLoading;

  /// No description provided for @storeManage.
  ///
  /// In en, this message translates to:
  /// **'Manage subscription'**
  String get storeManage;

  /// No description provided for @storeMonths.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 month} other{{count} months}}'**
  String storeMonths(int count);

  /// No description provided for @storeNotVerified.
  ///
  /// In en, this message translates to:
  /// **'The store didn\'t confirm this purchase.'**
  String get storeNotVerified;

  /// No description provided for @storeNothingToRestore.
  ///
  /// In en, this message translates to:
  /// **'No active subscription to restore.'**
  String get storeNothingToRestore;

  /// No description provided for @storeOtherAccount.
  ///
  /// In en, this message translates to:
  /// **'This subscription belongs to another Presence account.'**
  String get storeOtherAccount;

  /// No description provided for @storePending.
  ///
  /// In en, this message translates to:
  /// **'Purchase pending: Premium starts once the store confirms it.'**
  String get storePending;

  /// The free plan's text in the iOS and Android apps, where Premium is bought in the store: no web price
  ///
  /// In en, this message translates to:
  /// **'Free: up to {free} devices sync with each other while online. Premium adds cloud backup and up to {premium} devices.'**
  String storePlanFreeText(int free, int premium);

  /// The monthly store subscription's name, before its price
  ///
  /// In en, this message translates to:
  /// **'Premium monthly'**
  String get storePlanMonthly;

  /// A store subscription's button: its name, the store's localized price and the billing period (storeEvery*)
  ///
  /// In en, this message translates to:
  /// **'{plan}: {price} / {period}'**
  String storePlanPrice(String plan, String price, String period);

  /// The yearly store subscription's name, before its price
  ///
  /// In en, this message translates to:
  /// **'Premium yearly'**
  String get storePlanYearly;

  /// No description provided for @storePrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get storePrivacy;

  /// No description provided for @storePurchaseFailed.
  ///
  /// In en, this message translates to:
  /// **'The purchase didn\'t go through.'**
  String get storePurchaseFailed;

  /// No description provided for @storePurchased.
  ///
  /// In en, this message translates to:
  /// **'Thank you! Premium is on.'**
  String get storePurchased;

  /// Next to the store purchase buttons
  ///
  /// In en, this message translates to:
  /// **'Subscriptions renew automatically until you cancel them in your {store, select, apple{App Store} google{Google Play} other{store}} account settings, at least 24 hours before the period ends.'**
  String storeRenews(String store);

  /// No description provided for @storeRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore purchases'**
  String get storeRestore;

  /// No description provided for @storeRestored.
  ///
  /// In en, this message translates to:
  /// **'Your subscription is restored.'**
  String get storeRestored;

  /// No description provided for @storeTerms.
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get storeTerms;

  /// Under a subscription with a free trial: the trial's length (storeDays...), then the price and period
  ///
  /// In en, this message translates to:
  /// **'{trial} free, then {price} / {period}.'**
  String storeTrial(String trial, String price, String period);

  /// No description provided for @storeUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Purchases aren\'t available right now.'**
  String get storeUnavailable;

  /// No description provided for @storeWeeks.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 week} other{{count} weeks}}'**
  String storeWeeks(int count);

  /// No description provided for @storeYears.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 year} other{{count} years}}'**
  String storeYears(int count);

  /// No description provided for @subjectsEvents.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 event} other{{count} events}}'**
  String subjectsEvents(int count);

  /// No description provided for @subjectsLatestEvents.
  ///
  /// In en, this message translates to:
  /// **'Latest {shown} of {total} events'**
  String subjectsLatestEvents(int shown, int total);

  /// No description provided for @subjectsNoLocation.
  ///
  /// In en, this message translates to:
  /// **'No location'**
  String get subjectsNoLocation;

  /// No description provided for @subjectsNobodyTagged.
  ///
  /// In en, this message translates to:
  /// **'Nobody is tagged with this name any more.'**
  String get subjectsNobodyTagged;

  /// No description provided for @subjectsOpen.
  ///
  /// In en, this message translates to:
  /// **'Open {name}'**
  String subjectsOpen(String name);

  /// No description provided for @subjectsOpenEvent.
  ///
  /// In en, this message translates to:
  /// **'Open event {label}'**
  String subjectsOpenEvent(String label);

  /// No description provided for @subjectsRecognizedAuto.
  ///
  /// In en, this message translates to:
  /// **'Recognized automatically'**
  String get subjectsRecognizedAuto;
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
      <String>['en', 'es', 'pt'].contains(locale.languageCode);

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
    case 'pt':
      return AppLocalizationsPt();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
