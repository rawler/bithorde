#!/bin/bash
#
# SSH Authentication
#
if [ -z "$id_rsa_{1..23}" ]; then echo 'No $id_rsa_{1..23} found !' ; exit 1; fi

# Careful ! Put the correct number here !!! (the last line number)
echo -n $id_rsa_{1..23} >> ~/.ssh/travis_rsa_64
base64 --decode --ignore-garbage ~/.ssh/travis_rsa_64 > ~/.ssh/id_rsa

chmod 600 ~/.ssh/id_rsa

echo -e ">>> Copy config"
mv -fv .travis/ssh-config ~/.ssh/config

echo -e ">>> Hi github.com !"
ssh -T git@github.com
ssh -T rawler@git.launchpad.net
echo -e "\n"


