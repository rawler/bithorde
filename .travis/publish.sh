#!/bin/bash

if [ -f ~/.ssh/id_rsa ]; then
	git push git@github.com:rawler/bithorde.git $TRAVIS_COMMIT:master
	git push git+ssh://rawler@git.launchpad.net/bithorde $TRAVIS_COMMIT:master
fi

