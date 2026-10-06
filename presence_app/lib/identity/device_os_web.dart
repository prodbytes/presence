import 'package:web/web.dart' as web;

import 'device_os.dart';

String currentOs() => DeviceOs.ofUserAgent(web.window.navigator.userAgent);
