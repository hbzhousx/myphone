class Contact {
  final String id;
  final String displayName;
  final String phoneHash;
  final String? publicKeyFingerprint;
  final String? avatarPath;
  final DateTime? lastSeen;
  final bool isRegistered;

  const Contact({
    required this.id,
    required this.displayName,
    required this.phoneHash,
    this.publicKeyFingerprint,
    this.avatarPath,
    this.lastSeen,
    this.isRegistered = false,
  });

  String get initials {
    if (displayName.isEmpty) return '?';
    return displayName
        .split(' ')
        .take(2)
        .map((w) => w.isNotEmpty ? w[0].toUpperCase() : '')
        .join();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'display_name': displayName,
        'phone_hash': phoneHash,
        'public_key_fingerprint': publicKeyFingerprint,
        'avatar_path': avatarPath,
        'last_seen': lastSeen?.millisecondsSinceEpoch,
        'is_registered': isRegistered ? 1 : 0,
      };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        id: json['id'],
        displayName: json['display_name'],
        phoneHash: json['phone_hash'],
        publicKeyFingerprint: json['public_key_fingerprint'],
        avatarPath: json['avatar_path'],
        lastSeen: json['last_seen'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['last_seen'])
            : null,
        isRegistered: json['is_registered'] == 1,
      );
}

class CallHistoryEntry {
  final String id;
  final String contactId;
  final String direction;
  final String status;
  final int durationSeconds;
  final String callType;
  final String? codecUsed;
  final int? avgBitrateBps;
  final DateTime startedAt;
  final DateTime? endedAt;

  const CallHistoryEntry({
    required this.id,
    required this.contactId,
    required this.direction,
    required this.status,
    required this.durationSeconds,
    required this.callType,
    this.codecUsed,
    this.avgBitrateBps,
    required this.startedAt,
    this.endedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'contact_id': contactId,
        'direction': direction,
        'status': status,
        'duration_seconds': durationSeconds,
        'call_type': callType,
        'codec_used': codecUsed,
        'avg_bitrate_bps': avgBitrateBps,
        'started_at': startedAt.millisecondsSinceEpoch,
        'ended_at': endedAt?.millisecondsSinceEpoch,
      };

  factory CallHistoryEntry.fromJson(Map<String, dynamic> json) => CallHistoryEntry(
        id: json['id'],
        contactId: json['contact_id'],
        direction: json['direction'],
        status: json['status'],
        durationSeconds: json['duration_seconds'],
        callType: json['call_type'],
        codecUsed: json['codec_used'],
        avgBitrateBps: json['avg_bitrate_bps'],
        startedAt: DateTime.fromMillisecondsSinceEpoch(json['started_at']),
        endedAt: json['ended_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['ended_at'])
            : null,
      );
}
