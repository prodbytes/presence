import 'package:flutter/material.dart';

import 'event_filters.dart' show EventFilters;
import 'events.dart' show EventDeviceTag;

/// Shows a device's events from anywhere in the app: a tapped device name
/// (the event details' device, the account sheet's device list, the All
/// grid's labels) closes what's open over the tabs, switches to the
/// Monitoring tab and searches its events for the device's ID
/// ([EventFilters.showDevice]). Put by the home screen around its tabs;
/// [onShow] is null while the Monitoring tab isn't there (no access), and
/// the names aren't tappable then.
///
/// Dialogs and sheets are routes, outside the home screen: whatever opens
/// one passes the scope on with [capture].
class ShowDeviceEvents extends InheritedWidget {
  const ShowDeviceEvents({
    super.key,
    required this.onShow,
    required super.child,
  });

  /// Shows the events of the device with this ID; null, unavailable.
  final ValueChanged<String>? onShow;

  /// What shows the device's events, rebuilding [context] when it
  /// changes; null outside a scope or while unavailable.
  static ValueChanged<String>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShowDeviceEvents>()?.onShow;

  /// [child] (a dialog's or a sheet's) with the scope [context] is in, if
  /// any, so the device names in it show their events too.
  static Widget capture(BuildContext context, Widget child) {
    final scope = context.getInheritedWidgetOfExactType<ShowDeviceEvents>();
    return scope == null
        ? child
        : ShowDeviceEvents(onShow: scope.onShow, child: child);
  }

  @override
  bool updateShouldNotify(ShowDeviceEvents oldWidget) =>
      onShow != oldWidget.onShow;
}

/// A device's name that, in a [ShowDeviceEvents] scope, shows the device's
/// events when tapped: built by [builder] with the tap, or with null (not
/// tappable) outside one. Tappable, it's a button with a tooltip ("Show
/// this device's events"). The builder puts the tap on the name itself:
/// a selectable ID keeps being selectable (`SelectableText.onTap`).
class DeviceEventsLink extends StatelessWidget {
  const DeviceEventsLink({
    super.key,
    required this.device,
    required this.builder,
  });

  /// The device's ID.
  final String device;

  final Widget Function(BuildContext context, VoidCallback? onTap) builder;

  @override
  Widget build(BuildContext context) {
    final show = ShowDeviceEvents.maybeOf(context);
    if (show == null) return builder(context, null);
    return Tooltip(
      message: EventDeviceTag.showTooltip,
      child: Semantics(
        button: true,
        child: builder(context, () => show(device)),
      ),
    );
  }
}
