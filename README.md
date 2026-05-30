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

A helper script handles everything. It uses `web-ext` via `npx`, so you only
need **Node.js** installed plus a **Firefox** build.

### Recommended: permanent install into your real profile

This sideloads the extension **into your default Firefox profile** so it loads
automatically on every launch and your **WhatsApp Web login persists** — no
re-login, no manual steps. Re-run the same command any time to update.

```bash
# macOS / Linux
./install-firefox.sh install
```

```powershell
# Windows — or just double-click install-firefox.cmd
.\install-firefox.ps1 install
```

What it does: builds the package, finds your default profile from
`profiles.ini`, closes Firefox if it's running (asks first — pass `-y` /`-Yes`
to skip the prompt), writes the required prefs to the profile's `user.js`, drops
the packaged `whatsapp-translator@transapp.xpi` into the profile's `extensions/`
folder, and relaunches Firefox on WhatsApp Web.

> **Requires Firefox Developer Edition, Nightly, ESR, or an Unbranded build.**
> Regular **release/beta Firefox refuses unsigned extensions** and there is no
> pref to bypass it — on release, use the **signed** install below instead. The
> script auto-prefers a Dev/ESR/Nightly profile when you have more than one.

Options:

| Flag | Effect |
|------|--------|
| `-y` / `-Yes` | Don't prompt — close Firefox automatically if it's running. |
| `--no-launch` / `-NoLaunch` | Don't relaunch Firefox afterwards. |
| `--profile <path>` / `-ProfilePath <path>` | Target a specific profile instead of auto-detecting. |

To remove it again:

```bash
./install-firefox.sh uninstall       # macOS / Linux
.\install-firefox.ps1 uninstall      # Windows
```

This deletes the sideloaded XPI and removes **only** the managed block from
`user.js`, leaving your other settings untouched.

### Other modes

```text
run     Launch a throwaway profile with the extension loaded (quick testing;
        you log into WhatsApp in that temp profile, nothing is persisted).
build   Build an unsigned .xpi/.zip into ./dist.
sign    Build a Mozilla-SIGNED .xpi (works on release Firefox; needs AMO creds).
lint    Validate the extension with web-ext.
```

On **Windows**, the PowerShell script auto-detects Firefox (Developer Edition /
Nightly / ESR / release) from the standard install folders and the registry,
including per-user installs. `install-firefox.cmd` is a double-click wrapper that
runs the `.ps1` with a one-time execution-policy bypass and forwards arguments.

### Permanent install on release Firefox (signed)

Release/beta Firefox only loads **signed** extensions. Get free AMO API
credentials at <https://addons.mozilla.org/developers/addon/api/key/>, then:

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

Open the resulting signed `.xpi` in Firefox to install it permanently. (A signed
build also works with `install` — drop it into the profile yourself, or just
open the `.xpi`.)

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
