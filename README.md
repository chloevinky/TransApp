# WhatsApp Translator

A browser extension that automatically translates incoming WhatsApp Web
messages into English using the Claude API. Works on **Chrome** and **Firefox**
from a single Manifest V3 codebase.

## How it works

- `content.js` watches the WhatsApp Web chat for message bubbles and sends their
  text to the extension's background script.
- `background.js` calls the Anthropic Messages API (`api.anthropic.com`) — done
  from the background so the request bypasses CORS via `host_permissions`.
- `popup.html` / `popup.js` is the settings UI: your Anthropic API key, the
  source language, the Claude model, and an on/off toggle.
- Translations replace the message text in place; turning the toggle off reverts
  every message to its original text.

Your API key and chat text go **directly from your browser to Anthropic** under
your own key — nothing is collected or stored by the extension author.

## Cross-browser design

The single `manifest.json` supports both browsers:

| Concern              | Chrome                     | Firefox                                  |
|----------------------|----------------------------|------------------------------------------|
| Background           | `background.service_worker`| `background.scripts` (event page)        |
| Add-on identity      | n/a                        | `browser_specific_settings.gecko.id`     |
| WebExtension API     | `chrome.*` (callbacks)     | `chrome.*` aliased to `browser.*`        |

Both background keys are intentionally present — each browser reads the one it
supports and ignores the other (this is the
[Mozilla-recommended](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/background)
cross-browser pattern). `web-ext lint` reports a single, expected
`BACKGROUND_SERVICE_WORKER_IGNORED` notice for the unused Chrome key on Firefox.

Firefox 142+ is required (it's the version that introduced the
`data_collection_permissions` manifest key the extension declares).

---

## Install on Firefox

A helper script handles every path. It uses `web-ext` via `npx`, so you only
need **Node.js** installed (plus **Firefox** for the `run` mode).

### macOS / Linux

```bash
# Launch Firefox with the extension loaded (temporary, best for trying it out)
./install-firefox.sh run

# Build an unsigned package into ./dist (load via about:debugging)
./install-firefox.sh build

# Build a Mozilla-SIGNED .xpi for a permanent install (needs AMO API keys)
./install-firefox.sh sign

# Validate the extension
./install-firefox.sh lint
```

### Windows

Use the PowerShell installer. Either double-click **`install-firefox.cmd`** (it
launches PowerShell with the execution policy bypassed for that one run), or run
it from a terminal:

```powershell
# Launch Firefox with the extension loaded (temporary, best for trying it out)
.\install-firefox.ps1 run

# Build an unsigned package into .\dist (load via about:debugging)
.\install-firefox.ps1 build

# Build a Mozilla-SIGNED .xpi for a permanent install (needs AMO API keys)
.\install-firefox.ps1 sign

# Validate the extension
.\install-firefox.ps1 lint
```

```bat
REM Or from cmd.exe / double-click — same modes:
install-firefox.cmd run
install-firefox.cmd build
```

The Windows script auto-detects Firefox (release / Developer Edition / Nightly /
ESR) from the standard install folders and the registry, including per-user
installs. AMO credentials for `sign` are read from `$env:WEB_EXT_API_KEY` and
`$env:WEB_EXT_API_SECRET`.

### Temporary install (any Firefox, no signing)

1. `./install-firefox.sh build`
2. Open `about:debugging#/runtime/this-firefox`
3. **Load Temporary Add-on…** → pick the `.zip` in `./dist`
   (removed when Firefox restarts)

`./install-firefox.sh run` automates this and opens `web.whatsapp.com` for you.

### Permanent install (release Firefox)

Release Firefox only installs **signed** extensions. Get AMO API credentials at
<https://addons.mozilla.org/developers/addon/api/key/>, then:

```bash
# macOS / Linux
export WEB_EXT_API_KEY="user:xxxxx:123"
export WEB_EXT_API_SECRET="xxxxxxxx"
./install-firefox.sh sign
```

```powershell
# Windows (PowerShell)
$env:WEB_EXT_API_KEY    = "user:xxxxx:123"
$env:WEB_EXT_API_SECRET = "xxxxxxxx"
.\install-firefox.ps1 sign
```

Open the resulting signed `.xpi` in Firefox to install it permanently.

### Permanent install without signing (Developer Edition / Nightly / ESR only)

In `about:config` set `xpinstall.signatures.required = false`, then install the
`./dist/*.zip` via `about:addons` → gear → **Install Add-on From File…**.

---

## Install on Chrome

1. Open `chrome://extensions`
2. Enable **Developer mode**
3. **Load unpacked** → select this project directory

---

## Configure

Click the extension's toolbar icon, then:

1. Paste your **Anthropic API key** (`sk-ant-…`).
2. Choose the **source language** to translate from.
3. Optionally set the **Claude model** (defaults to `claude-sonnet-4-6`).
4. Click **Test API Connection** to confirm it works, then toggle
   **Translation ON**.

> **Firefox note:** if translation fails with a network/permission error, open
> `about:addons` → WhatsApp Translator → **Permissions** and ensure access to
> `api.anthropic.com` is allowed.

## Development

```bash
npm install        # installs web-ext locally
npm run lint       # web-ext lint
npm run build      # package into ./dist
npm run start:firefox   # run in Firefox via web-ext
```
