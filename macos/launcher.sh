#!/bin/bash
# MinuteModem.app launcher
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REL_DIR="$SCRIPT_DIR/../Resources/rel"

# macOS standard directories
export MM_DATA_DIR="$HOME/Library/Application Support/MinuteModem"
export MM_DB_PATH="$MM_DATA_DIR/minutemodem.db"
export MM_LOG_DIR="$HOME/Library/Logs/MinuteModem"
mkdir -p "$MM_DATA_DIR" "$MM_LOG_DIR"

export RELEASE_LOG_DIR="$MM_LOG_DIR"

exec "$REL_DIR/bin/minutemodem_station" start
