import 'dart:io';

import 'device_os.dart';

String currentOs() => DeviceOs.ofPlatform(Platform.operatingSystem);
