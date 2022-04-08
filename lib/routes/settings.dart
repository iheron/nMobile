import 'package:flutter/material.dart';
import 'package:nmobile/routes/routes.dart';
import 'package:nmobile/screens/settings/cache.dart';
import 'package:nmobile/screens/settings/home.dart';
import 'package:nmobile/screens/settings/subscribe.dart';

Map<String, WidgetBuilder> _routes = {
  SettingsHomeScreen.routeName: (BuildContext context) => SettingsHomeScreen(),
  SettingsCacheScreen.routeName: (BuildContext context) => SettingsCacheScreen(),
  SettingsAccelerateScreen.routeName: (BuildContext context) => SettingsAccelerateScreen(),
};

init() {
  Routes.registerRoutes(_routes);
}
