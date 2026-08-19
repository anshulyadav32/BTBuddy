# BTBuddy

Flutter/macOS USB serial controller for Kechaoda phones.

## Architecture

- Flutter/Dart UI
- macOS Swift MethodChannel/EventChannel bridge
- IOKit USB discovery
- POSIX `termios` serial communication
- USB-only device filtering
- Default serial: 115200, 8-N-1

## Create the Flutter platform files

If this repository was created without Flutter's generated platform folders, run:

```bash
flutter create --platforms=macos .
```

Then replace the generated `macos/Runner/AppDelegate.swift` with the one in this project and add the other Swift files.

## Run

```bash
flutter pub get
flutter run -d macos
```

## Build

```bash
flutter build macos --release
```

## Kechaoda defaults

Port is discovered dynamically. A device such as `/dev/cu.KECHAODA` is preferred.
Baud defaults to 115200.

## AT commands

The UI supports:

- `AT`
- `AT+CGMM`
- `AT+CGMR`
- `AT+CSQ`
- `AT+COPS?`
- `AT+CSCS?`
- `AT+CLCC`
- `AT+CCWA?`
- `AT+CMEE?`
- `AT+VTS=<digit>`

Call control:

- `ATD<number>;`
- `ATA`
- `AT+CHUP`

DTMF:

- `AT+VTS=<digit>`
