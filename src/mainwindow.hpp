#pragma once

#include <QMainWindow>

class QComboBox;
class QPushButton;
class QLineEdit;
class QPlainTextEdit;
class QLabel;
class Kechaoda;

class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    explicit MainWindow(QWidget* parent = nullptr);

private:
    void scan();
    void connectDevice();
    void disconnectDevice();
    void sendCommand();
    void dial();
    void answer();
    void hangup();
    void status();
    void dtmf();

    void log(const QString& text);

    Kechaoda* device_;
    QComboBox* ports_;
    QLabel* connection_;
    QLineEdit* number_;
    QLineEdit* command_;
    QPlainTextEdit* logView_;
};
