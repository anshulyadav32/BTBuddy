#include "serial_port.hpp"

#include <QDir>
#include <QThread>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>

SerialPort::SerialPort(QObject* parent) : QObject(parent) {}

SerialPort::~SerialPort() {
    closePort();
}

QStringList SerialPort::scan() {
    QDir dir("/dev");
    const auto entries =
        dir.entryList(QDir::System | QDir::Readable, QDir::Name);

    QStringList result;

    // First priority: exact Kechaoda interfaces.
    for (const auto& name : entries) {
        if (name == "cu.KECHAODA" || name == "tty.KECHAODA")
            result << "/dev/" + name;
    }

    // Second priority: likely USB/MediaTek serial interfaces.
    for (const auto& name : entries) {
        if (!name.startsWith("cu.") && !name.startsWith("tty."))
            continue;

        const auto lower = name.toLower();

        if ((lower.contains("usb") ||
             lower.contains("modem") ||
             lower.contains("serial") ||
             lower.contains("mediatek")) &&
            !result.contains("/dev/" + name)) {
            result << "/dev/" + name;
        }
    }

    return result;
}

bool SerialPort::openPort(const QString& path, int baud) {
    closePort();

    fd_ = ::open(path.toLocal8Bit().constData(), O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd_ < 0)
        return false;

    termios tio{};
    if (tcgetattr(fd_, &tio) != 0) {
        closePort();
        return false;
    }

    cfmakeraw(&tio);

    speed_t speed = B115200;
    switch (baud) {
        case 9600: speed = B9600; break;
        case 19200: speed = B19200; break;
        case 38400: speed = B38400; break;
        case 57600: speed = B57600; break;
        case 115200: speed = B115200; break;
        default:
            closePort();
            return false;
    }

    cfsetispeed(&tio, speed);
    cfsetospeed(&tio, speed);

    tio.c_cflag |= CLOCAL | CREAD;
    tio.c_cflag &= ~CSIZE;
    tio.c_cflag |= CS8;
    tio.c_cflag &= ~PARENB;
    tio.c_cflag &= ~CSTOPB;

    if (tcsetattr(fd_, TCSANOW, &tio) != 0) {
        closePort();
        return false;
    }

    int flags = fcntl(fd_, F_GETFL, 0);
    if (flags >= 0)
        fcntl(fd_, F_SETFL, flags & ~O_NONBLOCK);

    return true;
}

void SerialPort::closePort() {
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
}

bool SerialPort::isOpen() const {
    return fd_ >= 0;
}

QString SerialPort::writeCommand(const QString& command, int timeoutMs) {
    if (fd_ < 0)
        return "ERROR: serial port is not connected";

    QByteArray tx = command.toUtf8();
    if (!tx.endsWith('\r'))
        tx.append('\r');

    const auto written = ::write(fd_, tx.constData(), tx.size());
    if (written != tx.size())
        return QString("ERROR: write failed: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));

    QByteArray rx;
    const int steps = timeoutMs / 50;

    for (int i = 0; i < steps; ++i) {
        char buffer[1024];
        const auto n = ::read(fd_, buffer, sizeof(buffer));

        if (n > 0) {
            rx.append(buffer, static_cast<int>(n));
            if (rx.contains("\r\nOK\r\n") ||
                rx.contains("\r\nERROR\r\n")) {
                break;
            }
        } else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            return QString("ERROR: read failed: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
        }

        QThread::msleep(50);
    }

    return QString::fromUtf8(rx);
}
