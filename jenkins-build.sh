#!/bin/bash -x

mkdir -p build/usr/sbin/
mkdir -p build/etc/stomp-git/
mkdir -p build/etc/init.d/

cp stomp-git build/usr/sbin/stomp-git
cp stomp-git.yaml build/etc/stomp-git/stomp-git.yaml
cp stomp-git.initscript build/etc/init.d/stomp-git

PKG_VER=`grep '^version' stomp-git | awk -F\" '{print $2}'`
BUILDN=${BUILD_NUMBER:=1}

/usr/bin/fakeroot /usr/local/bin/fpm -s dir -t deb -n "stomp-git" -f \
  -v ${PKG_VER}.${BUILDN} --description "Future remote repo tracker" \
  --config-files /etc/stomp-git/stomp-git.yaml \
  -a all -m "<list.itoperations@futurenet.com>" \
  -C ./build .

