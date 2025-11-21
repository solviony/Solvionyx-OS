
#include "WifiManager.h"
#include <QProcess>

QStringList WifiManager::scanNetworks(){
    QProcess p; p.start("nmcli", QStringList()<<"-t"<<"device"<<"wifi"<<"list");
    p.waitForFinished();
    return QString(p.readAll()).split("\n");
}

bool WifiManager::connectTo(const QString &ssid,const QString &pass){
    QProcess::execute("nmcli", QStringList()<<"device"<<"wifi"<<"connect"<<ssid<<"password"<<pass);
    return true;
}
