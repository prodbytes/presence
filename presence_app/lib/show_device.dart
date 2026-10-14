/// Shows ([shown]) or hides the events of [deviceId] on this device
/// (`EventLog.hiddenDevices`): the Profile tab's device list.
typedef ShowDevice = void Function(String deviceId, bool shown);
