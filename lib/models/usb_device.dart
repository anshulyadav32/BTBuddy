class UsbDevice {
  final String name;
  final String manufacturer;
  final String model;
  final String path;
  final int vendorId;
  final int productId;
  final bool usb;
  final bool btConnected;
  final bool btPaired;
  final String btAddress;

  const UsbDevice({
    required this.name,
    required this.manufacturer,
    required this.model,
    required this.path,
    required this.vendorId,
    required this.productId,
    this.usb = true,
    this.btConnected = false,
    this.btPaired = false,
    this.btAddress = '',
  });

  factory UsbDevice.fromMap(Map<dynamic, dynamic> map) {
    return UsbDevice(
      name: '${map['name'] ?? 'Serial Device'}',
      manufacturer: '${map['manufacturer'] ?? (map['usb'] == false ? 'Bluetooth Device' : 'Unknown')}',
      model: '${map['model'] ?? ''}',
      path: '${map['path'] ?? ''}',
      vendorId: (map['vendorId'] as num?)?.toInt() ?? 0,
      productId: (map['productId'] as num?)?.toInt() ?? 0,
      usb: map['usb'] != false,
      btConnected: map['btConnected'] == true,
      btPaired: map['btPaired'] == true,
      btAddress: '${map['btAddress'] ?? ''}',
    );
  }

  @override
  bool operator ==(Object other) => other is UsbDevice && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => '$name — $path';
}
