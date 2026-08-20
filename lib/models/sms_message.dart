class SmsMessage {
  final int index;
  final String status;
  final String sender;
  final String date;
  final String body;
  final String storage; // "SM", "ME", "MT"
  final int simSlot; // 1, 2, ...

  const SmsMessage({
    required this.index,
    required this.status,
    required this.sender,
    required this.date,
    required this.body,
    this.storage = 'SM',
    this.simSlot = 1,
  });

  bool get isUnread => status.toUpperCase().contains('UNREAD');

  static List<SmsMessage> parseList(String raw, {String storage = 'SM', int simSlot = 1}) {
    final List<SmsMessage> list = [];
    final lines = raw.split(RegExp(r'\r?\n'));
    int? currentIndex;
    String? currentStatus;
    String? currentSender;
    String? currentDate;
    final bodyBuffer = StringBuffer();

    void commitCurrent() {
      final idx = currentIndex;
      if (idx != null) {
        final sender = currentSender;
        list.add(SmsMessage(
          index: idx,
          status: currentStatus ?? 'READ',
          sender: (sender != null && sender.isNotEmpty) ? sender : 'Unknown',
          date: currentDate ?? '',
          body: bodyBuffer.toString().trim(),
          storage: storage,
          simSlot: simSlot,
        ));
        bodyBuffer.clear();
      }
    }

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (line.startsWith('+CMGL:') || line.startsWith('+CMGR:')) {
        commitCurrent();

        final isCmgl = line.startsWith('+CMGL:');
        final content = line.substring(isCmgl ? 6 : 6).trim();

        // Extract all quoted strings and unquoted parts
        final quotes = RegExp(r'"([^"]*)"').allMatches(content).map((m) => m.group(1) ?? '').toList();

        if (isCmgl) {
          final idxMatch = RegExp(r'^\s*(\d+)').firstMatch(content);
          currentIndex = idxMatch != null ? int.tryParse(idxMatch.group(1)!) ?? (list.length + 1) : (list.length + 1);

          if (quotes.length >= 3) {
            currentStatus = quotes[0];
            currentSender = quotes[1];
            currentDate = quotes.last;
          } else if (quotes.length == 2) {
            currentStatus = quotes[0];
            currentSender = quotes[1];
            currentDate = '';
          } else if (quotes.length == 1) {
            currentSender = quotes[0];
            currentStatus = 'REC READ';
            currentDate = '';
          }
        } else {
          // +CMGR: "<stat>","<oa>",,"<scts>"
          currentIndex = list.length + 1;
          if (quotes.length >= 2) {
            currentStatus = quotes[0];
            currentSender = quotes[1];
            currentDate = quotes.length >= 3 ? quotes.last : '';
          }
        }
      } else if (line.isNotEmpty && line != 'OK' && line != 'ERROR' && currentIndex != null) {
        if (bodyBuffer.isNotEmpty) bodyBuffer.write('\n');
        bodyBuffer.write(line);
      }
    }

    commitCurrent();

    return list.reversed.toList();
  }
}
