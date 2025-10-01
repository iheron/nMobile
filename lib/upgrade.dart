import 'package:nmobile/common/settings.dart';
import 'package:nmobile/schema/wallet.dart';
import 'package:nmobile/storages/settings.dart' as settings_storage;
import 'package:nmobile/storages/wallet.dart';
import 'package:nmobile/utils/logger.dart';

/// Simple, single-function upgrade flow using if/else-if steps.
class Upgrade {
  static const String _keyLastBuild = 'last_build';

  /// Call once after Settings.init().
  /// Example: add steps like `if (needRunStep(342)) { /* do upgrade for 342 */ } else if (...) { ... }`.
  static Future<void> run() async {
    final int prev = await _getPreviousBuild();
    final int curr = _parseBuild(Settings.build);
    try {
      // STEP: build 342
      if (needRunStep(prevBuild: prev, currBuild: curr, targetBuild: 342)) {
        logger.i("Upgrade - Running build 342 upgrade step");
        logger.i("Upgrade - Previous build: $prev, Current build: $curr");
        final WalletStorage walletStorage = WalletStorage();
        final List<WalletSchema> wallets = await walletStorage.getAll();
        final String? defaultAddress = await walletStorage.getDefaultAddress();

        if (wallets.length == 2) {
          // If second is Default Account AND default is Default Account => set default to first
          final WalletSchema second = wallets[1];
          final String secondName = (second.name ?? '').trim();
          final bool secondIsDefaultAccount = secondName == 'Default Account';
          final bool defaultIsSecond = (defaultAddress != null && defaultAddress.isNotEmpty && defaultAddress == second.address);
          if (secondIsDefaultAccount && defaultIsSecond) {
            await walletStorage.setDefaultAddress(wallets[0].address);
          }
        } else if (wallets.length > 2) {
          // If default wallet is Default Account => clear default (do not delete wallet)
          if (defaultAddress != null && defaultAddress.isNotEmpty) {
            final int defIndex = wallets.indexWhere((w) => w.address == defaultAddress);
            if (defIndex >= 0) {
              final WalletSchema defWallet = wallets[defIndex];
              final String defName = (defWallet.name ?? '').trim();
              if (defName == 'Default Account') {
                // Clear default wallet setting
                await walletStorage.setDefaultAddress(null);
              }
            }
          }
        }
      }
     
    } finally {
      // Persist current build for next run
      await settings_storage.SettingsStorage.setSettings(_keyLastBuild, Settings.build);
    }
  }

  /// Return true if this step should run for [targetBuild]:
  /// - prevBuild is null/0 OR prevBuild < targetBuild
  /// - AND currBuild >= targetBuild
  static bool needRunStep({required int prevBuild, required int currBuild, required int targetBuild}) {
    if (currBuild <= 0) return false;
    final bool prevIsUnsetOrLower = (prevBuild == 0 || prevBuild < targetBuild);
    return prevIsUnsetOrLower && (currBuild >= targetBuild);
  }

  static Future<int> _getPreviousBuild() async {
    final String? val = await settings_storage.SettingsStorage.getSettings(_keyLastBuild);
    return _parseBuild(val);
  }

  static int _parseBuild(String? buildRaw) {
    if (buildRaw == null) return 0;
    final String digits = buildRaw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return 0;
    return int.tryParse(digits) ?? 0;
  }
}