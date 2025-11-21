
#pragma once
#include <QObject>

class EncryptionManager : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE bool luksFormat(const QString &device, const QString &pass);
    Q_INVOKABLE bool luksOpen(const QString &device, const QString &name, const QString &pass);
};
