enum UssdStatus {
  noActionRequired, // 0: USSD Response (session terminated)
  actionRequired, // 1: USSD Request (interactive prompt expecting user input)
  terminatedByNetwork, // 2: USSD Terminated by network
  otherClientResponded, // 3: Other local client has responded
  notSupported, // 4: Operation not supported
  timedOut, // 5: Network timeout
  unknown,
}

class UssdSession {
  final String query;
  final String response;
  final UssdStatus status;
  final int dcs;
  final DateTime timestamp;
  final bool isInteractive;

  UssdSession({
    required this.query,
    required this.response,
    required this.status,
    this.dcs = 15,
    DateTime? timestamp,
    this.isInteractive = false,
  }) : timestamp = timestamp ?? DateTime.now();

  static UssdSession parse(String raw, {String query = ''}) {
    // Standard format: +CUSD: <m>[,"<str>",<dcs>]
    // Example: +CUSD: 0,"Your balance is $10.00",15
    // Example: +CUSD: 1,"1. Top-up\n2. Balance\n3. Offers",15
    final regExp = RegExp(
      r'\+CUSD:\s*(\d+)(?:,\s*"((?:[^"\\]|\\.)*)"(?:,\s*(\d+))?)?',
      multiLine: true,
      caseSensitive: false,
    );

    final match = regExp.firstMatch(raw);
    if (match != null) {
      final codeInt = int.tryParse(match.group(1) ?? '0') ?? 0;
      final rawStr = match.group(2) ?? '';
      final dcs = int.tryParse(match.group(3) ?? '15') ?? 15;

      // Decode escaped newlines / chars if present
      final decodedText = _decodeUssdString(rawStr);

      UssdStatus status;
      switch (codeInt) {
        case 0:
          status = UssdStatus.noActionRequired;
          break;
        case 1:
          status = UssdStatus.actionRequired;
          break;
        case 2:
          status = UssdStatus.terminatedByNetwork;
          break;
        case 3:
          status = UssdStatus.otherClientResponded;
          break;
        case 4:
          status = UssdStatus.notSupported;
          break;
        case 5:
          status = UssdStatus.timedOut;
          break;
        default:
          status = UssdStatus.unknown;
      }

      return UssdSession(
        query: query,
        response: decodedText.isNotEmpty ? decodedText : raw.trim(),
        status: status,
        dcs: dcs,
        isInteractive: status == UssdStatus.actionRequired,
      );
    }

    // Fallback if raw text returned
    final cleaned = raw.replaceAll('OK', '').replaceAll('\r', '').trim();
    return UssdSession(
      query: query,
      response: cleaned.isNotEmpty ? cleaned : raw.trim(),
      status: UssdStatus.noActionRequired,
      isInteractive: false,
    );
  }

  static String _decodeUssdString(String input) {
    if (input.isEmpty) return '';

    // Check if hex encoded (e.g. UCS2 or 7-bit packed hex)
    // Hex strings are typically only hexadecimal characters and even length >= 4
    final hexPattern = RegExp(r'^[0-9A-Fa-f]{4,}$');
    if (hexPattern.hasMatch(input) && input.length % 4 == 0) {
      try {
        final buffer = StringBuffer();
        for (int i = 0; i < input.length; i += 4) {
          final hexPart = input.substring(i, i + 4);
          final charCode = int.parse(hexPart, radix: 16);
          if (charCode > 0) {
            buffer.writeCharCode(charCode);
          }
        }
        final decoded = buffer.toString();
        if (decoded.trim().isNotEmpty) {
          return decoded;
        }
      } catch (_) {
        // Fallback to original
      }
    }

    return input.replaceAll(r'\n', '\n').replaceAll(r'\r', '');
  }

  String get statusLabel {
    switch (status) {
      case UssdStatus.noActionRequired:
        return 'Completed';
      case UssdStatus.actionRequired:
        return 'Interactive Prompt (Reply Required)';
      case UssdStatus.terminatedByNetwork:
        return 'Terminated by Network';
      case UssdStatus.otherClientResponded:
        return 'Responded by Other Client';
      case UssdStatus.notSupported:
        return 'Operation Not Supported';
      case UssdStatus.timedOut:
        return 'Session Timed Out';
      case UssdStatus.unknown:
        return 'Active';
    }
  }
}
