class UsbDevice {
  final String name;
  final String manufacturer;
  final String model;
  final String path;
  final int vendorId;
  final int productId;
  final bool usb;

  const UsbDevice({
    required this.name,
    required this.manufacturer,
    required this.model,
    required this.path,
    required this.vendorId,
    required this.productId,
    this.usb = true,
  });

  factory UsbDevice.fromMap(Map<dynamic, dynamic> map) {
    return UsbDevice(
      name: '${map['name'] ?? 'USB Serial Device'}',
      manufacturer: '${map['manufacturer'] ?? 'Unknown'}',
      model: '${map['model'] ?? ''}',
      path: '${map['path'] ?? ''}',
      vendorId: (map['vendorId'] as num?)?.toInt() ?? 0,
      productId: (map['productId'] as num?)?.toInt() ?? 0,
      usb: map['usb'] != false,
    );
  }

  @override
  bool operator ==(Object other) => other is UsbDevice && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => '$name — $path';
}
