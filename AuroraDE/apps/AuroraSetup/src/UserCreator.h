
#pragma once
#include <QObject>

class UserCreator : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE bool createUser(const QString &name,const QString &pass);
};
