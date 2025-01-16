#!/bin/sh

CDIR=$(pwd)

function setup_mklib() {
    if [ ! -f tools/mklib/mklib.sh ]; then
        if [ ! -d tools ]; then
            mkdir tools
        fi
        cd tools
        git clone http://localhost:3000/andrey/mklib.git
    else 
        cd tools/mklib
        git pull
    fi
    cd ${CDIR}
}

setup_mklib
source ${CDIR}/tools/mklib/mklib.sh