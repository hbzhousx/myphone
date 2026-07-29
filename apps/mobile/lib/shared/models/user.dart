class AppUser {
  final String id;
  final String phoneNumber;
  final String displayName;
  final String identityPublicKey;
  final int identityKeyId;

  const AppUser({
    required this.id,
    required this.phoneNumber,
    required this.displayName,
    required this.identityPublicKey,
    required this.identityKeyId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'phone_number': phoneNumber,
        'display_name': displayName,
        'identity_public_key': identityPublicKey,
        'identity_key_id': identityKeyId,
      };

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'],
        phoneNumber: json['phone_number'],
        displayName: json['display_name'] ?? '',
        identityPublicKey: json['identity_public_key'],
        identityKeyId: json['identity_key_id'],
      );
}
