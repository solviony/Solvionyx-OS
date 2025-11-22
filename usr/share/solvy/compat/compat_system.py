#!/usr/bin/env python3
# v1/system
import platform

def get_system_info():
    return {
        "os": platform.system(),
        "version": platform.version(),
        "release": platform.release()
    }
