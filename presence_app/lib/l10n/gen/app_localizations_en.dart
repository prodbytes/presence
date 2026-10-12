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
      'Presence turns a phone, tablet, laptop or Raspberry Pi into an always-on camera for a place you look after: live feeds, clips that include the moments before, and clips on motion. Only record where you\'re allowed to.';

  @override
  String get authAccessAdmin => 'Admin Access';

  @override
  String get authAccessFree => 'Free Access';

  @override
  String get authAccessPremium => 'Premium Access';

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
  String authDevicesHidden(int count, String plan, int limit) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count devices\' events are hidden: $plan shows your first $limit devices.',
      one:
          '1 device\'s events are hidden: $plan shows your first $limit devices.',
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
  String get authHiddenTooltip =>
      'Past the plan\'s device limit: it syncs, but its events are hidden here';

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
  String authMoreHidden(int count, String plan, int limit) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count more devices sync, but their events are hidden: $plan shows your first $limit.',
      one:
          '1 more device syncs, but its events are hidden: $plan shows your first $limit.',
    );
    return '$_temp0';
  }

  @override
  String get authNoEvents => 'No events';

  @override
  String get authNoFeedback => 'No feedback yet.';

  @override
  String get authNoRoles => 'No roles yet';

  @override
  String get authNotSignedIn => 'Not signed in.';

  @override
  String authOpenHost(String host) {
    return 'Open $host';
  }

  @override
  String get authOsUnknown => 'Operating system unknown';

  @override
  String authOthersHidden(String plan, int limit) {
    return 'Your other devices\' events are hidden on this one: $plan shows your first $limit devices.';
  }

  @override
  String get authOwner => 'Owner';

  @override
  String authPastLimit(int limit) {
    return 'This device is past your first $limit: it syncs, but its events are hidden on your other devices, and theirs here.';
  }

  @override
  String get authPaymentsDefaults =>
      'Not saved yet: these are the deploy\'s links.';

  @override
  String get authPaymentsIntro =>
      'The Stripe Payment Links free members upgrade to Premium with. Leave one empty not to offer that plan.';

  @override
  String get authPaymentsInvalid => 'Empty, or an https link on stripe.com';

  @override
  String get authPaymentsMonthly => 'Monthly plan link';

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
  String authPlanFreeText(int free, int premium) {
    return 'Free: up to $free devices sync with each other while online. Premium adds cloud backup and up to $premium devices: US\$20 a month, the first week free.';
  }

  @override
  String get authPlanPremium => 'Premium';

  @override
  String authPlanPremiumText(int limit) {
    return 'Premium: cloud backup, and up to $limit devices sync.';
  }

  @override
  String get authPremiumMonthly => 'Premium monthly';

  @override
  String authPremiumShowsUpTo(String text, int limit) {
    return '$text Premium shows up to $limit.';
  }

  @override
  String get authPremiumYearly => 'Premium yearly';

  @override
  String get authProfile => 'Profile';

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
  String get authSignIn => 'Sign in';

  @override
  String get authSignInToPresence => 'Sign in to Presence';

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
      'Paste this in a terminal on a Raspberry Pi with a camera (Raspberry Pi OS, 32- or 64-bit), even one without a screen. It installs the Presence streamer as a new device of this profile, which records from every boot and keeps the clips with people and animals. Nobody signs in on the Pi.';

  @override
  String get authStreamerCopied =>
      'Command copied: paste it on the Raspberry Pi';

  @override
  String get authStreamerCopy => 'Copy command';

  @override
  String get authStreamerCreate => 'Create command';

  @override
  String authStreamerFailed(String error) {
    return 'Couldn\'t create the command ($error)';
  }

  @override
  String get authStreamerKeyOnce =>
      'It holds this device\'s key, shown only now: keep it private. Deleting the device stops it; creating another command makes another device.';

  @override
  String get authStreamerTitle => 'Stream from a Raspberry Pi';

  @override
  String get authSubscribe => 'Subscribe';

  @override
  String get authSubscribeButton => 'Subscribe at nu01.com';

  @override
  String authSubscribeText(String email) {
    return '$email doesn\'t have access to Presence yet. Subscribe at nu01.com: Free, or Premium for cloud backup and more devices. Then check again here.';
  }

  @override
  String get authSyncFree => 'Your devices sync with each other while online';

  @override
  String get authThisAccount => 'This account';

  @override
  String get authThisDevice => 'this device';

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
  String get cameraActionAll => 'Show all devices';

  @override
  String get cameraActionNormal => 'Back to normal: this camera';

  @override
  String get cameraActionStopped => 'Stop: no capturing or syncing';

  @override
  String get cameraActionUnattended =>
      'Go unattended: screen off, still capturing';

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
  String cameraLiveLabel(String device) {
    return '$device · live';
  }

  @override
  String get cameraModeAll => 'All';

  @override
  String get cameraModeNormal => 'Normal';

  @override
  String get cameraModeStopped => 'Stopped';

  @override
  String get cameraModeUnattended => 'Unattended';

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
  String get clipNameHint => 'Name';

  @override
  String get clipNameMore => 'Name more subjects on this frame';

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
    return 'Click each person or pet on the video to name them as a subject (frame at $time).';
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
  String get connectivityFree => 'Free: devices sync over live sync';

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
  String get eventCloudNotSynced => 'Not in the cloud';

  @override
  String get eventCloudSynced => 'In the cloud';

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
  String get eventRecognitionNotRun => 'Recognition hasn\'t run';

  @override
  String get eventRecognitionPartial => 'Recognition ran in part';

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
  String get eventsHideSystem => 'Hide system events';

  @override
  String get eventsNoGrabs => 'No grabs yet: system events are hidden';

  @override
  String eventsNoMatch(String query) {
    return 'No events match \"$query\"';
  }

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
      'RBACR: set; this profile is Free (its devices sync with each other)';

  @override
  String get healthRbacrMissing =>
      'RBACR: not set on the auth API; nobody who signs in has a role';

  @override
  String get healthRbacrPremium =>
      'RBACR: set; this profile is Premium (cloud backup)';

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
  String get navAdmin => 'Admin';

  @override
  String get navCamera => 'Camera';

  @override
  String get navHelp => 'Help';

  @override
  String get navHelpTitle => 'Feedback & Help';

  @override
  String get navLog => 'Log';

  @override
  String get navMonitoring => 'Monitoring';

  @override
  String get navProfile => 'Profile';

  @override
  String get navSettings => 'Settings';

  @override
  String navSignedInAs(String identity) {
    return 'Signed in as $identity';
  }

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
  String get settingsDeleteDeviceCancel => 'Cancel';

  @override
  String get settingsDeleteDeviceConfirm => 'Delete';

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
  String settingsDeleteDeviceMessage(String deviceId, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Its $count events will be hidden',
      one: 'Its 1 event will be hidden',
    );
    return 'Delete device $deviceId? $_temp0 on every device.';
  }

  @override
  String get settingsDeleteDeviceNote =>
      'Its clips stay in the cloud. If it records again, it shows again with its new events.';

  @override
  String get settingsDeleteDeviceTitle => 'Delete device?';

  @override
  String get settingsDevice => 'Device';

  @override
  String get settingsDeviceLoading => 'loading…';

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
  String get settingsSubjectsSection => 'Subjects';

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
}
