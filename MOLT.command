#!/usr/bin/env bash
# Double-click in Finder to install and open the local control center.
exec /bin/bash "$(cd "$(dirname "$0")" && pwd -P)/install.sh" --interactive
