
#include "InstallerEngine.h"
#include <QProcess>
#include <QDebug>

InstallerEngine::InstallerEngine(){}

void InstallerEngine::startInstall(){
    m_busy=true; emit busyChanged();
    emit progress(10);
    QProcess::execute("mkdir", QStringList()<<"/target");
    emit progress(50);
    emit progress(100);
    m_busy=false; emit busyChanged();
    emit done();
}
