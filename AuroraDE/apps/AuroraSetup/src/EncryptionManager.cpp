
#include "EncryptionManager.h"
#include <QProcess>

bool EncryptionManager::luksFormat(const QString &dev,const QString &pass){
    QProcess p;
    p.start("bash", QStringList() << "-c" << QString("echo '%1' | cryptsetup luksFormat %2 -").arg(pass, dev));
    p.waitForFinished();
    return true;
}

bool EncryptionManager::luksOpen(const QString &dev,const QString &name,const QString &pass){
    QProcess p;
    p.start("bash", QStringList() << "-c" << QString("echo '%1' | cryptsetup open %2 %3 -").arg(pass,dev,name));
    p.waitForFinished();
    return true;
}
