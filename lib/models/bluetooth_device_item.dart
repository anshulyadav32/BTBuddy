class BluetoothDeviceItem {
  final String name;
  final String address;
  final bool connected;
  final bool paired;
  final bool favorite;
  final int deviceClass;
  final int? rssi;
  final bool isPhone;
  final DateTime lastSeen;

  BluetoothDeviceItem({
    required this.name,
    required this.address,
    this.connected = false,
    this.paired = false,
    this.favorite = false,
    this.deviceClass = 0,
    this.rssi,
    this.isPhone = false,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  factory BluetoothDeviceItem.fromMap(Map<dynamic, dynamic> map) {
    final name = '${map['name'] ?? 'Unknown Bluetooth Device'}';
    final address = '${map['address'] ?? ''}';
    final connected = map['connected'] == true;
    final paired = map['paired'] == true;
    final favorite = map['favorite'] == true;
    final deviceClass = int.tryParse('${map['deviceClass'] ?? 0}') ?? 0;
    final rssi = map['rssi'] != null ? int.tryParse('${map['rssi']}') : null;

    final lower = '$name $address'.toLowerCase();
    final isPhone = lower.contains('kechaoda') ||
        lower.contains('mediatek') ||
        lower.contains('phone') ||
        lower.contains('mobile') ||
        lower.contains('gsm') ||
        deviceClass == 512; // Major device class for phone

    return BluetoothDeviceItem(
      name: name,
      address: address,
      connected: connected,
      paired: paired,
      favorite: favorite,
      deviceClass: deviceClass,
      rssi: rssi,
      isPhone: isPhone,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'address': address,
      'connected': connected,
      'paired': paired,
      'favorite': favorite,
      'deviceClass': deviceClass,
      'rssi': rssi,
      'isPhone': isPhone,
    };
  }

  String get typeLabel {
    if (isPhone) return 'Mobile Phone';
    if (name.toLowerCase().contains('audio') ||
        name.toLowerCase().contains('headset') ||
        name.toLowerCase().contains('buds') ||
        name.toLowerCase().contains('speaker')) {
      return 'Audio Endpoint';
    }
    return 'Bluetooth Device';
  }
}
