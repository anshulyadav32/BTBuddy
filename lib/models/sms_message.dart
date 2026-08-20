class SmsMessage {
  final int index;
  final String status;
  final String sender;
  final String date;
  final String body;

  const SmsMessage({
    required this.index,
    required this.status,
    required this.sender,
    required this.date,
    required this.body,
  });

  bool get isUnread => status.toUpperCase().contains('UNREAD');

  static List<SmsMessage> parseList(String raw) {
    final List<SmsMessage> list = [];
    final lines = raw.split(RegExp(r'\r?\n'));
    int? currentIndex;
    String? currentStatus;
    String? currentSender;
    String? currentDate;
    final bodyBuffer = StringBuffer();

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      final headerMatch = RegExp(
        r'\+CMGL:\s*(\d+),\s*"([^"]+)",\s*"([^"]+)"(?:,[^,]*)?,\s*"([^"]+)"',
      ).firstMatch(line);

      if (headerMatch != null) {
        if (currentIndex != null) {
          list.add(SmsMessage(
            index: currentIndex,
            status: currentStatus ?? 'READ',
            sender: currentSender ?? 'Unknown',
            date: currentDate ?? '',
            body: bodyBuffer.toString().trim(),
          ));
          bodyBuffer.clear();
        }
        currentIndex = int.tryParse(headerMatch.group(1) ?? '0') ?? 0;
        currentStatus = headerMatch.group(2) ?? 'REC READ';
        currentSender = headerMatch.group(3) ?? 'Unknown';
        currentDate = headerMatch.group(4) ?? '';
      } else if (line.isNotEmpty && line != 'OK' && line != 'ERROR' && currentIndex != null) {
        if (bodyBuffer.isNotEmpty) bodyBuffer.write('\n');
        bodyBuffer.write(line);
      }
    }

    if (currentIndex != null) {
      list.add(SmsMessage(
        index: currentIndex,
        status: currentStatus ?? 'READ',
        sender: currentSender ?? 'Unknown',
        date: currentDate ?? '',
        body: bodyBuffer.toString().trim(),
      ));
    }

    return list.reversed.toList();
  }
}
