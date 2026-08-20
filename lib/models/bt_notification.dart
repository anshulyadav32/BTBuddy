enum NotificationDirection {
  macToPhone,
  phoneToMac,
}

enum BtNotificationType {
  incomingCall,
  incomingSms,
  lowBattery,
  appAlert,
  customAlert,
  system,
}

class BtNotification {
  final String id;
  final String title;
  final String body;
  final String appName;
  final NotificationDirection direction;
  final BtNotificationType type;
  final DateTime timestamp;
  final bool delivered;
  final Map<String, dynamic>? metadata;

  BtNotification({
    required this.id,
    required this.title,
    required this.body,
    this.appName = 'BTBuddy',
    required this.direction,
    required this.type,
    DateTime? timestamp,
    this.delivered = true,
    this.metadata,
  }) : timestamp = timestamp ?? DateTime.now();

  factory BtNotification.phoneIncomingCall({
    required String callerNumber,
    String? callerName,
  }) {
    final title = callerName != null && callerName.isNotEmpty
        ? 'Incoming Call: $callerName'
        : 'Incoming Call';
    return BtNotification(
      id: 'call_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      body: callerNumber,
      appName: 'Phone Link',
      direction: NotificationDirection.phoneToMac,
      type: BtNotificationType.incomingCall,
      metadata: {'number': callerNumber, 'name': callerName},
    );
  }

  factory BtNotification.phoneIncomingSms({
    required String sender,
    required String message,
  }) {
    return BtNotification(
      id: 'sms_${DateTime.now().millisecondsSinceEpoch}',
      title: 'SMS from $sender',
      body: message,
      appName: 'Messages',
      direction: NotificationDirection.phoneToMac,
      type: BtNotificationType.incomingSms,
      metadata: {'sender': sender, 'message': message},
    );
  }

  factory BtNotification.phoneBatteryWarning({
    required int level,
  }) {
    return BtNotification(
      id: 'bat_${DateTime.now().millisecondsSinceEpoch}',
      title: 'Low Phone Battery',
      body: 'Connected phone battery is at $level%. Please plug in charger.',
      appName: 'Power Manager',
      direction: NotificationDirection.phoneToMac,
      type: BtNotificationType.lowBattery,
      metadata: {'batteryLevel': level},
    );
  }

  factory BtNotification.macPush({
    required String title,
    required String body,
    String appName = 'Mac Alert',
    BtNotificationType type = BtNotificationType.appAlert,
  }) {
    return BtNotification(
      id: 'push_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      body: body,
      appName: appName,
      direction: NotificationDirection.macToPhone,
      type: type,
    );
  }
}
