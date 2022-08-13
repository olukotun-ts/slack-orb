#!/usr/bin/sh

if uname -s | grep "MSYS" >/dev/null; then 
    file src/script/notify.sh
    dos2unix src/scripts/notify.sh
    file src/script/notify.sh
fi