// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get aboutLinkCopied => 'Link copied';

  @override
  String get aboutOpenSource => 'Presence is open source:';

  @override
  String get aboutParagraph =>
      'Presence turns any device with a camera into an always-on camera for a place you look after: live feeds, clips that include the moments before, and clips on motion. Only record where you\'re allowed to.';

  @override
  String get authAccessAdmin => 'Admin Access';

  @override
  String get authAccessFree => 'Free Access';

  @override
  String get authAccessPremium => 'Premium Access';

  @override
  String get authAccessPro => 'Pro Access';

  @override
  String get authBackedUp => 'Clips and events are backed up';

  @override
  String authBackedUpBoth(int up, int down) {
    return 'Backed up ($up uploaded, $down restored)';
  }

  @override
  String authBackedUpRestored(int down) {
    return 'Backed up ($down restored)';
  }

  @override
  String authBackedUpUploaded(int up) {
    return 'Backed up ($up uploaded)';
  }

  @override
  String get authBackupOff => 'Cloud backup is off';

  @override
  String get authCheckAgain => 'Check again';

  @override
  String get authCheckingRoles => 'Checking roles…';

  @override
  String get authDeleteAccount => 'Delete account';

  @override
  String get authDeleteAccountCancel => 'Cancel';

  @override
  String get authDeleteAccountChanged =>
      'Your account\'s profile changed. Close this and try again.';

  @override
  String get authDeleteAccountConfirm =>
      'I understand that this can\'t be undone';

  @override
  String get authDeleteAccountDevice =>
      'This device\'s copies of the profile\'s events and clips are deleted too, and you\'re signed out. This can\'t be undone.';

  @override
  String get authDeleteAccountDone =>
      'Your account and its profile were deleted';

  @override
  String authDeleteAccountFailed(String error) {
    return 'Couldn\'t delete the account ($error). Try again.';
  }

  @override
  String authDeleteAccountLinked(String email, String profile, String owner) {
    return '$email is linked to the profile $profile, owned by $owner. Deleting your account unlinks it and deletes your Feedback & Help messages; the profile and its data stay its owner\'s.';
  }

  @override
  String get authDeleteAccountManage => 'How to cancel a subscription';

  @override
  String authDeleteAccountOthers(String emails) {
    return 'These accounts linked to it lose access too: $emails.';
  }

  @override
  String authDeleteAccountOwner(String profile) {
    return 'You own the profile $profile. Deleting your account deletes the whole profile: its events, clips, recordings and settings in the cloud, its Feedback & Help messages, its recognition labels and its devices\' stream keys.';
  }

  @override
  String get authDeleteAccountSignInAgain =>
      'Sign in again, then delete the account.';

  @override
  String get authDeleteAccountSubscription =>
      'Deleting your account doesn\'t cancel a Premium subscription: cancel it first, from the link in your Stripe receipt, or ask us.';

  @override
  String get authDeleteAccountTitle => 'Delete your account?';

  @override
  String get authDeleteAccountUnfinished =>
      'The cloud data is still being deleted. Try again in a minute to finish.';

  @override
  String get authDeleteAccountUnlinked =>
      'Your account was deleted and unlinked from the profile';

  @override
  String authDeleteDevice(String device) {
    return 'Delete $device';
  }

  @override
  String authDeviceCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count devices',
      one: '1 device',
    );
    return '$_temp0';
  }

  @override
  String get authFeedback => 'Feedback';

  @override
  String get authFeedbackIntro =>
      'Members\' messages from the Help tab, the latest active first. Your replies show there.';

  @override
  String authFeedbackLoadFailed(String error) {
    return 'Couldn\'t load feedback ($error).';
  }

  @override
  String get authHaveCode =>
      'Have a code from your other account? Enter it to link this one to it.';

  @override
  String get authHidden => 'hidden';

  @override
  String authHiddenCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count devices hidden',
      one: '1 device hidden',
    );
    return '$_temp0';
  }

  @override
  String get authHiddenTooltip =>
      'Past the plan\'s device limit: it doesn\'t sync, and its events are hidden here';

  @override
  String authHideDevice(String device) {
    return 'Hide $device\'s events';
  }

  @override
  String get authJoin => 'Join Presence';

  @override
  String get authJoinFree => 'Join free';

  @override
  String get authJoinFreeFailed =>
      'Couldn\'t join right now. Try again in a moment.';

  @override
  String authJoinFreeText(String email) {
    return '$email isn\'t a member of Presence yet. Join free to use it on this device.';
  }

  @override
  String get authLeader => 'leader';

  @override
  String get authLeaderTooltip =>
      'The profile\'s leading streamer: the only one that streams to the cloud. The others wait, and one takes its place when it\'s been offline for an hour.';

  @override
  String get authLinkAnother => 'Link another account';

  @override
  String get authLinkCode => 'Link code';

  @override
  String get authLinkCodeHelp =>
      'Within 10 minutes, sign in with the other Google account and enter this code under Linked accounts.';

  @override
  String get authLinkCodeWrong =>
      'That code is wrong, already used or expired.';

  @override
  String get authLinkConflict =>
      'This account can\'t be linked: it has cloud data of its own, or other accounts are linked to it.';

  @override
  String get authLinkNoBackup =>
      'Cloud backup isn\'t set up, so accounts can\'t be linked.';

  @override
  String get authLinkOtherAccount =>
      'Have access with another Google account? Link it';

  @override
  String get authLinkThis => 'Link this account';

  @override
  String get authLinkTooMany => 'Too many tries. Wait a minute and try again.';

  @override
  String get authLinkedAccounts => 'Linked accounts';

  @override
  String get authLinkedIntro =>
      'Any of these Google accounts reaches the same clips and events.';

  @override
  String authLinkedTo(String owner) {
    return 'Linked to $owner.';
  }

  @override
  String get authLinkedToProfile => 'Linked to the profile.';

  @override
  String get authNoEvents => 'No events';

  @override
  String get authNoFeedback => 'No feedback yet.';

  @override
  String get authNoRoles => 'No roles yet';

  @override
  String get authNoVerifiedEmail => 'This account has no verified email.';

  @override
  String get authNotSignedIn => 'Not signed in.';

  @override
  String authOpenHost(String host) {
    return 'Open $host';
  }

  @override
  String get authOsUnknown => 'Operating system unknown';

  @override
  String get authOwner => 'Owner';

  @override
  String get authPaymentsDefaults =>
      'Not saved yet: these are the deploy\'s links.';

  @override
  String get authPaymentsIntro =>
      'The Stripe Payment Links free members upgrade to Premium with, and members to Pro. Leave one empty not to offer that plan.';

  @override
  String get authPaymentsInvalid => 'Empty, or an https link on stripe.com';

  @override
  String get authPaymentsMonthly => 'Monthly plan link';

  @override
  String get authPaymentsProMonthly => 'Pro monthly plan link';

  @override
  String get authPaymentsProYearly => 'Pro yearly plan link';

  @override
  String get authPaymentsSave => 'Save links';

  @override
  String authPaymentsSaveFailed(String error) {
    return 'Couldn\'t save the links ($error)';
  }

  @override
  String get authPaymentsSaved => 'Payment links saved';

  @override
  String get authPaymentsTitle => 'Payments';

  @override
  String get authPaymentsUnavailable => 'The payments API didn\'t answer.';

  @override
  String get authPaymentsYearly => 'Yearly plan link';

  @override
  String get authPlanFree => 'Free';

  @override
  String authPlanFreeText(int free, int premium, int pro) {
    return 'Free: each device keeps its events, and up to $free devices share them every 15 minutes. Premium syncs them instantly, with cloud backup and up to $premium devices: US\$20 a month, the first week free. Pro: up to $pro devices.';
  }

  @override
  String get authPlanPremium => 'Premium';

  @override
  String authPlanPremiumProText(int limit, int pro) {
    return 'Premium: cloud backup, and up to $limit devices sync. Pro: up to $pro devices.';
  }

  @override
  String authPlanPremiumText(int limit) {
    return 'Premium: cloud backup, and up to $limit devices sync.';
  }

  @override
  String get authPlanPro => 'Pro';

  @override
  String authPlanProText(int limit) {
    return 'Pro: cloud backup, and up to $limit devices sync.';
  }

  @override
  String get authPremiumMonthly => 'Premium monthly';

  @override
  String get authPremiumYearly => 'Premium yearly';

  @override
  String get authProMonthly => 'Pro monthly';

  @override
  String get authProYearly => 'Pro yearly';

  @override
  String get authProfile => 'Profile';

  @override
  String get authProviderNotConfigured =>
      'This sign-in isn\'t set up on the server yet.';

  @override
  String get authRbacrText =>
      'Voucher codes and maintenance mode are managed in rbacr, which keeps every role. Members redeem codes on the Sign up sheet.';

  @override
  String get authRedeem => 'Redeem';

  @override
  String get authReload => 'Reload';

  @override
  String authReplyFailed(String email, String error) {
    return 'Couldn\'t reply to $email ($error)';
  }

  @override
  String authRequestFailed(int status) {
    return 'The request failed (HTTP $status).';
  }

  @override
  String get authRetry => 'Retry';

  @override
  String get authRoleRoot => 'Root';

  @override
  String authRolesSemantics(String roles) {
    return 'Roles: $roles';
  }

  @override
  String get authSessionEnded => 'Your session ended. Sign in again.';

  @override
  String get authSessionRefused => 'Presence didn\'t accept this sign-in.';

  @override
  String get authSessionUnreachable => 'Couldn\'t reach Presence. Try again.';

  @override
  String authShowDevice(String device) {
    return 'Show $device\'s events';
  }

  @override
  String get authSignIn => 'Sign in';

  @override
  String get authSignInToPresence => 'Sign in to Presence';

  @override
  String get authSignInWithApple => 'Sign in with Apple';

  @override
  String get authSignInWithGoogle => 'Sign in with Google';

  @override
  String get authSignOut => 'Sign out';

  @override
  String get authSignUp => 'Sign up';

  @override
  String authSignedInAs(String identity) {
    return 'Signed in as $identity';
  }

  @override
  String authSomethingWrong(String error) {
    return 'Something went wrong ($error).';
  }

  @override
  String get authStreamerBody =>
      'Paste this in a terminal on a Linux device with a camera (Raspberry Pi OS or Debian, ARM, 32- or 64-bit), even one without a screen. It installs the Presence streamer as a new device of this profile, which records from every boot and keeps the clips with people and animals. Nobody signs in on it.';

  @override
  String get authStreamerCopied => 'Command copied: paste it on the streamer';

  @override
  String get authStreamerCopy => 'Copy command';

  @override
  String get authStreamerCreate => 'Get command';

  @override
  String authStreamerFailed(String error) {
    return 'Couldn\'t get the command ($error)';
  }

  @override
  String get authStreamerKeyOnce =>
      'It holds this device\'s key, shown only now: keep it private. Deleting the device stops it; creating another command makes another device.';

  @override
  String get authStreamerTitle => 'Streamer';

  @override
  String get authSubscribe => 'Subscribe';

  @override
  String get authSubscribeButton => 'Subscribe at nu01.com';

  @override
  String authSubscribeText(String email) {
    return '$email doesn\'t have access to Presence yet. Subscribe at nu01.com: Free, or Premium for cloud backup and more devices. Then check again here.';
  }

  @override
  String get authSyncFree =>
      'Each device keeps its events; your devices share them every 15 minutes (Premium: instantly)';

  @override
  String get authThisAccount => 'This account';

  @override
  String get authThisDevice => 'this device';

  @override
  String get authThisDeviceHidden => 'This device doesn\'t sync';

  @override
  String get authUnavailable => 'Sign-in is unavailable.';

  @override
  String get authUnlink => 'Unlink';

  @override
  String authUnlinked(String email) {
    return '$email was unlinked.';
  }

  @override
  String get authUpgrade => 'Upgrade';

  @override
  String get authUpgradePremium => 'Upgrade to Premium';

  @override
  String get authUploadFailed => 'Upload failed';

  @override
  String get authUploading => 'Uploading…';

  @override
  String authVoucherDiscount(int discount) {
    return 'That code gives $discount% off. Paying the rest isn\'t available yet, so it can\'t let you in.';
  }

  @override
  String get authVoucherFailed => 'Couldn\'t redeem the code.';

  @override
  String authVoucherFailedDetail(String error) {
    return 'Couldn\'t redeem the code ($error).';
  }

  @override
  String get authVoucherInvalid => 'That code is invalid, expired or used up.';

  @override
  String get authVoucherLabel => 'Voucher code';

  @override
  String get authVoucherPayment =>
      'That code needs a payment, which isn\'t available yet, so it can\'t let you in.';

  @override
  String get authVoucherPrompt =>
      'Have a voucher code? Redeem it to get in right away.';

  @override
  String get authVoucherTooMany =>
      'Too many tries. Wait a while and try again.';

  @override
  String get authVouchersTitle => 'Vouchers and maintenance';

  @override
  String get authYourAccount => 'Your account';

  @override
  String get blinkAbout =>
      'A streamer of yours fetches your Blink cameras\' clips: each camera becomes a device, and its clips with a person or an animal become events.';

  @override
  String get blinkConnect => 'Connect';

  @override
  String blinkConnected(String account) {
    return 'Connected to Blink as $account. Its cameras:';
  }

  @override
  String get blinkDisconnect => 'Disconnect';

  @override
  String get blinkEmail => 'Blink account email';

  @override
  String blinkError(String error) {
    return 'Blink: $error';
  }

  @override
  String get blinkInstalling =>
      'Installing Blink support on the streamer (once)…';

  @override
  String blinkLastFetch(String time) {
    return 'Clips last fetched at $time.';
  }

  @override
  String get blinkLoggingIn => 'Logging in to Blink…';

  @override
  String get blinkNoCameras => 'No cameras yet.';

  @override
  String get blinkNoStreamer =>
      'Set up a streamer first (Profile › Streamer); it fetches the Blink cameras\' clips.';

  @override
  String get blinkNotSent =>
      'Couldn\'t send it: the streamer\'s key isn\'t here yet, or cloud sync is off. Try again in a minute.';

  @override
  String get blinkOff => 'Not connected to Blink.';

  @override
  String get blinkPassword => 'Blink password';

  @override
  String get blinkPasswordNote =>
      'Sealed with the streamer\'s key (only your devices can open it) and deleted once it has logged in; it keeps only Blink\'s token.';

  @override
  String get blinkPin => 'PIN';

  @override
  String blinkPinRequired(String account) {
    return 'Blink sent a PIN to $account\'s email or phone: enter it here.';
  }

  @override
  String get blinkRemove => 'Remove';

  @override
  String get blinkRemoveNote =>
      'Remove stops fetching a camera, and it leaves your devices; its events stay. Disconnect and connect again to bring removed cameras back.';

  @override
  String get blinkSendPin => 'Send PIN';

  @override
  String get blinkStreamer => 'The streamer that fetches them';

  @override
  String blinkWaiting(String device) {
    return 'Sent to $device; it looks every 30 s…';
  }

  @override
  String cameraAgeDays(int days) {
    return '$days d ago';
  }

  @override
  String cameraAgeHours(int hours) {
    return '$hours h ago';
  }

  @override
  String get cameraAgeJustNow => 'just now';

  @override
  String cameraAgeMinutes(int minutes) {
    return '$minutes min ago';
  }

  @override
  String cameraAgeSeconds(int seconds) {
    return '$seconds s ago';
  }

  @override
  String get cameraAskedFreshGrab => 'Asked for a fresh grab';

  @override
  String get cameraClip => 'Clip';

  @override
  String get cameraClipArchived => 'Archived: this video is in cold storage';

  @override
  String get cameraClipCameraOff => 'Camera off';

  @override
  String cameraClipCountdown(String time) {
    return 'Clip · $time';
  }

  @override
  String get cameraClipLoadFailed => 'Couldn\'t load this clip';

  @override
  String cameraClipNextIn(String countdown) {
    return 'Next automatic clip in $countdown';
  }

  @override
  String get cameraClipNoCamera => 'No camera';

  @override
  String get cameraClipNotReady => 'Camera not ready';

  @override
  String get cameraClipPreview => 'Preview';

  @override
  String get cameraClipReady => 'Ready';

  @override
  String cameraClipRecordingNext(int seconds) {
    return 'Recording the next $seconds s…';
  }

  @override
  String get cameraClipSaving => 'Clip saving…';

  @override
  String cameraClipSavingNext(String next) {
    return 'Clip saving… $next';
  }

  @override
  String get cameraClipStarting => 'Camera starting…';

  @override
  String get cameraClipUnavailable => 'Camera unavailable';

  @override
  String cameraCouldNotOpen(String reason) {
    return 'Could not open the camera\n$reason';
  }

  @override
  String get cameraErrorBlocked =>
      'Camera access is blocked for this site. Allow the camera in the browser\'s site settings, then retry.';

  @override
  String get cameraErrorDenied =>
      'Camera permission was denied. Allow it in Settings.';

  @override
  String get cameraErrorGeneric =>
      'Something went wrong while starting the camera.';

  @override
  String get cameraErrorInUse =>
      'The camera is in use by another app, or couldn\'t start. Close other apps using it, then retry.';

  @override
  String get cameraErrorInsecure =>
      'The camera only works on a secure page. Open Presence over HTTPS.';

  @override
  String get cameraErrorNoneFound =>
      'No camera was found. Connect one, then retry.';

  @override
  String get cameraErrorStopped =>
      'The camera stopped (unplugged or taken away)';

  @override
  String get cameraFlip => 'Flip camera';

  @override
  String get cameraLive => 'live';

  @override
  String get cameraModeAll => 'All devices';

  @override
  String get cameraModeAllHint => 'Every device in a grid';

  @override
  String get cameraModeMenu => 'Camera mode';

  @override
  String get cameraModeNormal => 'This camera';

  @override
  String get cameraModeNormalHint => 'Full screen';

  @override
  String get cameraModeStopped => 'Stopped';

  @override
  String get cameraModeStoppedHint => 'Camera off, still syncing';

  @override
  String get cameraModeUnattended => 'Unattended';

  @override
  String get cameraModeUnattendedHint => 'Screen off, still capturing';

  @override
  String get cameraNight => 'Night';

  @override
  String get cameraNightTooltip =>
      'Night mode: as bright as it goes, and lit while a clip records';

  @override
  String get cameraNotFound => 'No camera found';

  @override
  String get cameraOffMessage =>
      'Camera off\nNothing is recorded until you turn it on.';

  @override
  String get cameraRetry => 'Retry';

  @override
  String get cameraThisDevice => 'This device';

  @override
  String get cameraTurnOn => 'Turn on';

  @override
  String get clipAuto => 'Auto';

  @override
  String get clipAutoAllTagged =>
      'Every subject named before is already on this clip.';

  @override
  String clipAutoCloudFailed(String subjects) {
    return '$subjects Cloud recognition didn\'t answer (breeds and coats); try again.';
  }

  @override
  String get clipAutoDeferred =>
      'The phone is low on memory: try again in a moment.';

  @override
  String get clipAutoFailed => 'Couldn\'t run recognition; try again.';

  @override
  String clipAutoFound(String names) {
    return 'Found $names.';
  }

  @override
  String get clipAutoLooking => 'Looking for the subjects named before…';

  @override
  String get clipAutoNoReferences =>
      'No subjects to look for yet: name someone on another clip first.';

  @override
  String get clipAutoNone => 'No subjects recognized.';

  @override
  String clipAutoNotSureMany(String names) {
    return 'Not sure about $names: answer the questions in the events.';
  }

  @override
  String clipAutoNotSureOne(String names, String name) {
    return 'Not sure about $names: answer \"Is this $name?\" in the events.';
  }

  @override
  String clipAutoTags(String subjects, String tags) {
    return '$subjects Tags: $tags.';
  }

  @override
  String get clipAutoTooltip =>
      'Find the subjects named before, and tag the things seen, on this device';

  @override
  String get clipAutoUnavailable => 'Not available on this device yet';

  @override
  String get clipAutoUnsupported =>
      'Recognition is not available on this device yet.';

  @override
  String get clipAutoWaiting => 'Waiting for the clip to finish recording…';

  @override
  String get clipCancel => 'Cancel';

  @override
  String get clipClose => 'Close';

  @override
  String get clipDone => 'Done';

  @override
  String get clipFrameTagLabel =>
      'Frame to name subjects on: click a person or pet to name them';

  @override
  String get clipGrabFailed => 'Couldn\'t grab this frame; try again';

  @override
  String clipIdentifyHint(String label) {
    return '$label: click them on the video to name them, or try Auto.';
  }

  @override
  String get clipNameAdd => 'Add';

  @override
  String get clipNameFrameHint => 'Name someone on this frame';

  @override
  String get clipNameHint => 'Name';

  @override
  String get clipNameMore => 'Name more subjects on this frame';

  @override
  String get clipNameSpotHint => 'Who is at the ring?';

  @override
  String get clipNameSubject => 'Name subject';

  @override
  String clipNamesAnd(String first, String last) {
    return '$first and $last';
  }

  @override
  String get clipNoSubjects =>
      'No subjects yet. Click a person or pet on the video to name them.';

  @override
  String get clipNoTags => 'No tags: nothing was seen on this clip.';

  @override
  String get clipNoTagsYet =>
      'No tags yet. Things seen on the clip, like bottle or bicycle, show here once it has been searched.';

  @override
  String get clipNoTagsYetTryAuto =>
      'No tags yet. Things seen on the clip, like bottle or bicycle, show here once it has been searched (try Auto).';

  @override
  String get clipNoVideo => 'No video recorded';

  @override
  String get clipNotRecordedClosed =>
      'Not recorded: the app closed while recording';

  @override
  String clipNotSaved(String status, String error) {
    return '$status · not saved: $error';
  }

  @override
  String get clipPlay => 'Play the clip';

  @override
  String clipPreviousOnly(int before, int after) {
    return 'Previous $before s only: the app closed before the next $after s were recorded';
  }

  @override
  String clipPreviousReady(int before, int after) {
    return 'Previous $before s ready · recording next $after s…';
  }

  @override
  String clipReady(int seconds) {
    return '$seconds s clip ready';
  }

  @override
  String get clipRecordingElsewhere => 'Recording on another device…';

  @override
  String get clipRecordingFailed => 'Recording failed';

  @override
  String clipRecordingNext(int after) {
    return 'Recording next $after s…';
  }

  @override
  String get clipRemoveSubject => 'Remove subject';

  @override
  String clipRemoveSubjectFromEvent(String label) {
    return 'Remove subject $label from this event';
  }

  @override
  String clipRemoveTagFromEvent(String label) {
    return 'Remove tag $label from this event';
  }

  @override
  String get clipRenameSubject => 'Rename subject';

  @override
  String get clipSave => 'Save';

  @override
  String clipSavingPrevious(int before) {
    return 'Saving previous $before s…';
  }

  @override
  String clipShowAt(String time) {
    return 'Show at $time';
  }

  @override
  String get clipShowEveryEvent => 'Show every event';

  @override
  String get clipShowEveryHold => 'Show every event (hold to rename)';

  @override
  String clipShowOnlyHold(String name) {
    return 'Show only events with $name (hold to rename)';
  }

  @override
  String clipShowOnlyWith(String label) {
    return 'Show only events with $label';
  }

  @override
  String get clipSubjects => 'Subjects';

  @override
  String clipTagHint(String time) {
    return 'Click where a person or pet is on the picture, then type their name below; or just type the name for this frame (at $time).';
  }

  @override
  String get clipTags => 'Tags';

  @override
  String get clipUnsupported =>
      'Video clips aren\'t supported on this platform';

  @override
  String get clipWhoIsThis => 'Who is this?';

  @override
  String get connectivityAllGood => 'Online · live sync connected';

  @override
  String get connectivityChecking => 'Checking the connection…';

  @override
  String get connectivityCloudFailed => 'Cloud sync failed';

  @override
  String get connectivityCloudNotSet =>
      'Cloud sync isn\'t set up in this build';

  @override
  String get connectivityCloudOn => 'Cloud sync on';

  @override
  String get connectivityCloudOneSide =>
      'Cloud sync is set up on one side only';

  @override
  String get connectivityFree => 'Free: devices share events every 15 min';

  @override
  String connectivityLabel(String headline) {
    return 'Connectivity: $headline';
  }

  @override
  String get connectivityLiveConnected => 'Live sync connected';

  @override
  String get connectivityLiveConnecting => 'Connecting to live sync…';

  @override
  String get connectivityLiveFailed => 'Live sync failed';

  @override
  String connectivityLiveIdle(String next) {
    return 'Live sync idle · next in $next';
  }

  @override
  String get connectivityLiveNotSet => 'Live sync isn\'t set up in this build';

  @override
  String get connectivityLiveOff => 'Live sync is off';

  @override
  String get connectivityLiveOnceSynced => 'Live sync connects once synced';

  @override
  String get connectivityNote =>
      'Other devices see this one live only while live sync is connected.';

  @override
  String get connectivityOffline => 'Offline: can\'t reach the server';

  @override
  String get connectivityOnline => 'Online';

  @override
  String connectivityPresenceAnswered(String since) {
    return 'Live — answered $since';
  }

  @override
  String connectivityPresenceLastSeen(String since, String unavailable) {
    return 'Last seen $since$unavailable';
  }

  @override
  String connectivityPresenceNever(String unavailable) {
    return 'Never seen$unavailable';
  }

  @override
  String get connectivityPresenceThisLive =>
      'Live — this device, connected to live sync';

  @override
  String get connectivityPresenceThisNotConnected =>
      'This device — not connected to live sync now';

  @override
  String get connectivityPresenceThisUnavailable =>
      'This device — live status unavailable';

  @override
  String get connectivityPresenceUnavailable => ' · live status unavailable';

  @override
  String connectivityThisDevice(String headline) {
    return 'This device — $headline';
  }

  @override
  String get consentAgree => 'I agree';

  @override
  String get consentBiometricsDetail =>
      'Under the GDPR, faces used to identify people, as when naming them in clips, need care: clear consent, safe keeping, and deleting on request.';

  @override
  String get consentBiometricsTitle =>
      'Faces are biometric data, and I am responsible.';

  @override
  String get consentFootnote => 'Asked once on this device. Not legal advice.';

  @override
  String get consentIntro => 'By continuing, you confirm:';

  @override
  String get consentRightDetail =>
      'I own or manage this place, or have permission, and people who may be filmed know about it.';

  @override
  String get consentRightTitle => 'I have the right to record here.';

  @override
  String get consentTitle => 'Before Presence starts recording';

  @override
  String get devModeTooltip =>
      'Development mode: sign-in isn\'t configured, so everything is open to everyone.';

  @override
  String devModeTooltipVersion(String version) {
    return 'Development mode, version $version: sign-in isn\'t configured, so everything is open to everyone.';
  }

  @override
  String get eventAlreadyDeleted => 'Event already deleted';

  @override
  String get eventCancel => 'Cancel';

  @override
  String get eventCloudArchived => 'Archived in the cloud (not on this device)';

  @override
  String get eventCloudColdStorage =>
      'Its recording is in cold storage: it can\'t be played from the cloud';

  @override
  String get eventCloudDelete => 'Delete';

  @override
  String get eventCloudDeleteBody =>
      'Its recording, thumbnail and tags are deleted from the cloud. This device won\'t upload it again unless you put it back.';

  @override
  String get eventCloudDeleteFailed => 'Couldn\'t delete it from the cloud';

  @override
  String get eventCloudDeleteOnlyCopy =>
      'This device doesn\'t hold a full copy: unless another device does, it\'s gone for good.';

  @override
  String get eventCloudDeleteTitle => 'Delete from the cloud?';

  @override
  String get eventCloudDeleted => 'Deleted from the cloud';

  @override
  String get eventCloudNotSynced => 'Not in the cloud';

  @override
  String get eventCloudPutFailed =>
      'Couldn\'t put it in the cloud: that takes a premium profile and a full copy on this device.';

  @override
  String get eventCloudPutting => 'Putting it in the cloud…';

  @override
  String get eventCloudSynced => 'In the cloud';

  @override
  String get eventCloudTapToDelete => 'Tap to delete it from the cloud';

  @override
  String get eventCloudTapToPut => 'Tap to put it in the cloud';

  @override
  String eventCopies(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count copies',
      one: '1 copy',
    );
    return '$_temp0';
  }

  @override
  String get eventCopiesCloud => 'Cloud';

  @override
  String get eventCopiesCloudColdStorage => 'Cloud (cold storage)';

  @override
  String get eventCopiesLiveOff =>
      'Live sync is off: other devices\' copies are unknown';

  @override
  String get eventCopiesNone => 'No copy known';

  @override
  String get eventCopiesNotSynced => 'Not synced';

  @override
  String eventCopiesOnDevices(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'On $count devices',
      one: 'On 1 device',
      zero: 'On no device',
    );
    return '$_temp0';
  }

  @override
  String get eventCopiesShareFailed =>
      'Couldn\'t reach the other devices: live sync is off or not connected';

  @override
  String get eventCopiesSharing => 'Asked the other devices to take a copy';

  @override
  String get eventCopiesTapToShare => 'Tap to sync a copy to every device';

  @override
  String get eventCopiesThisDevice => 'This device';

  @override
  String get eventDelete => 'Delete event';

  @override
  String get eventDeleteClipNote =>
      'Its clip stays in the cloud until it expires.';

  @override
  String get eventDeleteConfirm => 'Delete';

  @override
  String get eventDeleteFailed => 'Could not delete the event';

  @override
  String get eventDeleteMessage =>
      'Delete this event? It will be hidden on every device.';

  @override
  String get eventDeleteTitle => 'Delete event?';

  @override
  String get eventDeletedEverywhere => 'Event deleted on every device';

  @override
  String get eventDetailCaptureAll => 'Every device takes a clip';

  @override
  String get eventDetailClipMissing => 'Clip recording missing';

  @override
  String eventDetailSure(int percent) {
    return '$percent % sure';
  }

  @override
  String get eventDevice => 'Device';

  @override
  String get eventDeviceUnknown => 'Device unknown';

  @override
  String eventFlagIdentify(String label) {
    return '$label · Identify';
  }

  @override
  String get eventFlagUnidentified => 'Unidentified subject';

  @override
  String get eventFlagUnidentifiedTooltip => 'Unidentified subject — identify';

  @override
  String get eventLocationDevice => 'The device\'s position';

  @override
  String get eventLocationMap => 'Set on the map';

  @override
  String get eventLocationPinned => 'Pinned';

  @override
  String get eventNoLocation => 'No location for this event';

  @override
  String get eventOsUnknown => 'Operating system unknown';

  @override
  String get eventRecognitionComplete => 'Recognition ran in full';

  @override
  String eventRecognitionFailed(String reason) {
    return 'Recognition failed: $reason';
  }

  @override
  String get eventRecognitionNotRun => 'Recognition hasn\'t run';

  @override
  String get eventRecognitionPartial => 'Recognition ran in part';

  @override
  String get eventRecognitionRerunning => 'Running recognition…';

  @override
  String get eventRecognitionTapToRerun => 'Tap to run recognition';

  @override
  String get eventSubjectsAllTagged =>
      'People and pets: everyone known is already named';

  @override
  String eventSubjectsFound(String names) {
    return 'People and pets: $names';
  }

  @override
  String get eventSubjectsNoReferences =>
      'People and pets: no one named yet to look for';

  @override
  String get eventSubjectsNone =>
      'People and pets: searched, no one recognized';

  @override
  String get eventSubjectsNotSearched => 'People and pets: not searched';

  @override
  String get eventSuggestionClipMissing => 'The clip is missing';

  @override
  String get eventSuggestionNo => 'No';

  @override
  String eventSuggestionNot(String name) {
    return 'Not $name';
  }

  @override
  String eventSuggestionTagged(String name) {
    return 'Tagged as $name';
  }

  @override
  String eventSuggestionYes(String name) {
    return 'Yes, it\'s $name';
  }

  @override
  String eventTagsFound(String labels) {
    return 'Object tags: $labels';
  }

  @override
  String get eventTagsNone => 'Object tags: searched, nothing seen';

  @override
  String get eventTagsNotSearched => 'Object tags: not searched';

  @override
  String get eventThisDevice => 'this device';

  @override
  String get eventTitleAppStarted => 'Application started';

  @override
  String get eventTitleCaptureAll => 'Capture all';

  @override
  String get eventTitleClipRequested => 'Clip requested';

  @override
  String get eventTitleConsentGiven => 'Recording consent given';

  @override
  String get eventTitleGeneric => 'Event';

  @override
  String eventTitleIsThis(String name) {
    return 'Is this $name?';
  }

  @override
  String get eventTitleMotion => 'Motion detected';

  @override
  String get eventTitleScheduled => 'Scheduled clip';

  @override
  String get eventTitleSignedIn => 'Signed in';

  @override
  String get eventTitleSignedOut => 'Signed out';

  @override
  String get eventTitleStartup => 'Startup clip';

  @override
  String get eventWhere => 'Where';

  @override
  String eventsCountTooltip(int shown, int all) {
    return '$shown of $all events shown';
  }

  @override
  String get eventsDeleteAll => 'Delete the events shown';

  @override
  String get eventsDeleteAllClipNote =>
      'Their clips stay in the cloud until they expire.';

  @override
  String get eventsDeleteAllMessage =>
      'Delete all the events shown? They will be hidden on every device.';

  @override
  String eventsDeleteAllTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count events?',
      one: 'Delete 1 event?',
    );
    return '$_temp0';
  }

  @override
  String get eventsDeleteFailed => 'Could not delete the events';

  @override
  String eventsDeletedEverywhere(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count events deleted on every device',
      one: '1 event deleted on every device',
      zero: 'No events deleted',
    );
    return '$_temp0';
  }

  @override
  String get eventsHideNoOne => 'Hide events with no one in them';

  @override
  String get eventsHideSystem => 'Hide system events';

  @override
  String get eventsNoGrabs => 'No grabs yet: system events are hidden';

  @override
  String eventsNoMatch(String query) {
    return 'No events match \"$query\"';
  }

  @override
  String get eventsNoOneHidden =>
      'No one seen yet: events with no one are hidden';

  @override
  String get eventsNone => 'No events';

  @override
  String get eventsSearch => 'Search events';

  @override
  String get eventsSearchClear => 'Clear search';

  @override
  String get eventsShowDevice => 'Show this device\'s events';

  @override
  String get eventsShowEveryDevice => 'Show every device\'s events';

  @override
  String get eventsShowNoOne => 'Show events with no one in them';

  @override
  String get eventsShowSystem => 'Show system events';

  @override
  String get feedbackAdmin => 'Admin';

  @override
  String get feedbackAnswered => 'Answered';

  @override
  String get feedbackAwaitingReply => 'Awaiting a reply';

  @override
  String get feedbackMember => 'Member';

  @override
  String get feedbackReply => 'Reply';

  @override
  String feedbackSendFailed(String error) {
    return 'Couldn\'t send it ($error).';
  }

  @override
  String get feedbackSentTooMuch =>
      'You\'ve sent a lot today. Try again tomorrow.';

  @override
  String get feedbackTeam => 'Presence team';

  @override
  String get feedbackTooManyTries => 'Too many tries. Wait a minute.';

  @override
  String get feedbackYou => 'You';

  @override
  String get goproAbout =>
      'A streamer of yours fetches your GoPro cameras\' new videos over its network: each camera becomes a device, and its videos with a person or an animal become events. A GoPro HERO9 or newer, on the home network (HERO12 or newer), plugged in by USB, or on its own Wi-Fi. A HERO5 to HERO8: plug it into the streamer and add it under USB cameras.';

  @override
  String get goproAddressHelp =>
      'Its IP address: on the home network as the GoPro Quik app shows it; by USB 172.2x.1yz.51; on the camera\'s Wi-Fi 10.5.5.9.';

  @override
  String get goproCameras => 'Its GoPro cameras:';

  @override
  String goproError(String error) {
    return 'GoPro: $error';
  }

  @override
  String get goproNoStreamer =>
      'Set up a streamer first (Profile › Streamer); it fetches the GoPro cameras\' videos.';

  @override
  String get goproNone => 'No GoPro cameras yet.';

  @override
  String get goproPassword => 'Camera password (home network only)';

  @override
  String healthApiAnswered(String mode) {
    return 'Auth API: answered ($mode mode)';
  }

  @override
  String get healthApiChecking => 'Auth API: checking';

  @override
  String healthApiUnreachable(String error) {
    return 'Auth API: unreachable ($error)';
  }

  @override
  String get healthAuthApiName => 'Auth API';

  @override
  String get healthAwsOff => 'events stay on this device';

  @override
  String get healthAwsSet => 'AWS: set; syncs once signed in';

  @override
  String healthAwsSyncFailed(String error) {
    return 'AWS: sync failed ($error)';
  }

  @override
  String get healthAwsSynced => 'AWS: synced';

  @override
  String get healthAwsSyncing => 'AWS: syncing';

  @override
  String get healthChecking => 'Checking…';

  @override
  String healthChecks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count checks',
      one: '1 check',
    );
    return '$_temp0';
  }

  @override
  String get healthDevicesHere => 'In the events on this device';

  @override
  String get healthDevicesProfile => 'In the profile\'s events';

  @override
  String healthDevicesSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count devices in the events',
      one: '1 device in the events',
    );
    return '$_temp0';
  }

  @override
  String get healthDevicesTitle => 'Devices';

  @override
  String healthDevicesTooltip(String what) {
    return '$what, here and synced from the cloud';
  }

  @override
  String healthLastUpdate(String time) {
    return 'Last update $time';
  }

  @override
  String healthLiveConnected(String counts) {
    return 'Live: connected ($counts)';
  }

  @override
  String get healthLiveConnecting => 'Live: connecting';

  @override
  String healthLiveCounts(int received, int sent) {
    return '$received received, $sent sent';
  }

  @override
  String healthLiveFailed(String error) {
    return 'Live: failed ($error); events arrive with each sync';
  }

  @override
  String healthLiveIdle(String next, String mode, String counts) {
    return 'Live: idle · next in $next ($mode; $counts)';
  }

  @override
  String get healthLiveName => 'Live';

  @override
  String get healthLiveNever =>
      'Live: off (Never); events arrive with each sync (15 s)';

  @override
  String get healthLiveNotSet =>
      'Live: not set; events arrive with each sync (15 s)';

  @override
  String get healthLiveOff => 'Live: set; connects once synced';

  @override
  String healthMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get healthOidcOff => 'sign-in is off';

  @override
  String get healthOidcSet => 'OIDC: Google sign-in set';

  @override
  String get healthRbacrDev => 'RBACR: not used in DEV mode (nobody signs in)';

  @override
  String get healthRbacrFree =>
      'RBACR: set; this profile is Free (its devices share events every 15 min)';

  @override
  String get healthRbacrMissing =>
      'RBACR: not set on the auth API; nobody who signs in has a role';

  @override
  String get healthRbacrPremium =>
      'RBACR: set; this profile is Premium (cloud backup)';

  @override
  String get healthRbacrPro => 'RBACR: set; this profile is Pro (cloud backup)';

  @override
  String get healthRbacrSet => 'RBACR: set; gives the roles';

  @override
  String get healthRbacrUnknown => 'RBACR: the auth API doesn\'t say';

  @override
  String get healthRunFailed => 'failed';

  @override
  String get healthRunPassed => 'all passed';

  @override
  String healthSeconds(int seconds) {
    return '$seconds s';
  }

  @override
  String healthSettingNotInBuild(String name, String off) {
    return '$name: not set in this build; $off';
  }

  @override
  String healthSettingNotSet(String name, String off) {
    return '$name: not set; $off';
  }

  @override
  String healthSettingOnlyApi(String name, String off) {
    return '$name: set in the auth API but not in this build; $off';
  }

  @override
  String healthSettingOnlyBuild(String name) {
    return '$name: set in this build but not in the auth API';
  }

  @override
  String get healthTapForDetails => 'Tap for details.';

  @override
  String get healthTimeline => 'Timeline';

  @override
  String healthTimelineSummary(String checks, String interval) {
    return '$checks · every $interval';
  }

  @override
  String get healthTitle => 'Health';

  @override
  String get healthToneChecking => 'Checking';

  @override
  String get healthToneFailed => 'Failed';

  @override
  String get healthToneIdle => 'Idle';

  @override
  String get healthToneMismatch => 'Mismatch';

  @override
  String get healthToneOff => 'Off';

  @override
  String get healthToneOk => 'OK';

  @override
  String get healthToneSyncing => 'Syncing';

  @override
  String get healthUnknownError => 'unknown error';

  @override
  String get healthWarningFailed => 'Health check failed';

  @override
  String get helpIntro =>
      'Questions, ideas or something not working? Send a message; an administrator will answer here.';

  @override
  String helpLoadFailed(String error) {
    return 'Couldn\'t load messages ($error).';
  }

  @override
  String get helpMessage => 'Message';

  @override
  String get helpNoMessages => 'No messages yet.';

  @override
  String get helpNotSignedIn => 'Not signed in.';

  @override
  String get helpReload => 'Reload';

  @override
  String get helpSend => 'Send';

  @override
  String get helpTitle => 'Write to the Presence team';

  @override
  String homeAskedGrabs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Asked $count devices for a fresh grab…',
      one: 'Asked 1 device for a fresh grab…',
      zero: 'Asked every device for a fresh grab',
    );
    return '$_temp0';
  }

  @override
  String get homeBatteryCharging => 'charging';

  @override
  String get homeBatteryFull => 'full';

  @override
  String homeBatteryLevel(int level) {
    return 'Battery $level %';
  }

  @override
  String get homeBatteryOnBattery => 'on battery';

  @override
  String get homeBatteryPlugged => 'plugged in, not charging';

  @override
  String homeBatteryTemperature(String temperature) {
    return 'Battery temperature $temperature';
  }

  @override
  String homeBatteryTemperatureHot(String temperature) {
    return 'Battery temperature $temperature, hot';
  }

  @override
  String get homeClipAll => 'Capture all';

  @override
  String get homeClipManual => 'Clip started';

  @override
  String get homeClipMotion => 'Motion detected';

  @override
  String homeClipSaving(String started, int seconds) {
    return '$started · saving the next $seconds s';
  }

  @override
  String get homeClipScheduled => 'Scheduled clip';

  @override
  String get homeClipStartup => 'Startup clip';

  @override
  String homeJoinedAccount(String email, String deviceId) {
    return 'This device is now one of $email\'s: $deviceId';
  }

  @override
  String homeJoinedOpen(String deviceId) {
    return 'Presence is open on this device: $deviceId';
  }

  @override
  String homeMessageTapToView(String label) {
    return '$label. Tap to view it.';
  }

  @override
  String get homeScreenOffHint =>
      'Unattended: capturing with the screen off. Tap to wake.';

  @override
  String homeSignInFailed(String error) {
    return 'Sign-in failed: $error';
  }

  @override
  String get homeUnattendedWoken =>
      'Unattended: dark again 15 s after the last touch';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageLabel => 'App language';

  @override
  String get languageNote =>
      'Names, tags and device IDs show as they were written.';

  @override
  String get languagePortuguese => 'Português';

  @override
  String get languageSection => 'Language';

  @override
  String get languageSpanish => 'Español';

  @override
  String get languageSystem => 'Same as the device';

  @override
  String get legalPrivacy => 'Privacy Policy';

  @override
  String get legalTerms => 'Terms of Service';

  @override
  String get logClear => 'Clear';

  @override
  String get logCopied => 'Log copied';

  @override
  String get logCopy => 'Copy';

  @override
  String get logEmpty => 'Nothing logged yet.';

  @override
  String get logTitle => 'Log';

  @override
  String logTitleCount(int count) {
    return 'Log · $count latest';
  }

  @override
  String get maintenanceBody =>
      'We\'ll be back soon. This page comes back on its own.';

  @override
  String get maintenanceTitle => 'Sorry, Presence is down for maintenance.';

  @override
  String get monitoringSyncAsked =>
      'Syncing: this device now, and the others were asked to';

  @override
  String get monitoringSyncHere =>
      'Syncing this device now; the others couldn\'t be asked (live sync is off or offline)';

  @override
  String get monitoringSyncTooltip => 'Sync all devices';

  @override
  String get navAdmin => 'Admin';

  @override
  String get navCamera => 'Cams';

  @override
  String get navHelp => 'Help';

  @override
  String get navHelpTitle => 'Feedback & Help';

  @override
  String get navLog => 'Log';

  @override
  String get navMonitoring => 'Events';

  @override
  String get navProfile => 'Profile';

  @override
  String get navSettings => 'Setup';

  @override
  String navSignedInAs(String identity) {
    return 'Signed in as $identity';
  }

  @override
  String get netcamAdd => 'Add camera';

  @override
  String get netcamAddress => 'Camera address';

  @override
  String netcamCameraError(String error) {
    return 'Can\'t fetch: $error';
  }

  @override
  String get netcamChannel => 'Channel (an NVR\'s camera)';

  @override
  String get netcamChannelHelp =>
      '0 for a camera on its own, or an NVR\'s first camera.';

  @override
  String netcamChannelOf(int channel) {
    return 'channel $channel';
  }

  @override
  String get netcamChecking => 'Reaching the camera…';

  @override
  String netcamLastFetch(String time) {
    return 'Videos last fetched at $time.';
  }

  @override
  String get netcamName => 'Camera name';

  @override
  String get netcamNotSent =>
      'Couldn\'t send it: the streamer\'s key isn\'t here yet, or cloud sync is off. Try again in a minute.';

  @override
  String get netcamPasswordNote =>
      'Sealed with the streamer\'s key (only your devices can open it) and deleted from the cloud once the streamer has it.';

  @override
  String get netcamRemove => 'Remove';

  @override
  String get netcamStreamer => 'The streamer that fetches them';

  @override
  String get netcamUsername => 'User';

  @override
  String netcamWaiting(String device) {
    return 'Sent to $device; it looks every 30 s…';
  }

  @override
  String get reolinkAbout =>
      'A streamer of yours fetches the recordings your Reolink cameras (or NVR) make on motion, over its network: each camera becomes a device, and its recordings with a person or an animal become events. The camera records to its SD card or the NVR\'s disk, with HTTPS on (its network settings).';

  @override
  String get reolinkAddressHelp =>
      'Its IP address on your network, as the Reolink app shows it (Settings › Network information).';

  @override
  String get reolinkCameras => 'Its Reolink cameras:';

  @override
  String reolinkError(String error) {
    return 'Reolink: $error';
  }

  @override
  String get reolinkNoStreamer =>
      'Set up a streamer first (Profile › Streamer); it fetches the Reolink cameras\' recordings.';

  @override
  String get reolinkNone => 'No Reolink cameras yet.';

  @override
  String get reolinkPassword => 'Camera password';

  @override
  String get settingsAddDeviceCopy => 'Copy link';

  @override
  String get settingsAddDeviceLinkCopied => 'Link copied';

  @override
  String settingsAddDeviceQr(String link) {
    return 'QR code for $link';
  }

  @override
  String get settingsAddDeviceScan =>
      'Scan with another device to open Presence there. It becomes a new device, with its own ID.';

  @override
  String settingsAddDeviceScanAs(String email) {
    return 'Scan with another device to open Presence there as $email. It becomes a new device, with its own ID.';
  }

  @override
  String get settingsAddDeviceShare => 'Share';

  @override
  String get settingsAddDeviceShareTitle => 'Open Presence';

  @override
  String get settingsAddDeviceTitle => 'Add a device';

  @override
  String get settingsAdvancedSection => 'Advanced';

  @override
  String get settingsAskNote =>
      'Less sure than that, it asks you whether it\'s them.';

  @override
  String get settingsAutoTag => 'Tag automatically when at least';

  @override
  String settingsAutoTagValue(int percent) {
    return '$percent % sure';
  }

  @override
  String get settingsBlinkSection => 'Blink cameras';

  @override
  String get settingsBrightness => 'Brightness';

  @override
  String get settingsCameraSection => 'Camera';

  @override
  String get settingsClipAfter => 'After press';

  @override
  String get settingsClipBefore => 'Before press';

  @override
  String settingsClipsNote(int seconds) {
    return 'Clips play $seconds s in total. Changing \"Before\" takes up to that long to apply, while the cameras build up enough history.';
  }

  @override
  String get settingsClipsSection => 'Clips';

  @override
  String get settingsCloudFailed =>
      'Couldn\'t train now; it tries again later.';

  @override
  String settingsCloudLastTrained(String time) {
    return 'Last trained $time';
  }

  @override
  String get settingsCloudNoLabels =>
      'Nothing to learn yet: tag people and pets.';

  @override
  String get settingsCloudNotPremium => 'Cloud recognition is Premium only.';

  @override
  String get settingsCloudNotTrained => 'Not trained yet';

  @override
  String settingsCloudStatus(String when) {
    return '$when. Learns from the people and pets you tag; checked daily.';
  }

  @override
  String get settingsCloudTitle => 'Cloud recognition (Premium)';

  @override
  String get settingsCloudTrain => 'Train now';

  @override
  String get settingsCloudTrained => 'Trained.';

  @override
  String get settingsCloudUpToDate => 'Up to date.';

  @override
  String get settingsCoordinatesAxes =>
      'Give one latitude (N or S) and one longitude (E or W)';

  @override
  String get settingsCoordinatesEmpty => 'Paste a latitude and longitude';

  @override
  String get settingsCoordinatesInvalid =>
      'Not a position: use latitude, longitude, e.g. 38.7223, -9.1393';

  @override
  String get settingsCoordinatesLatitudeRange =>
      'Latitude must be between -90 and 90';

  @override
  String get settingsCoordinatesLongitudeRange =>
      'Longitude must be between -180 and 180';

  @override
  String get settingsCoordinatesMinutes => 'Minutes and seconds go up to 59';

  @override
  String get settingsDeleteDeviceCameraNotTold =>
      'Its streamer couldn\'t be told to stop fetching this camera, so it may come back. Delete it again once the streamer is online, or remove it in Settings\' camera section.';

  @override
  String get settingsDeleteDeviceCancel => 'Cancel';

  @override
  String get settingsDeleteDeviceChoice =>
      'Keep videos: it leaves the list, its events and videos stay. Delete videos: its events and videos are hidden on every device too. Either way, it shows again if it records again.';

  @override
  String get settingsDeleteDeviceConfirm => 'Delete videos';

  @override
  String settingsDeleteDeviceDone(String deviceId, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count events',
      one: '1 event',
    );
    return 'Deleted $deviceId: $_temp0 hidden';
  }

  @override
  String settingsDeleteDeviceFailed(String deviceId) {
    return 'Could not delete $deviceId';
  }

  @override
  String get settingsDeleteDeviceKeep => 'Keep videos';

  @override
  String settingsDeleteDeviceMessage(String deviceId, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'It has $count events',
      one: 'It has 1 event',
      zero: 'It has no events here',
    );
    return 'Delete $deviceId from your devices? $_temp0.';
  }

  @override
  String settingsDeleteDeviceRemoved(String deviceId) {
    return 'Removed $deviceId from the list; its videos stay';
  }

  @override
  String get settingsDeleteDeviceTitle => 'Delete device?';

  @override
  String get settingsDevice => 'Device';

  @override
  String get settingsDeviceLoading => 'loading…';

  @override
  String get settingsGoProSection => 'GoPro cameras';

  @override
  String get settingsHistoryNote =>
      'Older events and their clips are deleted from this device when the app starts and every 3 hours.';

  @override
  String get settingsHistorySection => 'History';

  @override
  String get settingsJoinDismiss => 'Dismiss';

  @override
  String settingsJoinOtherUser(String email) {
    return 'The link was shared by another Google account than $email. Sign out, and sign in with that one, to add this device.';
  }

  @override
  String get settingsJoinOtherUserUnknown =>
      'The link was shared by another Google account than yours. Sign out, and sign in with that one, to add this device.';

  @override
  String get settingsJoinSameDevice =>
      'This is the device that shared the link. Open it on another device to add that one.';

  @override
  String get settingsJoinSignIn =>
      'To add this device, sign in with the Google account that shared the link.';

  @override
  String get settingsJoinSignOut => 'Sign out';

  @override
  String get settingsKeep => 'Keep events for';

  @override
  String settingsKeepDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String settingsKeepWeeks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count weeks',
      one: '1 week',
    );
    return '$_temp0';
  }

  @override
  String get settingsLiveAdminNote =>
      'Always connected for admins, so this device is always reachable: other devices\' events arrive within a second.';

  @override
  String get settingsLiveAlways => 'Always';

  @override
  String get settingsLiveAlwaysNote =>
      'Stays connected: other devices\' events arrive within a second.';

  @override
  String get settingsLiveConnect => 'Connect to live sync';

  @override
  String settingsLiveEvery(String interval) {
    return 'Every $interval';
  }

  @override
  String settingsLiveFreeNote(String interval) {
    return 'Free: connects every $interval to share this device\'s events with your other devices and take theirs. Premium syncs them instantly.';
  }

  @override
  String get settingsLiveNever => 'Never';

  @override
  String get settingsLiveNeverNote =>
      'Other devices\' events arrive with each sync (15 s), and this device\'s reach them the same way.';

  @override
  String settingsLiveScheduledNote(String interval) {
    return 'Connects about every $interval for what other devices sent meanwhile, and at once to send this device\'s events.';
  }

  @override
  String get settingsLiveSection => 'Live sync';

  @override
  String get settingsLocationDenied => 'Location permission was denied';

  @override
  String get settingsLocationFinding => 'Finding this device…';

  @override
  String settingsLocationMoveMap(String reason) {
    return '$reason. Move the map to set it.';
  }

  @override
  String get settingsLocationMyLocation => 'My location';

  @override
  String get settingsLocationOff => 'Location is turned off';

  @override
  String get settingsLocationPaste => 'Paste position';

  @override
  String get settingsLocationPin => 'Pin position';

  @override
  String get settingsLocationPinThis => 'Pin this position';

  @override
  String get settingsLocationPinnedLabel => 'Pinned:';

  @override
  String get settingsLocationPinnedStatus => 'Pinned · used for every event';

  @override
  String get settingsLocationPositionLabel => 'Position (latitude, longitude)';

  @override
  String get settingsLocationSection => 'Location';

  @override
  String get settingsLocationSetOnMap => 'Set on the map';

  @override
  String get settingsLocationSetThis => 'Set this position';

  @override
  String get settingsLocationThisDevice => 'This device\'s location';

  @override
  String get settingsLocationUnavailable => 'Location unavailable';

  @override
  String get settingsLocationUnknown => 'Location unknown';

  @override
  String get settingsLocationUnpin => 'Unpin';

  @override
  String get settingsLocationUnpinToLocate => 'Unpin to use my location';

  @override
  String get settingsMapAttribution => '© OpenStreetMap contributors';

  @override
  String get settingsMapZoomIn => 'Zoom in';

  @override
  String get settingsMapZoomOut => 'Zoom out';

  @override
  String settingsMemoryAbout(String amount) {
    return 'about $amount';
  }

  @override
  String settingsMemoryFree(String amount) {
    return '$amount free';
  }

  @override
  String get settingsMotionCooldown => 'At most one automatic clip every';

  @override
  String settingsMotionNow(int percent) {
    return 'Motion now: $percent %';
  }

  @override
  String get settingsMotionNowWaiting => 'Motion now: waiting for the camera…';

  @override
  String get settingsMotionSection => 'Motion';

  @override
  String get settingsMotionSwitch => 'Clip automatically on motion';

  @override
  String get settingsMotionThreshold => 'Motion threshold';

  @override
  String settingsMotionThresholdValue(int percent) {
    return '$percent % of the picture';
  }

  @override
  String get settingsNextClipDue => 'Next clip: due, once a camera is open';

  @override
  String settingsNextClipIn(String time) {
    return 'Next clip in $time';
  }

  @override
  String get settingsNightMode => 'Night mode';

  @override
  String get settingsNightModeSubtitle =>
      'When it\'s dark: the brightest picture, and a light while a clip records (the torch, or the screen facing the scene)';

  @override
  String get settingsObjectsSubtitle =>
      'Human, cat, dog, bicycle, bottle… for search';

  @override
  String get settingsObjectsSwitch => 'Tag objects in new clips';

  @override
  String get settingsProfile => 'Profile';

  @override
  String get settingsProfileNone => 'none until signed in';

  @override
  String get settingsRecognitionSection => 'Recognition';

  @override
  String get settingsRecognitionSubtitle =>
      'People and pets tagged before, found on this device';

  @override
  String get settingsRecognitionSwitch => 'Recognize subjects in new clips';

  @override
  String get settingsRecognitionUnavailable =>
      'Not available on this device yet';

  @override
  String get settingsReolinkSection => 'Reolink cameras';

  @override
  String get settingsSameAsClip => 'Same as pressing Clip';

  @override
  String get settingsScheduleEvery => 'One clip every';

  @override
  String get settingsScheduleSection => 'Scheduled clips';

  @override
  String get settingsScheduleSwitch => 'Clip at start and on a timer';

  @override
  String get settingsShowLog => 'Show the Log tab';

  @override
  String get settingsShowLogSubtitle => 'The app\'s latest messages and health';

  @override
  String get settingsStartupClip => 'Startup clip: once the camera is ready';

  @override
  String get settingsSubjectEvents => 'How many events to load at once';

  @override
  String get settingsSubjectsSection => 'Events';

  @override
  String get settingsUsbCamSection => 'USB cameras';

  @override
  String storeDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String storeDeleteAccountSubscription(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'App Store',
      'google': 'Google Play',
      'other': 'store',
    });
    return 'Deleting your account doesn\'t cancel a Premium subscription: cancel it first in your $_temp0 subscription settings.';
  }

  @override
  String get storeEveryDay => 'day';

  @override
  String storeEveryDays(int count) {
    return '$count days';
  }

  @override
  String get storeEveryMonth => 'month';

  @override
  String storeEveryMonths(int count) {
    return '$count months';
  }

  @override
  String get storeEveryWeek => 'week';

  @override
  String storeEveryWeeks(int count) {
    return '$count weeks';
  }

  @override
  String get storeEveryYear => 'year';

  @override
  String storeEveryYears(int count) {
    return '$count years';
  }

  @override
  String get storeFailed =>
      'Couldn\'t confirm the purchase with Presence yet. It\'s tried again automatically.';

  @override
  String get storeLoading => 'Loading the plans…';

  @override
  String get storeManage => 'Manage subscription';

  @override
  String storeMonths(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count months',
      one: '1 month',
    );
    return '$_temp0';
  }

  @override
  String get storeNotVerified => 'The store didn\'t confirm this purchase.';

  @override
  String get storeNothingToRestore => 'No active subscription to restore.';

  @override
  String get storeOtherAccount =>
      'This subscription belongs to another Presence account.';

  @override
  String get storePending =>
      'Purchase pending: Premium starts once the store confirms it.';

  @override
  String storePlanFreeText(int free, int premium) {
    return 'Free: each device keeps its events, and up to $free devices share them every 15 minutes. Premium syncs them instantly, with cloud backup and up to $premium devices.';
  }

  @override
  String get storePlanMonthly => 'Premium monthly';

  @override
  String storePlanPrice(String plan, String price, String period) {
    return '$plan: $price / $period';
  }

  @override
  String get storePlanYearly => 'Premium yearly';

  @override
  String get storePrivacy => 'Privacy Policy';

  @override
  String get storePurchaseFailed => 'The purchase didn\'t go through.';

  @override
  String get storePurchased => 'Thank you! Premium is on.';

  @override
  String storeRenews(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'App Store',
      'google': 'Google Play',
      'other': 'store',
    });
    return 'Subscriptions renew automatically until you cancel them in your $_temp0 account settings, at least 24 hours before the period ends.';
  }

  @override
  String get storeRestore => 'Restore purchases';

  @override
  String get storeRestored => 'Your subscription is restored.';

  @override
  String get storeTerms => 'Terms of Service';

  @override
  String storeTrial(String trial, String price, String period) {
    return '$trial free, then $price / $period.';
  }

  @override
  String get storeUnavailable => 'Purchases aren\'t available right now.';

  @override
  String storeWeeks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count weeks',
      one: '1 week',
    );
    return '$_temp0';
  }

  @override
  String storeYears(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count years',
      one: '1 year',
    );
    return '$_temp0';
  }

  @override
  String streamerLeader(String device) {
    return 'Leader ($device)';
  }

  @override
  String streamerLeaderUnknown(String device) {
    return 'Leader (none yet; $device for now)';
  }

  @override
  String get streamerPickerHelp =>
      'Leader follows whichever streamer leads. Only the leading streamer fetches, so one picked here fetches while it leads.';

  @override
  String subjectsEvents(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count events',
      one: '1 event',
    );
    return '$_temp0';
  }

  @override
  String subjectsLatestEvents(int shown, int total) {
    return 'Latest $shown of $total events';
  }

  @override
  String get subjectsNoLocation => 'No location';

  @override
  String get subjectsNobodyTagged =>
      'Nobody is tagged with this name any more.';

  @override
  String subjectsOpen(String name) {
    return 'Open $name';
  }

  @override
  String subjectsOpenEvent(String label) {
    return 'Open event $label';
  }

  @override
  String get subjectsRecognizedAuto => 'Recognized automatically';

  @override
  String get usbcamAbout =>
      'A streamer of yours fetches the new videos of cameras plugged into it by USB, with no network or address: each camera becomes a device, and its videos with a person or an animal become events. Cameras that show up as a camera or a media device (PTP or MTP), such as a GoPro HERO5 to HERO8 or most digital cameras; turned on, plugged into the streamer.';

  @override
  String get usbcamAdd => 'Add';

  @override
  String get usbcamCameras => 'Its USB cameras:';

  @override
  String get usbcamDetected => 'Plugged into it, to add:';

  @override
  String usbcamError(String error) {
    return 'USB cameras: $error';
  }

  @override
  String get usbcamNoStreamer =>
      'Set up a streamer first (Profile › Streamer); the cameras are plugged into it.';

  @override
  String get usbcamNone => 'No USB cameras added yet.';

  @override
  String get usbcamNoneDetected =>
      'No other camera plugged into it. Plug one in and turn it on: it shows here within a minute.';

  @override
  String get usbcamStreamer => 'The streamer they\'re plugged into';

  @override
  String get usbcamUnplugged =>
      'Not plugged in: its new videos are fetched once it\'s back.';
}
