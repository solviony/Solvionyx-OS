#!/bin/bash
# Portable Solvy launcher
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
python3 "$DIR/solvy_portable_daemon.py" &
python3 "$DIR/solvy_portable_gui.py"
