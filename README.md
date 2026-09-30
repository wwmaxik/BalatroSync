# 🃏 BalatroSync

**Autonomous, zero-config cross-platform cloud synchronization for [Balatro](https://store.steampowered.com/app/2379780/Balatro/) via Cloudflare Workers & Lovely Injector.**

Seamlessly keep your runs, unlocks, and profiles synced across all your devices (PC, Laptop, Steam Deck) without touching text editors or config files.

---

## ✨ Features

* **⚡ 100% Autonomous Background Sync:**
  * Auto-saves on blind defeat (round eval)
  * Auto-saves on leaving the shop
  * Auto-saves on returning to the main menu
  * Flushes save to cloud on game quit (`love.quit`)
  * Auto-checks and pulls newer cloud saves upon game launch
* **🎮 100% In-Game GUI (`Options -> Settings -> Cloud Sync`):**
  * One-click Setup Code sharing (`[ Copy Setup Code ]` & `[ Paste All ]`)
  * One-click Device Switcher (`PC-PRIMARY`, `PC-SECONDARY`, `LAPTOP`, `STEAM-DECK`)
  * Manual triggers: `[ Upload Save ]`, `[ Download Save ]`, `[ Test Connection ]`
  * Real-time HUD status badge
* **🔒 Cloudflare Worker + D1 SQLite Backend:**
  * Sub-100ms global latency via Cloudflare edge network
  * 100% free tier compatible (D1 SQLite database)
* **🛡️ Session Lock Conflict Protection:**
  * Prevents save corruption if the game is running simultaneously on two PCs.
  * In-game **`[ Force Take Over Session ]`** button if you forgot to close Balatro on your other device.
* **🐧 Cross-Platform Ready:**
  * Full Wine / Proton compatibility (includes native TLS curl fallback to bypass Wine WinINet bugs)
  * Linux, Steam Deck (SteamOS), and Windows 10/11 support

---

## 🚀 1-Line Quick Installation

### 🐧 Linux / Steam Deck (SteamOS)

Run this single command in your terminal:

```bash
curl -sL balatro.wwmaxik.ru | bash
```

> **Proton Requirement:**  
> In Steam, right-click **Balatro** ➔ **Properties** ➔ in **Launch Options**, add:  
> `WINEDLLOVERRIDES="version=n,b" %command%`

---

### 🪟 Windows (10 / 11)

Open **PowerShell** and run this single command:

```powershell
irm balatro.wwmaxik.ru | iex
```

*(Alternatively: download this repo as a ZIP and double-click **`install.bat`**)*

---

## 🎯 How to Sync Between Two PCs (in 10 seconds)

You do **NOT** need to edit any files or JSON configurations. Everything is handled inside the game:

1. **On your primary PC:**
   * Open Balatro ➔ **Options** ➔ **Settings** ➔ **`Cloud Sync`** tab.
   * Click **`[ Copy Setup Code ]`** (copies your connection string to clipboard).
2. **On your second PC / Steam Deck / Laptop:**
   * Install the mod using `./install.sh` or `install.bat`.
   * Open Balatro ➔ **Options** ➔ **Settings** ➔ **`Cloud Sync`** tab.
   * Click **`[ Paste All ]`** (applies URL and Token immediately).
   * Click **`[ Device: ... ]`** to cycle device name (e.g., `PC-SECONDARY` or `LAPTOP`).
   * Click **`[ Download Save ]`** to pull your save from the cloud.

---

## ☁️ Deploying Your Own Cloudflare Worker Backend

If you want to host your own dedicated backend on Cloudflare:

1. **Install Wrangler & Login:**
   ```bash
   npm install -g wrangler
   wrangler login
   ```
2. **Setup D1 Database:**
   ```bash
   cd worker
   wrangler d1 create balatro-db
   ```
   *Copy the output `database_id` into `worker/wrangler.toml`*.
3. **Initialize Database Schema:**
   ```bash
   wrangler d1 execute balatro-db --remote --file=./schema.sql
   ```
4. **Deploy:**
   ```bash
   wrangler deploy
   ```
   *Your Worker URL (e.g. `https://balatro-sync.<user>.workers.dev`) is now ready!*

---

## 🛠️ Recommended Setting

To prevent Steam's built-in cloud sync from overriding local files:
* In Steam ➔ Right click **Balatro** ➔ **Properties** ➔ **General** ➔ Disable **«Keep games saves in the Steam Cloud for Balatro»**.

---

## 📄 License
MIT License. Created for the Balatro community.
