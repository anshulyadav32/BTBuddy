#include "kechaoda.hpp"

Kechaoda::Kechaoda(QObject* parent)
    : QObject(parent), serial_(this) {}

QStringList Kechaoda::ports() const {
    return SerialPort::scan();
}

bool Kechaoda::connectDevice(const QString& port) {
    return serial_.openPort(port, 115200);
}

void Kechaoda::disconnectDevice() {
    serial_.closePort();
}

bool Kechaoda::connected() const {
    return serial_.isOpen();
}

QString Kechaoda::command(const QString& cmd) {
    return serial_.writeCommand(cmd);
}

QString Kechaoda::dial(const QString& number) {
    return command("ATD" + number + ";");
}

QString Kechaoda::answer() {
    return command("ATA");
}

QString Kechaoda::hangup() {
    return command("AT+CHUP");
}

QString Kechaoda::callStatus() {
    return command("AT+CLCC");
}

QString Kechaoda::dtmf(const QString& digit) {
    return command("AT+VTS=" + digit);
}
