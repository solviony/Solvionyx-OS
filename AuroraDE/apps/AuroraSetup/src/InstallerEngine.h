
#pragma once
#include <QObject>
#include "DiskManager.h"
#include "EncryptionManager.h"
#include "WifiManager.h"
#include "UserCreator.h"

class InstallerEngine : public QObject {
    Q_OBJECT
public:
    InstallerEngine();
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    bool busy() const { return m_busy; }

    Q_INVOKABLE void startInstall();

signals:
    void busyChanged();
    void progress(int p);
    void done();

private:
    bool m_busy=false;
};
