import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/auth/delete_account.dart';
import 'package:presence_app/auth/profile_client.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/auth/store_billing.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';
import 'package:presence_app/storage/persistence.dart';

import 'fakes.dart';

const _profile = 'automatic_paranoid_axolotl';

const _owner = ProfileAccount(
  email: 'ana@example.com',
  owner: true,
  current: true,
);

/// Ticks the dialog's "I understand" checkbox, scrolled into view.
Future<void> confirm(WidgetTester tester) async {
  final box = find.byKey(const Key('delete-account-confirm'));
  await tester.ensureVisible(box);
  await tester.pumpAndSettle();
  await tester.tap(box);
}

void main() {
  group('HttpProfileClient.deleteAccount', () {
    test('posts the profile shown, and asks again until the folder is '
        'empty', () async {
      final requests = <http.Request>[];
      final answers = [
        {
          'deleted': 'profile',
          'profile': _profile,
          'objects': 1000,
          'complete': false,
        },
        {
          'deleted': 'profile',
          'profile': _profile,
          'accounts': 2,
          'objects': 20,
          'complete': true,
        },
      ];
      final client = HttpProfileClient(
        Uri.parse('https://presence.example/'),
        client: MockClient((request) async {
          requests.add(request);
          final answer = answers.removeAt(0);
          return http.Response(
            jsonEncode(answer),
            answer['complete'] == true ? 200 : 202,
          );
        }),
      );

      final result = await client.deleteAccount('google-token', _profile);

      expect(requests, hasLength(2));
      for (final r in requests) {
        expect(r.method, 'POST');
        expect(
          r.url.toString(),
          'https://presence.example/api/auth/account/delete',
        );
        expect(r.headers['authorization'], 'Bearer google-token');
        expect(r.body, _profile);
      }
      expect(result.complete, isTrue);
      expect(result.wholeProfile, isTrue);
      expect(result.accounts, 2);
      expect(result.objects, 1020);
    });

    test('a linked account; nothing left; a refusal', () async {
      var answer = http.Response(
        jsonEncode({
          'deleted': 'account',
          'profile': _profile,
          'accounts': 1,
          'complete': true,
        }),
        200,
      );
      final client = HttpProfileClient(
        Uri.parse('https://presence.example/'),
        client: MockClient((_) async => answer),
      );
      final linked = await client.deleteAccount('t', _profile);
      expect(linked.wholeProfile, isFalse);
      expect(linked.profile, _profile);

      answer = http.Response('{"deleted":"nothing","complete":true}', 200);
      final nothing = await client.deleteAccount('t', _profile);
      expect(nothing.profile, isNull);
      expect(nothing.complete, isTrue);

      answer = http.Response('{"error":"x"}', 409);
      expect(
        () => client.deleteAccount('t', _profile),
        throwsA(
          isA<RolesException>().having((e) => e.statusCode, 'status', 409),
        ),
      );
    });

    test('gives up after its rounds, not complete', () async {
      var calls = 0;
      final client = HttpProfileClient(
        Uri.parse('https://presence.example/'),
        client: MockClient((_) async {
          calls++;
          return http.Response(
            '{"deleted":"profile","profile":"$_profile","objects":1000,"complete":false}',
            202,
          );
        }),
      );
      final result = await client.deleteAccount('t', _profile, rounds: 3);
      expect(calls, 3);
      expect(result.complete, isFalse);
      expect(result.objects, 3000);
    });
  });

  group('DeleteAccountDialog', () {
    /// A page with a button that asks, as the account sheet's does.
    Future<List<Uri>> show(
      WidgetTester tester, {
      required FakeProfileClient profiles,
      required DeleteAccount delete,
    }) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: DeleteAccountButton(
                auth: FakeAuthService.signedIn(),
                profiles: profiles,
                profile: _profile,
                delete: delete,
                openLink: (url) async {
                  opened.add(url);
                  return true;
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('delete-account')));
      await tester.pumpAndSettle();
      return opened;
    }

    Finder go() => find.byKey(const Key('delete-account-go'));
    bool enabled(WidgetTester tester) =>
        tester.widget<FilledButton>(go()).onPressed != null;

    testWidgets('the owner is told the whole profile goes, and confirms '
        'first', (tester) async {
      final profiles = FakeProfileClient([
        _owner,
        const ProfileAccount(
          email: 'ana@gmail.com',
          owner: false,
          current: false,
        ),
      ]);
      var deleted = 0;
      await show(
        tester,
        profiles: profiles,
        delete: () async {
          deleted++;
          return const AccountDeletion(
            profile: _profile,
            wholeProfile: true,
            accounts: 2,
          );
        },
      );

      expect(find.text('Delete your account?'), findsOneWidget);
      expect(
        find.textContaining('You own the profile $_profile'),
        findsOneWidget,
      );
      expect(find.textContaining('ana@gmail.com'), findsOneWidget);
      expect(
        find.textContaining("doesn't cancel a Premium subscription"),
        findsOneWidget,
      );
      expect(find.textContaining("can't be undone"), findsWidgets);
      // Not before the checkbox.
      expect(enabled(tester), isFalse);
      await confirm(tester);
      await tester.pump();
      expect(enabled(tester), isTrue);

      await tester.tap(go());
      await tester.pumpAndSettle();

      expect(deleted, 1);
      expect(find.byKey(const Key('delete-account-dialog')), findsNothing);
      expect(
        find.text('Your account and its profile were deleted'),
        findsOneWidget,
      );
    });

    testWidgets('a linked account is told only it leaves', (tester) async {
      final profiles = FakeProfileClient([
        const ProfileAccount(
          email: 'ana@nu01.com',
          owner: true,
          current: false,
        ),
        const ProfileAccount(
          email: 'ana@example.com',
          owner: false,
          current: true,
        ),
      ]);
      await show(
        tester,
        profiles: profiles,
        delete: () async => const AccountDeletion(profile: _profile),
      );

      expect(find.byKey(const Key('delete-account-owner')), findsNothing);
      expect(
        find.text(
          'ana@example.com is linked to the profile $_profile, owned by '
          'ana@nu01.com. Deleting your account unlinks it and deletes your '
          "Feedback & Help messages; the profile and its data stay its "
          "owner's.",
        ),
        findsOneWidget,
      );
      await confirm(tester);
      await tester.pump();
      await tester.tap(go());
      await tester.pumpAndSettle();
      expect(
        find.text('Your account was deleted and unlinked from the profile'),
        findsOneWidget,
      );
    });

    testWidgets('Cancel deletes nothing', (tester) async {
      var deleted = 0;
      await show(
        tester,
        profiles: FakeProfileClient(),
        delete: () async {
          deleted++;
          return const AccountDeletion(profile: _profile);
        },
      );
      await confirm(tester);
      await tester.pump();
      await tester.tap(find.byKey(const Key('delete-account-cancel')));
      await tester.pumpAndSettle();
      expect(deleted, 0);
      expect(find.byKey(const Key('delete-account-dialog')), findsNothing);
      expect(find.byKey(const Key('account-deleted')), findsNothing);
    });

    testWidgets('a failure says why and can be tried again', (tester) async {
      Object? fails = RolesException(409);
      var tries = 0;
      await show(
        tester,
        profiles: FakeProfileClient(),
        delete: () async {
          tries++;
          if (fails case final e?) throw e;
          return const AccountDeletion(profile: _profile, wholeProfile: true);
        },
      );
      await confirm(tester);
      await tester.pump();

      await tester.tap(go());
      await tester.pumpAndSettle();
      expect(
        find.text("Your account's profile changed. Close this and try again."),
        findsOneWidget,
      );
      expect(find.byKey(const Key('delete-account-dialog')), findsOneWidget);

      fails = RolesException(401);
      await tester.tap(go());
      await tester.pumpAndSettle();
      expect(
        find.text('Sign in again, then delete the account.'),
        findsOneWidget,
      );

      fails = null;
      await tester.tap(go());
      await tester.pumpAndSettle();
      expect(tries, 3);
      expect(find.byKey(const Key('delete-account-dialog')), findsNothing);
    });

    testWidgets('a folder not deleted yet asks to try again', (tester) async {
      await show(
        tester,
        profiles: FakeProfileClient(),
        delete: () async => const AccountDeletion(
          profile: _profile,
          wholeProfile: true,
          complete: false,
        ),
      );
      await confirm(tester);
      await tester.pump();
      await tester.tap(go());
      await tester.pumpAndSettle();
      expect(find.textContaining('still being deleted'), findsOneWidget);
      expect(find.byKey(const Key('delete-account-dialog')), findsOneWidget);
    });

    testWidgets('links to how to cancel a subscription', (tester) async {
      final opened = await show(
        tester,
        profiles: FakeProfileClient(),
        delete: () async => const AccountDeletion(profile: _profile),
      );
      await tester.tap(find.byKey(const Key('delete-account-subscriptions')));
      await tester.pump();
      expect(opened, hasLength(1));
      expect(opened.single.path, '/delete-account');
      expect(opened.single.fragment, 'subscriptions');
    });

    testWidgets("on iOS and Android: the store's subscriptions, never Stripe", (
      tester,
    ) async {
      PurchaseChannel.debugOverride = PurchaseChannel.appStore;
      addTearDown(() => PurchaseChannel.debugOverride = PurchaseChannel.stripe);
      final opened = await show(
        tester,
        profiles: FakeProfileClient(),
        delete: () async => const AccountDeletion(profile: _profile),
      );
      expect(find.textContaining('Stripe'), findsNothing);
      expect(find.textContaining('App Store subscription settings'), findsOne);
      await tester.tap(find.byKey(const Key('delete-account-subscriptions')));
      await tester.pump();
      expect(opened, [
        Uri.parse('https://apps.apple.com/account/subscriptions'),
      ]);
    });

    testWidgets('fits a 320 dp phone', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await show(
        tester,
        profiles: FakeProfileClient(),
        delete: () async => const AccountDeletion(profile: _profile),
      );
      expect(tester.takeException(), isNull);
      expect(go(), findsOneWidget);
    });
  });

  group('the account sheet', () {
    testWidgets('ends with Delete account once the profile is known', (
      tester,
    ) async {
      final auth = FakeAuthService();
      final client = FakeRolesClient([userRole])..profile = null;
      final roles = RolesService(auth: auth, client: client);
      addTearDown(roles.dispose);
      await auth.signIn();
      Widget sheet({DeleteAccount? delete}) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AccountSheet(
              auth: auth,
              roles: roles,
              profiles: FakeProfileClient(),
              deleteAccount: delete,
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        sheet(
          delete: () async {
            return const AccountDeletion(profile: _profile);
          },
        ),
      );
      await tester.pumpAndSettle();
      // No profile (the auth API hasn't answered one): no button.
      expect(find.byKey(const Key('sign-out')), findsOneWidget);
      expect(find.byKey(const Key('delete-account')), findsNothing);
      client.profile = _profile;
      await roles.refresh();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-account')), findsOneWidget);
      // Nothing to delete with: none.
      await tester.pumpWidget(sheet());
      expect(find.byKey(const Key('delete-account')), findsNothing);
    });
  });

  group('Persistence.deleteProfile', () {
    test('deletes the profile\'s events, clips, recordings and peers\' keys, '
        'and nothing else', () async {
      final bus = AppEventBus();
      final persistence = Persistence(
        factory: Future.value(newIdbFactoryMemory()),
        bus: bus,
        config: ConfigController(),
        mediaStore: IdbMediaStore.new,
      );
      addTearDown(() {
        persistence.dispose();
        bus.close();
      });
      final store = await persistence.store;
      final media = await persistence.media;
      Future<void> event(String id, String? profile, {String? clip}) async {
        await store.putEvent({
          'id': id,
          'type': clip == null ? AppEvent.genericType : 'clipRequested',
          'title': 'Door opened',
          'time': 1000,
          'profileId': ?profile,
          'clipId': ?clip,
        });
        if (clip != null) {
          await store.putClip({
            'id': clip,
            'eventId': id,
            'cameraId': 'cam',
            'beforeMs': 5000,
            'afterMs': 10000,
            'state': 'complete',
            'full': {'mediaId': '$clip-full', 'startMs': 0, 'endMs': 15000},
          });
          await store.putMedia('$clip-full', Uint8List.fromList([1, 2, 3]));
        }
      }

      await event('mine', _profile);
      await event('mine-clip', _profile, clip: 'c1');
      await event('ask', _profile);
      await store.putEvent({
        'id': 'suggestion',
        'type': 'subject_suggestion',
        'title': 'Is this Rex?',
        'time': 1000,
        'clipEventId': 'mine-clip',
      });
      await event('signed-out', null);
      await event('theirs', 'other_profile_here', clip: 'c2');
      await store.markSynced(
        'us-east-1:x/events/year=1970/day=001/mine.json',
        'fingerprint',
      );
      await store.markSynced(
        'us-east-1:y/events/year=1970/day=001/theirs.json',
        'fingerprint',
      );
      await store.putSettings('keys', {'brave_phone': 'a2V5'});

      final deleted = await persistence.deleteProfile(_profile);

      expect(deleted, 4, reason: 'three events and the suggestion');
      expect(await store.eventIds(), {'signed-out', 'theirs'});
      expect(await store.clipIds(), {'c2'});
      expect(await media.ids(), ['c2-full']);
      expect((await store.syncedKeys()).keys, [
        'us-east-1:y/events/year=1970/day=001/theirs.json',
      ]);
      expect(await store.getSettings('keys'), isEmpty);
      // This device stays itself.
      expect(await store.getSettings('device'), isNotNull);
    });
  });

  group('in the app', () {
    testWidgets('deleting the account deletes it at the API, signs out and '
        'says so', (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final storage = newIdbFactoryMemory();
      // Another device's event of the profile, and one of another profile.
      final seed = await tester.runAsync(() => EventStore.open(storage));
      for (final (id, profile) in [
        ('theirs', _profile),
        ('other', 'other_profile_here'),
      ]) {
        await tester.runAsync(
          () => seed!.putEvent({
            'id': id,
            'type': AppEvent.genericType,
            'title': 'Door $id',
            'time': DateTime.now().millisecondsSinceEpoch,
            'deviceId': 'brave_phone',
            'userId': '1',
            'profileId': profile,
          }),
        );
      }
      seed!.close();
      final auth = FakeAuthService.signedIn();
      final profiles = FakeProfileClient([_owner]);
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          cameras: openFakes(const []),
          storage: storage,
          mediaIo: fakeMediaIo,
          auth: auth,
          rolesClient: FakeRolesClient([userRole]),
          rbacrClient: FakeRbacrClient(),
          profileClient: profiles,
          mapTiles: const SizedBox(),
          locator: NoLocation(),
        ),
      );
      await tester.pumpAndSettle();
      await settleStorage(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('account-button')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('delete-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-account')));
      await tester.pumpAndSettle();
      await confirm(tester);
      await tester.pump();
      await tester.tap(find.byKey(const Key('delete-account-go')));
      await tester.pump();
      await settleStorage(tester);
      await tester.pumpAndSettle();

      expect(profiles.deletedAccounts, [_profile]);
      expect(auth.user, isNull);
      expect(find.byKey(const Key('delete-account-dialog')), findsNothing);
      expect(find.byKey(const Key('account-sheet')), findsNothing);
      expect(
        find.text('Your account and its profile were deleted'),
        findsOneWidget,
      );

      // This device forgot the profile's events; another profile's stay.
      await tester.pumpWidget(const SizedBox());
      await settleStorage(tester);
      final ids = await tester.runAsync(() async {
        final store = await EventStore.open(storage);
        final ids = await store.eventIds();
        store.close();
        return ids;
      });
      expect(ids, contains('other'));
      expect(ids, isNot(contains('theirs')));
    });
  });
}
