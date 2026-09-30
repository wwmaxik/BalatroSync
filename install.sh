#!/usr/bin/env bash
# ==============================================================================
# BalatroSync Installer for Linux / Steam Deck / Proton
# Automatically sets up Lovely Injector, BalatroSync Mod, and TLS helpers.
# Supports 1-line installation via:
#   curl -sSL https://raw.githubusercontent.com/wwmaxik/BalatroSync/main/install.sh | bash
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}"
echo "============================================================"
echo "           BalatroSync Cloud Mod Installer (Linux)         "
echo "============================================================"
echo -e "${NC}"

# Helper for interactive prompt when piped from curl into bash
prompt_read() {
    local prompt_msg="$1"
    local var_name="$2"
    if [ -e /dev/tty ]; then
        read -rp "$prompt_msg" "$var_name" < /dev/tty || true
    else
        read -rp "$prompt_msg" "$var_name" || true
    fi
}

# 0. Resolve payload directory (Local directory vs. curl | bash pipe)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
PAYLOAD_DIR=""

if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/Mod" ]; then
    PAYLOAD_DIR="$SCRIPT_DIR"
else
    echo -e "${BLUE}[*] Remote one-liner detected. Downloading BalatroSync package...${NC}"
    TMP_WORK_DIR=$(mktemp -d /tmp/balatrosync_install.XXXXXX)
    TAR_URL="https://github.com/wwmaxik/BalatroSync/archive/refs/heads/main.tar.gz"

    if command -v curl &>/dev/null; then
        curl -sSL "$TAR_URL" | tar -xz -C "$TMP_WORK_DIR"
    elif command -v wget &>/dev/null; then
        wget -qO- "$TAR_URL" | tar -xz -C "$TMP_WORK_DIR"
    else
        echo -e "${RED}[ERROR] Neither curl nor wget found. Please install curl or wget.${NC}"
        exit 1
    fi

    FOUND_MOD_DIR=$(find "$TMP_WORK_DIR" -maxdepth 3 -type d -name "Mod" 2>/dev/null | head -n 1 || true)
    if [ -n "$FOUND_MOD_DIR" ]; then
        PAYLOAD_DIR="$(dirname "$FOUND_MOD_DIR")"
    else
        echo -e "${RED}[ERROR] Failed to extract BalatroSync payload.${NC}"
        exit 1
    fi
    trap 'rm -rf "$TMP_WORK_DIR"' EXIT
fi

# 1. Search for Steam directories
STEAM_DIRS=(
    "$HOME/.steam/debian-installation"
    "$HOME/.steam/steam"
    "$HOME/.local/share/Steam"
    "$HOME/.var/app/com.valvesoftware.Steam/.steam/steam"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
)

FOUND_LIBRARIES=()

for sdir in "${STEAM_DIRS[@]}"; do
    if [ -d "$sdir" ]; then
        FOUND_LIBRARIES+=("$sdir")
        # Check libraryfolders.vdf for extra drives/mounts
        vdf="$sdir/steamapps/libraryfolders.vdf"
        if [ -f "$vdf" ]; then
            while IFS= read -r line; do
                if [[ "$line" =~ \"path\"[[:space:]]+\"([^\"]+)\" ]]; then
                    lib_path="${BASH_REMATCH[1]}"
                    if [ -d "$lib_path" ]; then
                        FOUND_LIBRARIES+=("$lib_path")
                    fi
                fi
            done < "$vdf"
        fi
    fi
done

# Add common manual locations
FOUND_LIBRARIES+=("/mnt/games" "/mnt/games/Balatro" "$HOME/Games" "$HOME/Games/Balatro")

# 2. Locate Balatro Game Directory
BALATRO_DIR=""

for lib in "${FOUND_LIBRARIES[@]}"; do
    if [ -f "$lib/steamapps/common/Balatro/Balatro.exe" ]; then
        BALATRO_DIR="$lib/steamapps/common/Balatro"
        break
    elif [ -f "$lib/Balatro.exe" ]; then
        BALATRO_DIR="$lib"
        break
    fi
done

if [ -z "$BALATRO_DIR" ]; then
    echo -e "${YELLOW}[!] Balatro installation not automatically found.${NC}"
    prompt_read "Please enter the path to your Balatro directory: " user_path
    user_path="${user_path/#\~/$HOME}"
    if [ -f "$user_path/Balatro.exe" ]; then
        BALATRO_DIR="$user_path"
    else
        echo -e "${RED}[ERROR] Balatro.exe not found at '$user_path'. Aborting.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}[✓] Found Balatro game directory:${NC} $BALATRO_DIR"

# 3. Locate Proton Compatdata (AppData/Roaming/Balatro)
PROTON_BALATRO_APPDATA=""

for lib in "${FOUND_LIBRARIES[@]}"; do
    # Check official Steam AppID 2379780
    cand="$lib/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro"
    if [ -d "$cand" ]; then
        PROTON_BALATRO_APPDATA="$cand"
        break
    fi
done

if [ -z "$PROTON_BALATRO_APPDATA" ]; then
    # Search for any compatdata folder containing AppData/Roaming/Balatro
    for lib in "${FOUND_LIBRARIES[@]}"; do
        if [ -d "$lib/steamapps/compatdata" ]; then
            found_appdata=$(find "$lib/steamapps/compatdata" -maxdepth 8 -type d -path "*/AppData/Roaming/Balatro" 2>/dev/null | head -n 1 || true)
            if [ -n "$found_appdata" ] && [ -d "$found_appdata" ]; then
                PROTON_BALATRO_APPDATA="$found_appdata"
                break
            fi
        fi
    done
fi

if [ -n "$PROTON_BALATRO_APPDATA" ]; then
    echo -e "${GREEN}[✓] Found Proton save directory:${NC} $PROTON_BALATRO_APPDATA"
else
    echo -e "${YELLOW}[!] Proton save directory not found yet (game may not have been run once under Proton).${NC}"
fi

# 4. Check & Install Lovely Injector (version.dll)
echo ""
echo -e "${BLUE}[*] Checking Lovely mod injector...${NC}"
if [ -f "$BALATRO_DIR/version.dll" ]; then
    echo -e "${GREEN}[✓] Lovely injector (version.dll) is already installed.${NC}"
else
    echo -e "${YELLOW}[*] Downloading Lovely injector (v0.10.0)...${NC}"
    LOVELY_URL="https://github.com/ethangreen-dev/lovely-injector/releases/download/v0.10.0/lovely-x86_64-pc-windows-msvc.zip"
    TMP_ZIP="/tmp/lovely_injector.zip"
    TMP_EXTRACT="/tmp/lovely_extracted"
    rm -rf "$TMP_ZIP" "$TMP_EXTRACT"
    mkdir -p "$TMP_EXTRACT"

    if command -v curl &>/dev/null; then
        curl -sL "$LOVELY_URL" -o "$TMP_ZIP"
    elif command -v wget &>/dev/null; then
        wget -q "$LOVELY_URL" -O "$TMP_ZIP"
    else
        echo -e "${RED}[ERROR] Neither curl nor wget found. Please download Lovely version.dll manually.${NC}"
        exit 1
    fi

    if command -v unzip &>/dev/null; then
        unzip -q "$TMP_ZIP" -d "$TMP_EXTRACT"
        cp "$TMP_EXTRACT/version.dll" "$BALATRO_DIR/version.dll"
        rm -rf "$TMP_ZIP" "$TMP_EXTRACT"
        echo -e "${GREEN}[✓] Installed Lovely injector (version.dll) into Balatro game directory.${NC}"
    else
        echo -e "${YELLOW}[!] 'unzip' command not found. Please extract $TMP_ZIP into $BALATRO_DIR manually.${NC}"
    fi
fi

# 5. Copy Windows curl helper for Proton TLS stability
echo ""
echo -e "${BLUE}[*] Installing TLS network helper (curl.exe)...${NC}"
if [ -f "$PAYLOAD_DIR/bin/curl.exe" ]; then
    cp -v "$PAYLOAD_DIR/bin/curl.exe" "$BALATRO_DIR/"
    [ -f "$PAYLOAD_DIR/bin/libcurl-x64.dll" ] && cp -v "$PAYLOAD_DIR/bin/libcurl-x64.dll" "$BALATRO_DIR/"
    [ -f "$PAYLOAD_DIR/bin/curl-ca-bundle.crt" ] && cp -v "$PAYLOAD_DIR/bin/curl-ca-bundle.crt" "$BALATRO_DIR/"
    echo -e "${GREEN}[✓] TLS network helpers installed.${NC}"
fi

# 6. Install BalatroSync Mod Files
echo ""
echo -e "${BLUE}[*] Installing BalatroSync mod files...${NC}"
GAME_MODS_DIR="$BALATRO_DIR/Mods/BalatroSync"
mkdir -p "$GAME_MODS_DIR"

cp -v "$PAYLOAD_DIR/Mod/lovely.toml" "$GAME_MODS_DIR/"
cp -v "$PAYLOAD_DIR/Mod/sync_mod.lua" "$GAME_MODS_DIR/"
cp -v "$PAYLOAD_DIR/Mod/sync_thread.lua" "$GAME_MODS_DIR/"

if [ -n "$PROTON_BALATRO_APPDATA" ]; then
    PROTON_MODS_DIR="$PROTON_BALATRO_APPDATA/Mods/BalatroSync"
    mkdir -p "$PROTON_MODS_DIR"
    cp -v "$PAYLOAD_DIR/Mod/lovely.toml" "$PROTON_MODS_DIR/"
    cp -v "$PAYLOAD_DIR/Mod/sync_mod.lua" "$PROTON_MODS_DIR/"
    cp -v "$PAYLOAD_DIR/Mod/sync_thread.lua" "$PROTON_MODS_DIR/"
fi

# 7. Setup Configuration (Optional Setup Code)
echo ""
echo -e "${CYAN}------------------------------------------------------------${NC}"
echo -e "You can configure your Cloudflare Worker URL & Token right now,"
echo -e "or skip and paste it directly in the in-game GUI via ${BOLD}[ Paste All ]${NC}."
echo -e "${CYAN}------------------------------------------------------------${NC}"
setup_input=""
prompt_read "Paste Setup Code (URL#TOKEN) or press [ENTER] to skip: " setup_input

TARGET_CONFIG="$GAME_MODS_DIR/config.json"
WORKER_URL=""
AUTH_TOKEN=""
DEVICE_ID="PC-SECONDARY"

if [[ "$setup_input" =~ (https?://[^#[:space:]]+)#([^[:space:]]+) ]]; then
    WORKER_URL="${BASH_REMATCH[1]}"
    AUTH_TOKEN="${BASH_REMATCH[2]}"
    echo -e "${GREEN}[✓] Parsed Setup Code successfully!${NC}"
elif [ -n "$setup_input" ]; then
    echo -e "${YELLOW}[!] Unrecognized format. A template config will be created.${NC}"
fi

if [ -f "$TARGET_CONFIG" ] && [ -z "$WORKER_URL" ]; then
    echo -e "${GREEN}[✓] Preserved existing config.json.${NC}"
else
    cat <<EOF > "$TARGET_CONFIG"
{
  "worker_url": "${WORKER_URL:-https://balatro.wwmaxik.ru}",
  "auth_token": "${AUTH_TOKEN:-your-secret-auth-token}",
  "device_id": "${DEVICE_ID}",
  "auto_sync": true
}
EOF
    echo -e "${GREEN}[✓] Created config.json at $TARGET_CONFIG${NC}"
    if [ -n "$PROTON_BALATRO_APPDATA" ]; then
        mkdir -p "$PROTON_BALATRO_APPDATA/Mods/BalatroSync"
        cp "$TARGET_CONFIG" "$PROTON_BALATRO_APPDATA/Mods/BalatroSync/config.json"
    fi
fi

# 8. Finished & Steam Launch Option Reminder
echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}           BalatroSync Installation Complete!               ${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo ""
echo -e "${BOLD}Important reminder for Proton on Linux / Steam Deck:${NC}"
echo -e "In Steam, right-click ${CYAN}Balatro${NC} -> ${CYAN}Properties...${NC}"
echo -e "In ${CYAN}Launch Options${NC}, ensure you have:"
echo -e "    ${YELLOW}WINEDLLOVERRIDES=\"version=n,b\" %command%${NC}"
echo ""
echo -e "To configure in game: ${BOLD}Options -> Settings -> Cloud Sync${NC} tab."
echo -e "Enjoy automatic cross-platform cloud saves!"
echo ""
