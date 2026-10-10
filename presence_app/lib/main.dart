import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:idb_shim/idb_shim.dart' show IdbFactory;

import 'app_log.dart';
import 'app_version.dart';
import 'battery.dart';
import 'auth/api_config.dart';
import 'barrel_roll.dart';
import 'auth/auth_service.dart';
import 'auth/google_auth_service.dart';
import 'auth/membership_client.dart';
import 'feedback/feedback_client.dart';
import 'auth/profile_client.dart';
import 'auth/roles_service.dart';
import 'camera_feeds.dart';
import 'copies_badge.dart';
import 'cloud/cloud_config.dart';
import 'cloud/cloud_sync.dart';
import 'cloud/cognito.dart';
import 'cloud/event_copies.dart';
import 'cloud/live_mqtt.dart';
import 'cloud/live_sync.dart';
import 'cloud/s3.dart';
import 'config.dart';
import 'consent/consent_screen.dart';
import 'event_details.dart';
import 'cameras/cameras.dart';
import 'events.dart';
import 'home/home_screen.dart';
import 'identity/join_link.dart';
import 'identity/launch_url.dart';
import 'location/device_location.dart';
import 'maintenance.dart';
import 'recognition/recognizer.dart';
import 'screen_off.dart';
import 'tab_memory.dart';
import 'storage/media_platform.dart';
import 'storage/media_store.dart';
import 'storage/persistence.dart';
import 'storage/retention.dart';
import 'theme.dart';

export 'home/camera_buttons.dart' show CameraMode;
export 'home/camera_messages.dart' show CameraMessage, CameraMessagePill;
export 'home/clip_button.dart'
    show ClipButton, ClipButtonColors, ClipButtonStatus, ClipTone;
export 'home/dev_mode_label.dart' show DevModeLabel;
export 'home/home_screen.dart' show HomeScreen;
export 'home_tabs.dart' show HomeTab;

void main() {
  // Everything the app logs also goes to the admins' Log tab.
  AppLog.capture(() {
    WidgetsFlutterBinding.ensureInitialized();
    // On Android, to files on the phone too, for debugging after the fact.
    AppLog.instance.persistToDevice();
    runApp(const PresenceApp());
  });
}

class PresenceApp extends StatefulWidget {
  const PresenceApp({
    super.key,
    this.cameras,
    this.storage,
    this.mediaIo,
    this.now,
    this.tabMemory,
    this.auth,
    this.cloud,
    this.live,
    this.rolesClient,
    this.membershipClient,
    this.feedbackClient,
    this.profileClient,
    this.consentGiven = false,
    this.locator,
    this.mapTiles,
    this.battery,
    this.links,
    this.recognizer,
    this.screenOff,
  });

  /// Overrides the Screen off button's screen control (used by tests);
  /// defaults to the platform's ([ScreenOff]).
  final ScreenOff? screenOff;

  /// Makes the recognizer that searches each new clip (used by tests, with
  /// fake models); defaults to [SubjectRecognizer] with the real ones.
  final SubjectRecognizer Function(
    AppEventBus bus,
    EventLog log,
    ConfigController config,
  )?
  recognizer;

  /// Overrides the links the app is opened with (used by tests); defaults
  /// to `app_links`: the page's address on web, App Links on Android.
  final Stream<Uri>? links;

  /// Skips the recording consent, as if this device had given it (used by
  /// tests). The app itself always checks storage.
  final bool consentGiven;

  /// Overrides the battery reading shown over the camera (used by tests).
  final BatteryReader? battery;

  /// Overrides the device's positioning (used by tests).
  final Locator? locator;

  /// Overrides the maps' tiles (used by tests); defaults to OpenStreetMap.
  final Widget? mapTiles;

  /// Overrides membership requests (used by tests); defaults to
  /// `/api/auth/membership`.
  final MembershipClient? membershipClient;

  /// Overrides Feedback and Help (used by tests); defaults to
  /// `/api/auth/feedback`.
  final FeedbackClient? feedbackClient;

  /// Overrides the profile routes (used by tests); defaults to
  /// `/api/auth/profile`.
  final ProfileClient? profileClient;

  /// Overrides the auth API (used by tests); defaults to `GET /api/auth`.
  final RolesClient? rolesClient;

  /// Overrides cloud uploads (used by tests); defaults to Cognito + S3
  /// when `CloudConfig` is set, and none otherwise.
  final CloudBackend? cloud;

  /// Overrides live sync (used by tests); defaults to AWS IoT Core when the
  /// build has its endpoint (`IOT_ENDPOINT`), and none otherwise.
  final LiveSync? live;

  /// Overrides the clock (used by tests).
  final DateTime Function()? now;

  /// Overrides where the open tab is remembered across refreshes (used by
  /// tests).
  final TabMemory? tabMemory;

  /// Overrides sign-in (used by tests); defaults to Google.
  final AuthService? auth;

  /// Overrides camera access (used by tests); defaults to the device's.
  final CameraBackend? cameras;

  /// Where app data is saved (used by tests); defaults to IndexedDB on web.
  final IdbFactory? storage;

  /// Overrides reading and replaying stored recordings (used by tests).
  final MediaIo? mediaIo;

  @override
  State<PresenceApp> createState() => _PresenceAppState();
}

class _PresenceAppState extends State<PresenceApp> {
  // Owned above MaterialApp so every route can publish to the bus, and so
  // history, settings and open cameras outlive any single screen.
  final _bus = AppEventBus();
  final _config = ConfigController();
  late final _screenOff = widget.screenOff ?? ScreenOff();
  late final EventLog _log;
  late final Persistence _persistence;

  /// Who holds a copy of each event (this device, the cloud, the profile's
  /// other devices), for the copies count on event cards.
  late final EventCopies _copies = EventCopies(store: _persistence.store);
  late final EventRetention _retention;
  late final CameraRig _rig;
  late final LocationController _location;
  late final SubjectRecognizer _recognizer;

  @override
  void initState() {
    super.initState();
    // Subscribe before publishing: a broadcast stream drops events that
    // have no listener yet.
    _log = EventLog(_bus.stream);
    _auth = widget.auth ?? GoogleAuthService();
    // The signed-in account's profile, as the auth API answers.
    _roles = RolesService(
      auth: _auth,
      client: widget.rolesClient ?? HttpRolesClient(ApiConfig.baseUrl),
      // Maintenance mode reaches a running app within a minute.
      maintenanceCheckInterval: const Duration(minutes: 1),
    );
    final mediaIo = widget.mediaIo;
    _persistence = Persistence(
      factory: widget.storage != null
          ? Future.value(widget.storage)
          : newDefaultIdbFactory(),
      bus: _bus,
      config: _config,
      // Each event records who is signed in, and belongs to their
      // profile; none signed out.
      currentUser: () => _auth.user?.id,
      currentProfile: () => _roles.profile,
      // And records where the device is.
      currentLocation: () => _location.location,
      now: widget.now,
      mediaStore: mediaIo == null
          ? null
          : (store) => IdbMediaStore(store, mediaIo),
    );
    _location = LocationController(
      locator: widget.locator ?? DeviceLocator(),
      load: _persistence.loadLocation,
      save: _persistence.saveLocation,
      now: widget.now,
    );
    _location.init().ignore();
    // Settings restored from the cloud include the location set on the map.
    _persistence.onRemoteLocation = _location.applyRemote;
    // Finds the subjects on each new clip once it's recorded.
    _recognizer =
        widget.recognizer?.call(_bus, _log, _config) ??
        SubjectRecognizer(bus: _bus, log: _log, config: _config);
    _bus.publish(AppEvent.appStarted());
    _auth.addListener(_onAuthChanged);
    _rig = CameraRig(
      backend: widget.cameras ?? DeviceCameras(),
      config: _config,
      bus: _bus,
      now: widget.now,
    );
    _auth.init().ignore();
    _roles.addListener(_onProfileChanged);
    final cloud =
        widget.cloud ??
        (CloudConfig.enabled
            ? AwsCloudBackend(
                cognito: CognitoCredentials(
                  region: CloudConfig.region,
                  api: ApiConfig.baseUrl,
                  // Each device takes its place among the profile's.
                  deviceId: () => _persistence.deviceId,
                ),
                bucket: S3Bucket(
                  bucket: CloudConfig.userDataBucket,
                  region: CloudConfig.region,
                ),
              )
            : null);
    _sync = cloud == null
        ? null
        : CloudSync(
            auth: _auth,
            // Only users with a role sync.
            roles: _roles,
            backend: cloud,
            now: widget.now,
            store: _persistence.store,
            media: _persistence.media,
            changes: _persistence.changes,
            // Not what the device deletes as too old.
            keep: () => _config.config.history.keep,
            // And this device's settings, kept per device.
            settings: _persistence,
            copies: _copies,
            // Events reach the profile's other devices within a second
            // (AWS IoT Core), when this build has its endpoint.
            live:
                widget.live ??
                (CloudConfig.iotEndpoint.isEmpty
                    ? null
                    : LiveSync(
                        endpoint: CloudConfig.iotEndpoint,
                        region: CloudConfig.region,
                        stage: CloudConfig.liveStage,
                        connect: MqttLiveConnection.connect,
                      )),
            // Clips and events fetched from the cloud after sign-in join the
            // local history, like a restore from IndexedDB.
            // A Capture all request from another device takes a clip here.
            onRemote: (remote) async {
              final events = await _persistence.importRemote(
                events: remote.events,
                clips: remote.clips,
                awaitClips: remote.live,
              );
              _log.addHistory(events);
              // Clips that events from live sync were waiting for.
              await _persistence.showArrivedClips(remote.clips, _log);
              // Events changed on another device: their tags as they are
              // there now, on screen too.
              await _persistence.updateFromRemote(remote.updated, _log.events);
              _rig.answerCaptureAll(events, deviceId: _deviceId);
            },
          );
    // How live sync connects (the Connect to live sync setting, for this
    // user's roles: admins always connected, others at most every 30 s):
    // now, and at once whenever it changes (or is restored) or the roles
    // do (sign-in, a role granted or taken, sign-out). The saved setting
    // is left as it is.
    if (_sync?.live case final live?) {
      void applyLive() =>
          live.config = _config.config.live.effective(isAdmin: _roles.isAdmin);
      applyLive();
      _config.addListener(applyLive);
      _roles.addListener(applyLive);
    }
    // Only the events of the devices that show (a free profile's first
    // two): whenever the profile's devices or this device's ID are known
    // again. A device the list doesn't know yet, while there's room, asks
    // for it again.
    if (_sync case final sync?) {
      sync.addListener(_applyDeviceSlots);
      _log.addListener(_noticeDevices);
    }
    // The camera's Stopped mode (its pause, kept in the settings) stops
    // syncing too: no passes and no live sync until it's left. Now (a
    // device restarted Stopped stays quiet), and whenever it changes.
    if (_sync case final sync?) {
      void applyHalt() => sync.setHalted(_config.config.camera.paused);
      applyHalt();
      _config.addListener(applyHalt);
    }
    // A clip fetched from the cloud plays before its recording has come
    // down: it's downloaded then.
    _persistence.fetchMissingMedia = _sync?.fetchRecording;
    _persistence
      ..attachRig(_rig)
      ..restore(_log).catchError((Object e) {
        debugPrint('Presence: could not restore saved data: $e');
      });
    // Deletes events older than the History setting: now, once the history
    // is restored, and every 3 h.
    _retention = EventRetention(
      delete: _persistence.deleteEventsBefore,
      config: _config,
      now: widget.now,
    )..start();
    _persistence.deviceId.then((id) {
      _copies.deviceId = id;
      if (mounted) setState(() => _deviceId = id);
      _applyDeviceSlots();
    }, onError: (Object e) => debugPrint('Presence: no device ID: $e'));
    _checkConsent();
    requestPersistentStorage().ignore();
    // Opened with a link to add this device: the first one, and any while
    // running.
    _links = (widget.links ?? AppLinks().uriLinkStream).listen((uri) {
      final join = JoinLink.parse(uri);
      if (join != null && mounted) setState(() => _join = join);
    }, onError: (Object e) => debugPrint('Presence: no launch link: $e'));
  }

  StreamSubscription<Uri>? _links;

  /// Shows only the events of the devices the profile's slots show from
  /// this one (`DeviceSlots.visibleFrom`); all of them without slots.
  void _applyDeviceSlots() {
    final slots = _sync?.deviceSlots;
    final device = _deviceId;
    _log.visibleDevices = slots == null || device == null
        ? null
        : slots.visibleFrom(device);
  }

  /// The profile's devices in the log, for the sync to see whether one is
  /// new to its slots ([CloudSync.noticeDevices]).
  void _noticeDevices() {
    final sync = _sync;
    final profile = _roles.profile;
    if (sync?.deviceSlots == null || profile == null) return;
    sync!.noticeDevices({
      for (final e in _log.events)
        if (e.profileId == profile) ?e.deviceId,
    });
  }

  /// The link this device was opened with to join a user's devices, until
  /// it's handled or dismissed.
  JoinLink? _join;

  /// Deletes another of the signed-in profile's devices
  /// (`Persistence.deleteDevice`); nothing without a profile.
  Future<int> _deleteDevice(String deviceId) async {
    final profile = _roles.profile;
    if (profile == null) return 0;
    final deleted = await _persistence.deleteDevice(
      deviceId,
      profileId: profile,
    );
    // No presence dot from before: it shows again only if it pings or
    // answers again, with new events.
    _sync?.live?.forget(deviceId);
    // Nor is it counted as holding copies of the events left.
    _copies.forgetDevice(deviceId);
    // And the next device takes its place among those that show.
    _sync?.releaseDevice(deviceId).ignore();
    return deleted;
  }

  /// Deletes one event of the signed-in profile on every device
  /// (`Persistence.deleteEvent`); nothing without a profile (so not in
  /// DEV).
  Future<bool> _deleteEvent(AppEvent event) async {
    final profile = _roles.profile;
    if (profile == null) return false;
    final deleted = await _persistence.deleteEvent(
      event.id,
      profileId: profile,
    );
    // Nor is it counted among the copies any more.
    if (deleted) _copies.forget(event.id);
    return deleted;
  }

  void _joinHandled() {
    clearLaunchQuery();
    setState(() => _join = null);
  }

  /// This device's ID, once storage has it.
  String? _deviceId;

  /// Whether this device gave its recording consent: null while checking,
  /// before anything shows. The cameras open (and record) only once it's
  /// given.
  bool? _consented;

  Future<void> _checkConsent() async {
    var given = widget.consentGiven;
    if (!given) {
      try {
        given = await _persistence.hasConsent();
      } catch (e) {
        // Can't tell: ask.
        debugPrint('Presence: could not read the consent: $e');
      }
    }
    if (!mounted) return;
    setState(() => _consented = given);
    if (given) _openCameras();
  }

  /// Opens the cameras once the saved settings are loaded, so the camera
  /// picked with Flip last time opens first, not the default one. Storage
  /// that never answers mustn't keep the camera closed: after a few seconds
  /// it opens anyway (and switches when the settings arrive).
  void _openCameras() {
    var opened = false;
    void open() {
      if (opened || !mounted) return;
      opened = true;
      _settingsWait?.cancel();
      _rig.load();
    }

    _settingsWait?.cancel();
    _settingsWait = Timer(const Duration(seconds: 5), () {
      debugPrint('Presence: settings still loading; opening the camera');
      open();
    });
    _persistence.configLoaded.then((_) => open());
  }

  /// The longest [_openCameras] waits for the saved settings.
  Timer? _settingsWait;

  /// The user agreed on the consent screen: saved once, never asked again
  /// on this device. If saving fails, this session goes on and the next
  /// launch asks again.
  Future<void> _agree() async {
    final at = (widget.now ?? DateTime.now)();
    try {
      await _persistence.giveConsent(at);
    } catch (e) {
      debugPrint('Presence: could not save the consent: $e');
    }
    if (!mounted) return;
    _bus.publish(
      AppEvent(
        icon: Icons.verified_user,
        title: 'Recording consent given',
        detail: _deviceId,
        time: at,
      ),
    );
    setState(() => _consented = true);
    _openCameras();
  }

  /// The profile whose events were last claimed, and for whom; null
  /// signed out.
  String? _claimedFor;
  String? _claimedBy;

  /// Once the auth API answers a sign-in (or a session restored at launch)
  /// with the account's profile, the events recorded here without one
  /// become that profile's. When the same account moves to another profile
  /// (linked or moved while signed in), its events not yet uploaded to the
  /// one before come along.
  void _onProfileChanged() {
    final profile = _roles.profile;
    final user = _auth.user;
    if (profile == _claimedFor) return;
    final previous = _claimedBy == user?.id ? _claimedFor : null;
    _claimedFor = profile;
    _claimedBy = user?.id;
    if (profile == null || user == null) return;
    _persistence
        .claimForProfile(profile, user.id, from: previous)
        .catchError(
          (Object e) => debugPrint('Presence: could not claim events: $e'),
        );
  }

  late final AuthService _auth;
  late final RolesService _roles;
  late final MembershipClient _membership =
      widget.membershipClient ?? HttpMembershipClient(ApiConfig.baseUrl);
  late final FeedbackClient _feedback =
      widget.feedbackClient ?? HttpFeedbackClient(ApiConfig.baseUrl);
  late final ProfileClient _profiles =
      widget.profileClient ?? HttpProfileClient(ApiConfig.baseUrl);
  CloudSync? _sync;
  String? _signedInAs;

  /// Sign-ins and sign-outs go on the event stream too.
  void _onAuthChanged() {
    final email = _auth.user?.email;
    if (email == _signedInAs) return;
    final previous = _signedInAs;
    _signedInAs = email;
    _bus.publish(
      email != null
          ? AppEvent(icon: Icons.login, title: 'Signed in', detail: email)
          : AppEvent(icon: Icons.logout, title: 'Signed out', detail: previous),
    );
  }

  @override
  void dispose() {
    _settingsWait?.cancel();
    _auth.removeListener(_onAuthChanged);
    _links?.cancel();
    _sync?.removeListener(_applyDeviceSlots);
    _log.removeListener(_noticeDevices);
    _sync?.dispose();
    _copies.dispose();
    _roles.dispose();
    _location.dispose();
    _recognizer.dispose();
    _retention.dispose();
    _persistence.dispose();
    _rig.dispose();
    _log.dispose();
    _bus.close();
    _config.dispose();
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppEventBusScope(
      bus: _bus,
      child: SubjectRecognizerScope(
        recognizer: _recognizer,
        child: EventCopiesScope(
          copies: _copies,
          // The end of an event's details (the clip player): its map, its
          // device and deleting it, signed in with a profile.
          child: ListenableBuilder(
            listenable: _roles,
            builder: (context, app) => EventDetailsScope(
              profileId: _roles.profile,
              thisDevice: _deviceId,
              live: _sync?.live,
              log: _log,
              tiles: widget.mapTiles,
              deleteEvent: _deleteEvent,
              now: widget.now,
              child: app!,
            ),
            child: MaterialApp(
              title: AppVersion.title,
              debugShowCheckedModeBanner: false,
              theme: gruvboxSoftDarkTheme(),
              // The "do a barrel roll" search spins everything. In
              // maintenance mode, only admins get past the sorry message.
              builder: (context, app) => BarrelRoll(
                child: MaintenanceGate(roles: _roles, child: app!),
              ),
              home: switch (_consented) {
                // Nothing shows until the device's consent is known.
                null => const Scaffold(
                  body: Center(
                    child: CircularProgressIndicator(
                      key: Key('checking-consent'),
                    ),
                  ),
                ),
                false => ConsentScreen(onAgree: _agree),
                true => HomeScreen(
                  log: _log,
                  rig: _rig,
                  config: _config,
                  auth: _auth,
                  roles: _roles,
                  membership: _membership,
                  feedback: _feedback,
                  profiles: _profiles,
                  sync: _sync,
                  deviceId: _deviceId,
                  location: _location,
                  mapTiles: widget.mapTiles,
                  battery: widget.battery,
                  join: _join,
                  onJoinHandled: _joinHandled,
                  tabMemory: widget.tabMemory,
                  deleteDevice: _deleteDevice,
                  screenOff: _screenOff,
                ),
              },
            ),
          ),
        ),
      ),
    );
  }
}
