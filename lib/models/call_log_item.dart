enum CallType {
  dialed,
  received,
  missed,
  unknown;

  String get label {
    switch (this) {
      case CallType.dialed:
        return 'Outgoing Call';
      case CallType.received:
        return 'Incoming Call';
      case CallType.missed:
        return 'Missed Call';
      case CallType.unknown:
        return 'Call';
    }
  }
}

class CallLogItem {
  final int index;
  final String number;
  final String name;
  final CallType type;
  final String timestamp;
  final int simSlot; // 1 or 2
  final String duration;

  const CallLogItem({
    required this.index,
    required this.number,
    this.name = '',
    required this.type,
    this.timestamp = '',
    this.simSlot = 1,
    this.duration = '',
  });

  String get displayName => name.isNotEmpty ? name : (number.isNotEmpty ? number : 'Unknown');

  static List<CallLogItem> parseCpbrResponse(String raw, {required CallType type, int simSlot = 1}) {
    final List<CallLogItem> items = [];
    final lines = raw.split(RegExp(r'\r?\n'));

    for (final line in lines) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('+CPBR:')) continue;

      // Extract after "+CPBR:"
      final content = trimmed.substring(6).trim();

      // Parse tokens handling quoted and unquoted CSV
      final tokens = <String>[];
      final sb = StringBuffer();
      bool inQuotes = false;

      for (int i = 0; i < content.length; i++) {
        final c = content[i];
        if (c == '"') {
          inQuotes = !inQuotes;
        } else if (c == ',' && !inQuotes) {
          tokens.add(sb.toString().trim().replaceAll('"', ''));
          sb.clear();
        } else {
          sb.write(c);
        }
      }
      tokens.add(sb.toString().trim().replaceAll('"', ''));

      if (tokens.isNotEmpty) {
        final idx = int.tryParse(tokens[0]) ?? 0;
        final num = tokens.length > 1 ? tokens[1] : '';
        final text = tokens.length > 3 ? tokens[3] : (tokens.length > 2 ? tokens[2] : '');

        String name = '';
        String time = '';

        if (text.contains(',')) {
          final parts = text.split(',');
          name = parts.first.trim();
          time = parts.sublist(1).join(',').trim();
        } else if (RegExp(r'\d{2}[/-]\d{2}[/-]\d{2}').hasMatch(text) || RegExp(r'\d{2}:\d{2}').hasMatch(text)) {
          time = text;
        } else {
          name = text;
        }

        if (num.isNotEmpty || name.isNotEmpty) {
          items.add(CallLogItem(
            index: idx,
            number: num,
            name: name,
            type: type,
            timestamp: time.isNotEmpty ? time : 'Recent',
            simSlot: simSlot,
          ));
        }
      }
    }

    return items;
  }
}
