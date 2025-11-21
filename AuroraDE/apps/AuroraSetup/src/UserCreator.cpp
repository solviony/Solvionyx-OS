
#include "UserCreator.h"
#include <QProcess>

bool UserCreator::createUser(const QString &name,const QString &pass){
    QProcess::execute("useradd", QStringList()<<"-m"<<name);
    QProcess::execute("bash", QStringList()<<"-c"<<QString("echo '%1:%2' | chpasswd").arg(name,pass));
    return true;
}
