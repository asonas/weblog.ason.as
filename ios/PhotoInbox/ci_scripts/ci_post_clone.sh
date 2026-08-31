#!/bin/sh

set -eu

brew install xcodegen
xcodegen generate \
  --spec "$CI_PRIMARY_REPOSITORY_PATH/ios/PhotoInbox/project.yml" \
  --project "$CI_PRIMARY_REPOSITORY_PATH/ios/PhotoInbox"
