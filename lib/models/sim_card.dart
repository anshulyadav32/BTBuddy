enum SimStatus {
  ready,
  inserted,
  noSim,
  pinRequired,
  pukRequired,
  disabled,
  unknown;

  String get label {
    switch (this) {
      case SimStatus.ready:
        return 'Ready / Active';
      case SimStatus.inserted:
        return 'Inserted (Standby)';
      case SimStatus.noSim:
        return 'No SIM Card';
      case SimStatus.pinRequired:
        return 'PIN Required';
      case SimStatus.pukRequired:
        return 'PUK Blocked';
      case SimStatus.disabled:
        return 'Disabled';
      case SimStatus.unknown:
        return 'Unknown';
    }
  }

  bool get isAvailable => this == SimStatus.ready || this == SimStatus.inserted;
}

class SimCard {
  final int slotIndex; // 1-indexed (SIM 1, SIM 2, ...)
  final String label; // "SIM 1", "SIM 2", etc.
  final String operatorName;
  final SimStatus status;
  final int signalLevel; // 0 - 31
  final String? phoneNumber;
  final String? iccid;
  final String? imsi;
  final bool isActive;

  const SimCard({
    required this.slotIndex,
    this.label = 'SIM',
    this.operatorName = 'Network Provider',
    this.status = SimStatus.ready,
    this.signalLevel = 24,
    this.phoneNumber,
    this.iccid,
    this.imsi,
    this.isActive = false,
  });

  SimCard copyWith({
    int? slotIndex,
    String? label,
    String? operatorName,
    SimStatus? status,
    int? signalLevel,
    String? phoneNumber,
    String? iccid,
    String? imsi,
    bool? isActive,
  }) {
    return SimCard(
      slotIndex: slotIndex ?? this.slotIndex,
      label: label ?? this.label,
      operatorName: operatorName ?? this.operatorName,
      status: status ?? this.status,
      signalLevel: signalLevel ?? this.signalLevel,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      iccid: iccid ?? this.iccid,
      imsi: imsi ?? this.imsi,
      isActive: isActive ?? this.isActive,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'slotIndex': slotIndex,
      'label': label,
      'operatorName': operatorName,
      'status': status.name,
      'signalLevel': signalLevel,
      'phoneNumber': phoneNumber,
      'iccid': iccid,
      'imsi': imsi,
      'isActive': isActive,
    };
  }

  factory SimCard.fromMap(Map<dynamic, dynamic> map) {
    return SimCard(
      slotIndex: int.tryParse('${map['slotIndex'] ?? 1}') ?? 1,
      label: '${map['label'] ?? 'SIM'}',
      operatorName: '${map['operatorName'] ?? 'Network Provider'}',
      status: SimStatus.values.firstWhere(
        (s) => s.name == '${map['status']}',
        orElse: () => SimStatus.unknown,
      ),
      signalLevel: int.tryParse('${map['signalLevel'] ?? 0}') ?? 0,
      phoneNumber: map['phoneNumber'] != null ? '${map['phoneNumber']}' : null,
      iccid: map['iccid'] != null ? '${map['iccid']}' : null,
      imsi: map['imsi'] != null ? '${map['imsi']}' : null,
      isActive: map['isActive'] == true,
    );
  }

  int get signalPercent => ((signalLevel / 31) * 100).clamp(0, 100).toInt();
}
