#!/usr/bin/sh

pwd
if uname -s | grep "MSYS" >/dev/null; then 
    dos2unix src/scripts/notify.sh
fi