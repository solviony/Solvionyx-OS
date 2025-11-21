
#pragma once
#include <QObject>

class DiskManager : public QObject {
    Q_OBJECT
public:
    explicit DiskManager(QObject *parent=nullptr);
    Q_INVOKABLE QStringList listDisks();
    Q_INVOKABLE QVariantMap inspectDisk(const QString &path);
    Q_INVOKABLE bool wipeDisk(const QString &path);
    Q_INVOKABLE bool createPartition(const QString &disk, const QString &size, const QString &type);
};
