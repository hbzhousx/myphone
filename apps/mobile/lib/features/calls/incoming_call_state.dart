import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Data class holding a pending incoming call before the user accepts or declines.
class PendingIncomingCall {
  final String callId;
  final String contactId;
  final String contactName;
  final String sdpOffer;
  final Map<String, dynamic> e2eeOffer;

  const PendingIncomingCall({
    required this.callId,
    required this.contactId,
    required this.contactName,
    required this.sdpOffer,
    required this.e2eeOffer,
  });
}

class IncomingCallNotifier extends StateNotifier<PendingIncomingCall?> {
  IncomingCallNotifier() : super(null);

  void setIncoming(PendingIncomingCall call) => state = call;
  void clear() => state = null;
}

final incomingCallProvider =
    StateNotifierProvider<IncomingCallNotifier, PendingIncomingCall?>(
        (ref) => IncomingCallNotifier());
