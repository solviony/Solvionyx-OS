
#include "DiskManager.h"
#include <QProcess>

DiskManager::DiskManager(QObject *parent):QObject(parent){}

QStringList DiskManager::listDisks(){
    QProcess p; p.start("lsblk", QStringList() << "-J");
    p.waitForFinished();
    return QStringList() << p.readAll();
}

QVariantMap DiskManager::inspectDisk(const QString &path){
    QVariantMap m; m["device"]=path; return m;
}

bool DiskManager::wipeDisk(const QString &path){
    QProcess::execute("wipefs", QStringList()<<"-a"<<path);
    return true;
}

bool DiskManager::createPartition(const QString &disk,const QString &size,const QString &type){
    QProcess::execute("parted", QStringList()<<disk<<"mkpart"<<"primary"<<type<<size);
    return true;
}
