#! /usr/bin/env bash
: ${arch="$(dpkg-architecture -qDEB_HOST_ARCH)"}
: ${release="$(lsb_release -sc)"}
: ${SUDO=sudo}

set -euo pipefail
IFS=$'\n\t'

BOX_ACTION_NONE="none"
BOX_ACTION_INSTALL="install"
BOX_ACTION_UPGRADE="upgrade"

BOX_STATUS_MISSING="missing"
BOX_STATUS_OUTDATED="outdated"
BOX_STATUS_LATEST="latest"
BOX_STATUS_MISMATCH="mismatch"

APT_CACHE_UP_TO_DATE="false"
APT_INSTALL_CACHE=$(mktemp)
APT_UPGRADE_CACHE=$(mktemp)

SECTION_PREFIX=''

function satisfy () {
  local TYPE=$1
  shift

  check-"$TYPE" "$@"
  print-box-status "$TYPE" "$1"
  satisfy-"$TYPE" "$@"
}

function check () {
  local TYPE=$1
  shift
  check-"$TYPE" "$@"

  if [[ "$BOX_STATUS" = "$BOX_STATUS_LATEST" ]]; then
    return 0
  fi
  return 1
}

function section () {
  local LABEL=$1
  local COLOUR_END='\033[0m'
  local MAGENTA='\033[0;35m'
  printf "%s[" "$SECTION_PREFIX"
  if [[ -t 1 ]]; then
    printf "%b" "$MAGENTA"
  fi
  printf "%s" "$LABEL"
  if [[ -t 1 ]]; then
    printf "%b" "$COLOUR_END"
  fi
  printf "]\n"

  SECTION_PREFIX="  $SECTION_PREFIX"
}

function end-section () {
  SECTION_PREFIX=${SECTION_PREFIX/#  /}
  if [[ $SECTION_PREFIX = '' ]]; then
    echo
  fi
}

function must-install () {
  local TYPE=$1
  shift
  check-"$TYPE" "$@"

  if [[ "$BOX_STATUS" = "$BOX_STATUS_MISSING" ]]; then
    return 0
  fi
  return 1
}

function must-upgrade () {
  local TYPE=$1
  shift
  check-"$TYPE" "$@"

  if [[ "$BOX_STATUS" = "$BOX_STATUS_OUTDATED" ]]; then
    return 0
  fi
  return 1
}

function did-install () {
  if [[ "$BOX_ACTION" = "$BOX_ACTION_INSTALL" ]]; then
    return 0
  else
    return 1
  fi
}

function did-upgrade () {
  if [[ "$BOX_ACTION" = "$BOX_ACTION_UPGRADE" ]]; then
    return 0
  else
    return 1
  fi
}

function execute-function () {
  local PREFIX=$1
  local IDENTIFIER=$2

  IDENTIFIER=${IDENTIFIER/#[^A-Za-z0-9]/}
  IDENTIFIER=${IDENTIFIER//[^A-Za-z0-9]/-}

  local TEMP_DIR
  TEMP_DIR=$(mktemp --directory)
  cd "$TEMP_DIR"
  "$PREFIX"-"$IDENTIFIER"
  cd "$OLDPWD"
}

function check-if-apt-cache-needs-update () {
  if [[ ! "$APT_CACHE_UP_TO_DATE" = "true" ]]; then
    dpkg-query -W -f='${Package}\n' > "$APT_INSTALL_CACHE"

    set +e
    apt-get -s upgrade | grep '^Inst' | cut -d ' ' -f 2 > "$APT_UPGRADE_CACHE"
    set -e
    APT_CACHE_UP_TO_DATE="true"
  fi
}

function check-apt () {
  local PACKAGE=$1

  check-if-apt-cache-needs-update

  if ! grep -q --line-regexp --fixed-strings "$PACKAGE" < "$APT_INSTALL_CACHE"; then
    BOX_STATUS=$BOX_STATUS_MISSING
  elif grep -q --line-regexp --fixed-strings "$PACKAGE" < "$APT_UPGRADE_CACHE"; then
    BOX_STATUS=$BOX_STATUS_OUTDATED
  else
    BOX_STATUS=$BOX_STATUS_LATEST
  fi
}

function satisfy-apt () {
  local PACKAGE=$1

  if [[ "$BOX_STATUS" = "$BOX_STATUS_LATEST" ]]; then
    BOX_ACTION=$BOX_ACTION_NONE
  else
    $SUDO apt-get -y install "$PACKAGE"
    APT_CACHE_UP_TO_DATE="false"

    if [[ "$BOX_STATUS" = "$BOX_STATUS_OUTDATED" ]]; then
      BOX_ACTION=$BOX_ACTION_UPGRADE
    elif [[ "$BOX_STATUS" = "$BOX_STATUS_MISSING" ]]; then
      BOX_ACTION=$BOX_ACTION_INSTALL
    fi
  fi
}

function check-deb () {
  local PACKAGE=$1
  local URL=$2

  check-if-apt-cache-needs-update

  if ! grep -q --line-regexp --fixed-strings "$PACKAGE" < "$APT_INSTALL_CACHE"; then
    BOX_STATUS=$BOX_STATUS_MISSING
  else
    BOX_STATUS=$BOX_STATUS_LATEST
  fi
}

function satisfy-deb () {
  local PACKAGE=$1
  local URL=$2

  if [[ "$BOX_STATUS" = "$BOX_STATUS_LATEST" ]]; then
    BOX_ACTION=$BOX_ACTION_NONE
  else
    local TEMP_DIR
    TEMP_DIR=$(mktemp --directory)
    cd "$TEMP_DIR"
    wget -O package.deb "$URL"
    $SUDO dpkg -i package.deb
    cd "$OLDPWD"
    BOX_ACTION=$BOX_ACTION_INSTALL
  fi
}

function check-apt-ppa () {
  local PPA=$1
  local SEARCH
  SEARCH=${PPA/#ppa:/}

  if apt-cache policy | grep -q "$SEARCH"; then
    BOX_STATUS=$BOX_STATUS_LATEST
  else
    BOX_STATUS=$BOX_STATUS_MISSING
  fi
}

function satisfy-apt-ppa () {
  local PPA=$1

  if [[ "$BOX_STATUS" = "$BOX_STATUS_LATEST" ]]; then
    BOX_ACTION=$BOX_ACTION_NONE
  else
    $SUDO add-apt-repository -y "$PPA"
    $SUDO apt-get -y update
    APT_CACHE_UP_TO_DATE="false"
    BOX_ACTION=$BOX_ACTION_INSTALL
  fi
}

function check-file-line () {
  local COMMENT=$1
  local FILE_PATH=$2
  local LINE=$3
  local CHECK_LINE="$LINE"
  [[ "$COMMENT" ]] && CHECK_LINE="$LINE # $COMMENT"

  if [[ -f "$FILE_PATH" ]]; then
    if grep -q --line-regexp --fixed-strings "$CHECK_LINE" "$FILE_PATH"; then
      BOX_STATUS=$BOX_STATUS_LATEST
    else
      BOX_STATUS=$BOX_STATUS_MISSING
    fi
  else
    BOX_STATUS=$BOX_STATUS_MISSING
  fi
}

function satisfy-file-line () {
  local COMMENT=$1
  local FILE_PATH=$2
  local LINE=$3
  local ADD_LINE="$LINE"
  [[ "$COMMENT" ]] && ADD_LINE="$LINE # $COMMENT"

  if [[ "$BOX_STATUS" = "$BOX_STATUS_LATEST" ]]; then
    BOX_ACTION=$BOX_ACTION_NONE
  else
    echo "$ADD_LINE" >> "$FILE_PATH"
    BOX_ACTION=$BOX_ACTION_INSTALL
  fi
}

function check-symlink () {
  local TARGET=$1
  local NAME=$2

  if [[ -L $NAME ]]; then
    local EXISTING_TARGET
    EXISTING_TARGET=$(readlink -f "$NAME")

    if [[ "$EXISTING_TARGET" = "$TARGET" ]]; then
      BOX_STATUS=$BOX_STATUS_LATEST
    else
      BOX_STATUS=$BOX_STATUS_MISMATCH
    fi
  elif [[ -e $NAME ]]; then
    BOX_STATUS=$BOX_STATUS_MISMATCH
  else
    BOX_STATUS=$BOX_STATUS_MISSING
  fi
}

function satisfy-symlink () {
  local TARGET=$1
  local NAME=$2

  if [[ "$BOX_STATUS" = "$BOX_STATUS_LATEST" ]]; then
    BOX_ACTION=$BOX_ACTION_NONE
  elif [[ "$BOX_STATUS" = "$BOX_STATUS_MISSING" ]]; then
    ln -s "$TARGET" "$NAME"
    BOX_ACTION=$BOX_ACTION_INSTALL
  elif [[ "$BOX_STATUS" = "$BOX_STATUS_MISMATCH" ]]; then
    echo "Couldn't create symlink $NAME, because it already exists"
    echo "and is either a file, or a symlink pointing somewhere else."
    exit 1
  fi
}

function check-golang () {
  local VERSION=$1

  if type go &>/dev/null; then
    local CURRENT_VERSION
    CURRENT_VERSION=$(go version | cut -d ' ' -f 3)

    if [[ "$CURRENT_VERSION" = "$VERSION" ]]; then
      BOX_STATUS=$BOX_STATUS_LATEST
    else
      BOX_STATUS=$BOX_STATUS_MISMATCH
    fi
  else
    BOX_STATUS=$BOX_STATUS_MISSING
  fi
}

function satisfy-golang () {
  local VERSION=$1
  local local_file
  local local_dest="$HOME/.local"
  [[ -w /usr/local ]] && local_dest=/usr/local

  if [[ "$BOX_STATUS" = "$BOX_STATUS_LATEST" ]]; then
    BOX_ACTION=$BOX_ACTION_NONE
  elif [[ "$BOX_STATUS" = "$BOX_STATUS_MISMATCH" ]]; then
    exit 1
  else
    local TEMP_DIR
    TEMP_DIR=$(mktemp --directory)
    cd "$TEMP_DIR"
    case $arch in
      amd64) local_file="go${VERSION}.linux-amd64.tar.gz" ;;
      i386|i686) local_file="go${VERSION}.linux-386.tar.gz" ;;
    esac
    wget "https://redirector.gvt1.com/edgedl/go/${local_file}"
    tar -C "$local_dest" -axf "${local_file}"
    cd "$OLDPWD"
    BOX_ACTION=$BOX_ACTION_INSTALL
  fi
}

function satisfy-executable () {
  local EXECUTABLE=$1

  if [[ "$BOX_STATUS" = "$BOX_STATUS_MISSING" ]]; then
    execute-function "install" "$EXECUTABLE"
  fi
}

function check-executable () {
  local EXECUTABLE=$1

  if hash "$EXECUTABLE" 2>/dev/null; then
    BOX_STATUS=$BOX_STATUS_LATEST
  else
    BOX_STATUS=$BOX_STATUS_MISSING
  fi
}

function satisfy-file () {
  local NAME=$1
  local FILE=$2

  if [[ "$BOX_STATUS" = "$BOX_STATUS_MISSING" ]]; then
    execute-function "install" "$NAME"
  fi
}

function check-file () {
  local NAME=$1
  local FILE=$2

  if [[ -f $FILE ]]; then
    BOX_STATUS=$BOX_STATUS_LATEST
  else
    BOX_STATUS=$BOX_STATUS_MISSING
  fi
}

function check-go-package () {
  local PACKAGE=$1

  if go list "$PACKAGE" > /dev/null; then
    BOX_STATUS=$BOX_STATUS_LATEST
  else
    BOX_STATUS=$BOX_STATUS_MISSING
  fi
}

function satisfy-go-package () {
  local PACKAGE=$1

  if [[ "$BOX_STATUS" = "$BOX_STATUS_MISSING" ]]; then
    go get "$PACKAGE"
    BOX_ACTION=$BOX_ACTION_INSTALL
  else
    BOX_ACTION=$BOX_ACTION_NONE
  fi
}

function check-github () {
  local REPOSITORY=$1
  local DESTINATION=$2

  if [[ -d "$DESTINATION" ]]; then
    cd "$DESTINATION"
    git fetch --quiet > /dev/null

    if [[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]]; then
      BOX_STATUS=$BOX_STATUS_LATEST
    else
      BOX_STATUS=$BOX_STATUS_OUTDATED
    fi

    cd "$OLDPWD"
  else
    BOX_STATUS=$BOX_STATUS_MISSING
  fi
}

function satisfy-github () {
  local REPOSITORY=$1
  local DESTINATION=$2

  if [[ "$BOX_STATUS" = "$BOX_STATUS_MISSING" ]]; then
    git clone "$REPOSITORY" "$DESTINATION"
    BOX_ACTION=$BOX_ACTION_INSTALL
  elif [[ "$BOX_STATUS" = "$BOX_STATUS_OUTDATED" ]]; then
    cd "$DESTINATION"
    git pull
    cd "$OLDPWD"
    BOX_ACTION=$BOX_ACTION_UPGRADE
  else
    BOX_ACTION=$BOX_ACTION_NONE
  fi
}

function check-dconf () {
  local LABEL=$1
  local DCONF_PATH=$2
  local DCONF_KEY=$3
  local DCONF_VALUE=$4

  local CURRENT_VALUE
  CURRENT_VALUE=$(gsettings get "$DCONF_PATH" "$DCONF_KEY" 2> /dev/null || :)

  if [[ "$CURRENT_VALUE" = "$DCONF_VALUE" ]] || [[ "$CURRENT_VALUE" = "'$DCONF_VALUE'" ]]; then
    BOX_STATUS=$BOX_STATUS_LATEST
  else
    BOX_STATUS=$BOX_STATUS_MISSING
  fi
}

function satisfy-dconf () {
  local LABEL=$1
  local DCONF_PATH=$2
  local DCONF_KEY=$3
  local DCONF_VALUE=$4

  if [[ "$BOX_STATUS" = "$BOX_STATUS_MISSING" ]]; then
    BOX_ACTION=$BOX_ACTION_INSTALL
    gsettings set "$DCONF_PATH" "$DCONF_KEY" "$DCONF_VALUE"
  else
    BOX_ACTION=$BOX_ACTION_NONE
  fi
}

function print-box-status () {
  local TYPE=$1
  local LABEL=$2

  if [[ -t 1 ]]; then
    local COLOUR_END='\033[0m'
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[0;33m'
    local BLUE='\033[0;34m'

    if [[ "$BOX_STATUS" = "$BOX_STATUS_MISSING" ]]; then
      local COLOUR=$RED
    elif [[ "$BOX_STATUS" = "$BOX_STATUS_OUTDATED" ]]; then
      local COLOUR=$YELLOW
    elif [[ "$BOX_STATUS" = "$BOX_STATUS_LATEST" ]]; then
      local COLOUR=$GREEN
    elif [[ "$BOX_STATUS" = "$BOX_STATUS_MISMATCH" ]]; then
      local COLOUR=$RED
    fi

    printf "%s%b%s%b %s -> %b%s%b\n" "$SECTION_PREFIX" "$BLUE" "$TYPE" "$COLOUR_END" "$LABEL" "$COLOUR" "$BOX_STATUS" "$COLOUR_END"
  else
    echo "$SECTION_PREFIX$TYPE $LABEL -> $BOX_STATUS"
  fi
}
