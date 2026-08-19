#include "mainwindow.hpp"
#include "kechaoda.hpp"

#include <QComboBox>
#include <QGridLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QMainWindow>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QVBoxLayout>
#include <QWidget>
#include <QDateTime>

MainWindow::MainWindow(QWidget* parent)
    : QMainWindow(parent), device_(new Kechaoda(this)) {

    setWindowTitle("BTBuddy");
    resize(900, 700);

    auto* central = new QWidget(this);
    auto* root = new QVBoxLayout(central);

    auto* title = new QLabel("🔵  BTBuddy — Kechaoda Controller");
    title->setStyleSheet("font-size: 24px; font-weight: bold; padding: 12px;");
    root->addWidget(title);

    auto* serialBox = new QGroupBox("Serial");
    auto* serialLayout = new QHBoxLayout(serialBox);

    ports_ = new QComboBox;
    auto* scanButton = new QPushButton("SCAN");
    auto* connectButton = new QPushButton("CONNECT");
    auto* disconnectButton = new QPushButton("DISCONNECT");
    connection_ = new QLabel("● DISCONNECTED");

    serialLayout->addWidget(ports_, 1);
    serialLayout->addWidget(scanButton);
    serialLayout->addWidget(connectButton);
    serialLayout->addWidget(disconnectButton);
    serialLayout->addWidget(connection_);

    root->addWidget(serialBox);

    auto* callBox = new QGroupBox("Calls");
    auto* callLayout = new QGridLayout(callBox);

    number_ = new QLineEdit;
    number_->setPlaceholderText("Phone number");

    auto* dialButton = new QPushButton("DIAL");
    auto* answerButton = new QPushButton("ANSWER");
    auto* hangupButton = new QPushButton("HANG UP");
    auto* statusButton = new QPushButton("STATUS");

    callLayout->addWidget(number_, 0, 0, 1, 4);
    callLayout->addWidget(dialButton, 1, 0);
    callLayout->addWidget(answerButton, 1, 1);
    callLayout->addWidget(hangupButton, 1, 2);
    callLayout->addWidget(statusButton, 1, 3);

    root->addWidget(callBox);

    auto* dtmfBox = new QGroupBox("DTMF");
    auto* dtmfLayout = new QGridLayout(dtmfBox);

    const QStringList digits{
        "1","2","3","4","5","6","7","8","9",
        "*","0","#","A","B","C","D"
    };

    for (int i = 0; i < digits.size(); ++i) {
        auto* button = new QPushButton(digits[i]);
        dtmfLayout->addWidget(button, i / 4, i % 4);
        connect(button, &QPushButton::clicked, this, [this, digit = digits[i]] {
            const auto response = device_->dtmf(digit);
            log("DTMF " + digit + "\n" + response);
        });
    }

    root->addWidget(dtmfBox);

    auto* terminalBox = new QGroupBox("AT Terminal");
    auto* terminalLayout = new QHBoxLayout(terminalBox);

    command_ = new QLineEdit("AT");
    auto* sendButton = new QPushButton("SEND");

    terminalLayout->addWidget(command_, 1);
    terminalLayout->addWidget(sendButton);

    root->addWidget(terminalBox);

    logView_ = new QPlainTextEdit;
    logView_->setReadOnly(true);
    logView_->setStyleSheet("font-family: Menlo; font-size: 12px;");
    root->addWidget(logView_, 1);

    setCentralWidget(central);

    connect(scanButton, &QPushButton::clicked, this, &MainWindow::scan);
    connect(connectButton, &QPushButton::clicked, this, &MainWindow::connectDevice);
    connect(disconnectButton, &QPushButton::clicked, this, &MainWindow::disconnectDevice);
    connect(sendButton, &QPushButton::clicked, this, &MainWindow::sendCommand);
    connect(dialButton, &QPushButton::clicked, this, &MainWindow::dial);
    connect(answerButton, &QPushButton::clicked, this, &MainWindow::answer);
    connect(hangupButton, &QPushButton::clicked, this, &MainWindow::hangup);
    connect(statusButton, &QPushButton::clicked, this, &MainWindow::status);

    scan();
}

void MainWindow::log(const QString& text) {
    logView_->appendPlainText(
        QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss") +
        "\n" + text + "\n"
    );
}

void MainWindow::scan() {
    ports_->clear();
    const auto list = device_->ports();
    ports_->addItems(list);

    if (list.contains("/dev/cu.KECHAODA")) {
        ports_->setCurrentText("/dev/cu.KECHAODA");
        log("AUTO-DETECT: KECHAODA found at /dev/cu.KECHAODA");
    } else if (!list.isEmpty()) {
        ports_->setCurrentIndex(0);
        log("AUTO-DETECT: selected " + list.first());
    }

    log(list.isEmpty()
        ? "SCAN: no supported serial ports"
        : "SCAN:\n" + list.join("\n"));
}

void MainWindow::connectDevice() {
    const auto port = ports_->currentText();

    if (port.isEmpty()) {
        log("CONNECT: select a port");
        return;
    }

    if (device_->connectDevice(port)) {
        connection_->setText("● CONNECTED");
        connection_->setStyleSheet("color: #25a244; font-weight: bold;");
        log("CONNECTED: " + port + " @ 115200");
        sendCommand();
    } else {
        log("CONNECT ERROR: could not open " + port);
    }
}

void MainWindow::disconnectDevice() {
    device_->disconnectDevice();
    connection_->setText("● DISCONNECTED");
    connection_->setStyleSheet("color: #d00000; font-weight: bold;");
    log("DISCONNECTED");
}

void MainWindow::sendCommand() {
    if (!device_->connected()) {
        log("ERROR: not connected");
        return;
    }

    const auto cmd = command_->text();
    const auto response = device_->command(cmd);
    log("TX: " + cmd + "\nRX:\n" + response);
}

void MainWindow::dial() {
    if (!device_->connected()) return;
    log("DIAL\n" + device_->dial(number_->text()));
}

void MainWindow::answer() {
    if (!device_->connected()) return;
    log("ANSWER\n" + device_->answer());
}

void MainWindow::hangup() {
    if (!device_->connected()) return;
    log("HANG UP\n" + device_->hangup());
}

void MainWindow::status() {
    if (!device_->connected()) return;
    log("CLCC\n" + device_->callStatus());
}
