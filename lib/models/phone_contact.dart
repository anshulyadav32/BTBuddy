class PhoneContact {
  final int index;
  final String name;
  final String number;

  const PhoneContact({
    required this.index,
    required this.name,
    required this.number,
  });

  static List<PhoneContact> parseList(String raw) {
    final List<PhoneContact> list = [];
    final lines = raw.split(RegExp(r'\r?\n'));

    for (final line in lines) {
      final match = RegExp(r'\+CPBR:\s*(\d+),\s*"([^"]+)",\s*\d+,\s*"([^"]*)"').firstMatch(line.trim());
      if (match != null) {
        final idx = int.tryParse(match.group(1) ?? '0') ?? 0;
        final num = match.group(2) ?? '';
        final name = match.group(3)?.isNotEmpty == true ? match.group(3)! : 'Contact $idx';
        list.add(PhoneContact(index: idx, number: num, name: name));
      }
    }
    return list;
  }
}
