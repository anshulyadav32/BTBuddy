class SerialEvent {
  final String type;
  final String data;
  final DateTime time;

  SerialEvent({
    required this.type,
    required this.data,
    DateTime? time,
  }) : time = time ?? DateTime.now();
}
