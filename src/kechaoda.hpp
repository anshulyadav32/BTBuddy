#pragma once

#include "serial_port.hpp"

class Kechaoda : public QObject {
    Q_OBJECT
public:
    explicit Kechaoda(QObject* parent = nullptr);

    QStringList ports() const;
    bool connectDevice(const QString& port);
    void disconnectDevice();

    bool connected() const;
    QString command(const QString& cmd);

    QString dial(const QString& number);
    QString answer();
    QString hangup();
    QString callStatus();
    QString dtmf(const QString& digit);

private:
    SerialPort serial_;
};
