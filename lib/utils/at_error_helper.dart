import 'package:flutter/material.dart';

/// Comprehensive AT & GSM Error Translator and Resolution Assistant
class AtErrorHelper {
  /// Translates raw AT error strings (+CME ERROR, +CMS ERROR, NO CARRIER, BUSY, etc.) into human-readable explanations.
  static String formatError(String rawError, {String context = ''}) {
    final lower = rawError.toLowerCase().trim();

    if (lower.isEmpty) return 'An unknown error occurred.';

    // Connection & Port Errors
    if (lower.contains('resource busy') || lower.contains('ebusy')) {
      return 'The serial port is currently open and locked by another application. Please close other serial tools and try again.';
    }
    if (lower.contains('permission denied') || lower.contains('eacces')) {
      return 'Permission denied accessing serial/Bluetooth port. Please check macOS Bluetooth & Privacy permissions.';
    }
    if (lower.contains('no such file') || lower.contains('not found')) {
      return 'The device was unplugged or disconnected from the system.';
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return 'Device did not respond within the expected timeout. The handset may be processing another task or disconnected.';
    }

    // Standard Cellular Call Progress Errors
    if (lower.contains('no carrier')) {
      return 'Call disconnected or network unavailable (NO CARRIER). Check cellular coverage, antenna, or SIM card balance.';
    }
    if (lower.contains('busy')) {
      return 'Recipient line is busy or rejected the call (BUSY).';
    }
    if (lower.contains('no dialtone') || lower.contains('no dial tone')) {
      return 'No cellular dial tone detected from modem. Network service may be unavailable.';
    }
    if (lower.contains('no answer')) {
      return 'No answer from recipient phone within timeout (NO ANSWER).';
    }

    // CME Errors (Mobile Equipment & SIM Errors)
    final cmeMatch = RegExp(r'\+CME ERROR:\s*(\d+)', caseSensitive: false).firstMatch(rawError);
    if (cmeMatch != null) {
      final code = int.tryParse(cmeMatch.group(1) ?? '');
      switch (code) {
        case 0:
          return 'Phone Hardware Failure (CME 0). Handset reported a hardware issue.';
        case 1:
          return 'No Connection to Phone (CME 1). Device link was lost or disconnected.';
        case 2:
          return 'Phone Adapter Link Reserved (CME 2). Port is in use by another service.';
        case 3:
          return 'Operation Not Allowed (CME 3). Handset keypad is locked or in restricted mode.';
        case 4:
          return 'Operation Not Supported (CME 4). This feature phone model does not support this command.';
        case 5:
          return 'PH-SIM PIN Required (CME 5). Handset is phone-locked.';
        case 10:
          return 'SIM Card Not Inserted (CME 10). Please ensure a SIM card is properly placed in the slot.';
        case 11:
          return 'SIM PIN Required (CME 11). Please enter your SIM PIN on handset.';
        case 12:
          return 'SIM PUK Required (CME 12). SIM card is locked and requires PUK code.';
        case 13:
          return 'SIM Failure (CME 13). SIM card is defective or unreadable.';
        case 14:
          return 'SIM Busy (CME 14). SIM is busy processing, please try again in a moment.';
        case 15:
          return 'Wrong SIM (CME 15).';
        case 16:
          return 'Incorrect Password / PIN (CME 16).';
        case 20:
          return 'Phone Memory Full (CME 20). Delete old call logs or SMS messages on phone.';
        case 21:
          return 'Invalid Storage Index (CME 21). The requested entry slot does not exist.';
        case 22:
          return 'Item Not Found (CME 22).';
        case 23:
          return 'Memory Failure (CME 23). Handset internal storage error.';
        case 24:
          return 'Text String Too Long (CME 24). Content exceeds maximum length.';
        case 25:
          return 'Invalid Characters (CME 25). Phone number or text contains unsupported characters.';
        case 30:
          return 'No Cellular Network Service (CME 30). Emergency calls only or no reception.';
        case 31:
          return 'Network Timeout (CME 31). Base station did not respond.';
        case 32:
          return 'Network Not Allowed (CME 32). Operator denied network registration.';
        default:
          return 'Cellular Modem CME Error #$code: $rawError';
      }
    }

    // CMS Errors (SMS Message & Delivery Errors)
    final cmsMatch = RegExp(r'\+CMS ERROR:\s*(\d+)', caseSensitive: false).firstMatch(rawError);
    if (cmsMatch != null) {
      final code = int.tryParse(cmsMatch.group(1) ?? '');
      switch (code) {
        case 1:
          return 'Unassigned / Unallocated Phone Number (CMS 1).';
        case 8:
          return 'Operator Determined Barring (CMS 8). Account plan or SMS balance restriction.';
        case 10:
          return 'Call / SMS Barred (CMS 10). Outgoing SMS disabled on this SIM.';
        case 21:
          return 'Short Message Transfer Rejected by Network (CMS 21).';
        case 27:
          return 'Destination Out of Service (CMS 27). Recipient phone is powered off or unreachable.';
        case 28:
          return 'Unidentified Subscriber (CMS 28).';
        case 30:
          return 'Unknown Subscriber / Invalid Number (CMS 30). Verify destination number.';
        case 38:
          return 'Network Out of Order (CMS 38). Cellular network temporary outage.';
        case 41:
          return 'Temporary Network Failure (CMS 41). Please retry in a few seconds.';
        case 42:
          return 'Network Congestion (CMS 42). High traffic on cellular tower.';
        case 255:
          return 'Handset Busy / Invalid State (CMS 255). Phone is currently handling another task.';
        case 300:
          return 'SMS Engine Failure (CMS 300).';
        case 301:
          return 'SMS Service Reserved (CMS 301).';
        case 302:
          return 'Operation Not Allowed (CMS 302). SMS Center number (SMSC) may be missing.';
        case 304:
          return 'Invalid SMS Text Mode Parameter (CMS 304).';
        case 310:
          return 'SIM Not Inserted for SMS (CMS 310).';
        case 311:
          return 'SIM PIN Required for SMS (CMS 311).';
        case 314:
          return 'SIM Busy (CMS 314). Try sending again in a few moments.';
        case 320:
          return 'SIM Memory Full (CMS 320). Handset SIM inbox is full, please delete old messages.';
        case 321:
          return 'Invalid SMS Index (CMS 321).';
        case 330:
          return 'SMS Center (SMSC) Address Unknown (CMS 330). Please configure SMSC number on phone.';
        case 500:
          return 'Unknown Network Error (CMS 500). Cellular carrier rejected message submission.';
        default:
          return 'SMS Service Error #$code: $rawError';
      }
    }

    if (rawError.contains('ERROR') && !rawError.contains(':')) {
      if (context.isNotEmpty) {
        return '$context failed: Handset modem returned ERROR. Device may be busy or command unsupported.';
      }
      return 'Modem returned ERROR. The device may be busy or unsupported.';
    }

    return rawError;
  }

  /// Returns a contextual icon for the error type.
  static IconData getIcon(String rawError) {
    final lower = rawError.toLowerCase();
    if (lower.contains('sim') || lower.contains('cme 10') || lower.contains('cme 11')) {
      return Icons.sim_card_alert_rounded;
    }
    if (lower.contains('no carrier') || lower.contains('cme 30') || lower.contains('network')) {
      return Icons.signal_cellular_connected_no_internet_0_bar_rounded;
    }
    if (lower.contains('busy')) {
      return Icons.phone_paused_rounded;
    }
    if (lower.contains('permission') || lower.contains('locked') || lower.contains('pin')) {
      return Icons.lock_outline_rounded;
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return Icons.timer_off_outlined;
    }
    if (lower.contains('sms') || lower.contains('cms')) {
      return Icons.sms_failed_rounded;
    }
    return Icons.error_outline_rounded;
  }

  /// Returns suggested recovery action text for user.
  static String? getSuggestedAction(String rawError) {
    final lower = rawError.toLowerCase();
    if (lower.contains('sim') && lower.contains('10')) {
      return 'Check SIM Tray';
    }
    if (lower.contains('no carrier') || lower.contains('network') || lower.contains('cme 30')) {
      return 'Switch SIM';
    }
    if (lower.contains('timeout') || lower.contains('busy') || lower.contains('cms 41') || lower.contains('cms 42')) {
      return 'Retry';
    }
    if (lower.contains('permission') || lower.contains('ebusy')) {
      return 'Reconnect';
    }
    return null;
  }
}
