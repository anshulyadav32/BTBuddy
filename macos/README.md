# macOS setup

This project contains the native Runner Swift sources needed by BTBuddy.
If the standard Flutter macOS scaffold is not present, run:

    flutter create --platforms=macos .

Then restore/replace:
- Runner/AppDelegate.swift
- Runner/SerialPortManager.swift
- Runner/USBDeviceManager.swift

The generated Runner project supplies the normal Flutter macOS Xcode configuration.
