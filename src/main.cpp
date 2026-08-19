#include <QApplication>
#include "mainwindow.hpp"

int main(int argc, char* argv[]) {
    QApplication app(argc, argv);
    app.setApplicationName("BTBuddy");
    app.setOrganizationName("BTBuddy");

    MainWindow window;
    window.show();

    return app.exec();
}
