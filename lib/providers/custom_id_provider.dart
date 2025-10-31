import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../common/search_service/search_service.dart';

/// Custom ID state model
class CustomIdState {
  final String? customId;
  final bool isLoading;
  final String? error;

  const CustomIdState({
    this.customId,
    this.isLoading = false,
    this.error,
  });

  CustomIdState copyWith({
    String? customId,
    bool? isLoading,
    String? error,
  }) {
    return CustomIdState(
      customId: customId ?? this.customId,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
    );
  }
}

/// Custom ID Notifier - Riverpod 3.0 API (without code generation)
class CustomIdNotifier extends Notifier<CustomIdState> {
  @override
  CustomIdState build() {
    return const CustomIdState();
  }

  /// Load custom ID from server
  /// Parameters:
  /// - seed: User's seed for authentication
  /// - nknAddress: NKN client address (can be "identifier.publickey" format or just publickey)
  Future<void> loadCustomId(Uint8List seed, String nknAddress) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // Create authenticated search service
      final service = await SearchService.createWithAuth(seed: seed);

      // Get my info using the nknAddress
      final myInfo = await service.getMyInfo(nknAddress: nknAddress);

      
      // Dispose the service
      await service.dispose();

      if (myInfo == null) {
        // No data found - user hasn't submitted custom ID yet (not an error)
        state = state.copyWith(
          customId: null,
          isLoading: false,
          error: null,
        );
      } else {
        // Update state with custom ID (can be null if not set)
        state = state.copyWith(
          customId: myInfo.customId,
          isLoading: false,
          error: null,
        );
      }
    } catch (e) {
      state = state.copyWith(
        customId: null,
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// Update custom ID (after user submits)
  void setCustomId(String? customId) {
    state = state.copyWith(customId: customId);
  }

  /// Clear custom ID
  void clear() {
    state = const CustomIdState();
  }
}

/// Custom ID Provider - Riverpod 3.0 API
final customIdProvider = NotifierProvider<CustomIdNotifier, CustomIdState>(() {
  return CustomIdNotifier();
});

