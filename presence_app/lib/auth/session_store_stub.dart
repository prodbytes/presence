/// Android and iOS: the Google SDK restores the session, so nothing is
/// stored here.
class SessionStore {
  const SessionStore();

  String? load() => null;

  void save(String session) {}

  void clear() {}
}
