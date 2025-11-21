
#pragma once
#include <QObject>

class WifiManager : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE QStringList scanNetworks();
    Q_INVOKABLE bool connectTo(const QString &ssid,const QString &pass);
};
