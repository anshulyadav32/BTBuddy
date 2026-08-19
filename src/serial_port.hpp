#pragma once

#include <QObject>
#include <QString>
#include <QStringList>

class SerialPort : public QObject {
    Q_OBJECT
public:
    explicit SerialPort(QObject* parent = nullptr);
    ~SerialPort();

    static QStringList scan();
    bool openPort(const QString& path, int baud = 115200);
    void closePort();
    bool isOpen() const;
    QString writeCommand(const QString& command, int timeoutMs = 3000);

private:
    int fd_ = -1;
};
