# fakeviewport-win

fakeviewport-win opens UniFi Protect in Google Chrome as a full-screen viewport and keeps it alive on a Windows display machine.

Original fakeViewport project: https://github.com/Samuel1698/fakeViewport

This Windows version is built separately with native PowerShell and Chrome flags so it can run without Python, Selenium, or Linux services.

## What It Does

- Opens UniFi Protect in Google Chrome.
- Uses a dedicated Chrome profile so login, MFA, camera layout, and stream quality settings persist.
- Launches in kiosk/full-screen mode by default.
- Focuses the Protect view and tries to trigger the in-app camera fullscreen mode.
- Detects offline/login/loading states and reloads the Protect page before escalating to a browser restart.
- Detects when the Live View grid leaves fullscreen and restores it automatically.
- Restarts Chrome if it exits, becomes unhealthy, or stops responding through Chrome DevTools.
- Hides the cursor and common Protect controls for a clean display.
- Restarts Chrome once every 24 hours by default to refresh the connection.
- Writes timestamped logs with warning/error details.
- Optionally installs a Startup-folder shortcut to start on login.

## Quick Start

1. Install Google Chrome.
2. Double-click `setup-fakeviewport-win-profile.cmd`.
3. Follow the setup guide that opens in Chrome.
4. Sign in to Protect using either your direct UNVR IP or `unifi.ui.com`.
5. Open the desired Protect camera/live view and choose the stream quality you want.
6. Copy the full URL for the grid view you want to use fullscreen and paste it into `ProtectUrl` in `config.json`.
7. Close Chrome and run `start-fakeviewport-win.cmd`.

The provided `config.json` uses placeholders. Replace them with your own grid URL and login details:

```text
PASTE_YOUR_FULL_PROTECT_GRID_URL_HERE
```

## Configuration

Edit `config.json`:

```json
{
  "ProtectUrl": "PASTE_YOUR_FULL_PROTECT_GRID_URL_HERE",
  "SetupUrl": "",
  "AutoLoginEnabled": true,
  "LoginUsername": "YOUR_UNIFI_USERNAME_HERE",
  "LoginPassword": "YOUR_UNIFI_PASSWORD_HERE",
  "TrustThisDevice": true,

  "ChromePath": "",
  "ProfileDirectory": ".\\chrome-profile",
  "Kiosk": true,
  "DebugPort": 9222,
  "FullscreenAfterSeconds": 12,
  "FullscreenAttempts": 3,
  "FullscreenParentSelector": "div[class*='LiveviewControls__ButtonGroup']",
  "FullscreenButtonSelector": ":nth-child(2) > button",
  "FullscreenKeySequence": "f",
  "ClickCenterBeforeFullscreen": true,
  "DoubleClickCenterBeforeFullscreen": false,
  "RestartEveryMinutes": 1440,
  "HealthCheckEnabled": true,
  "MaxHealthFailures": 4,
  "MaxOfflineReloads": 2,
  "MaxUnresponsiveFailures": 3,
  "MaxFullscreenRestoreFailures": 3,
  "DevToolsTimeoutSeconds": 8,
  "HideCursor": true,
  "HideUiElements": true,
  "CleanDisplayEveryMinutes": 5,
  "RestartIfChromeExits": true,
  "CheckEverySeconds": 15,
  "LogFile": ".\\logs\\fakeviewport-win.log"
}
```

`ChromePath` can stay empty. The launcher auto-detects Chrome from the usual Windows install paths.

`ProfileDirectory` is intentionally local to this folder. Chrome stores your UniFi session there, which avoids putting usernames, passwords, or MFA tokens in a script.

`AutoLoginEnabled` defaults to `true`. When fakeviewport-win detects a UniFi login form, it fills `LoginUsername` and `LoginPassword` from `config.json`, submits the form, and optionally clicks "Trust This Device." This stores the password in plain text, so only use it on a secured display machine and do not commit a filled-in `config.json`.

For direct-IP UNVR URLs, put the full local URL in `ProtectUrl`; fakeviewport-win tracks the Chrome process by the dedicated profile and DevTools port so Chrome's launcher handoff does not create duplicate windows.

`Kiosk` controls Chrome's fullscreen shell. `DebugPort` enables local Chrome DevTools control on `127.0.0.1`, which fakeviewport-win uses to click the Live View fullscreen button.

The default selectors target the Protect Live View fullscreen controls:

```text
div[class*='LiveviewControls__ButtonGroup']
:nth-child(2) > button
```

If that selector click fails, fakeviewport-win can still fall back to focusing the view and sending `FullscreenKeySequence`.

`RestartEveryMinutes` defaults to `1440`, so Chrome quits and reconnects once every 24 hours. `HealthCheckEnabled` uses the same local DevTools channel to verify the Live View wrapper is present, detect offline/login/loading states, reload the page, and restart Chrome after repeated failures. `DevToolsTimeoutSeconds` and `MaxUnresponsiveFailures` control the deeper watchdog for a browser that is alive but no longer responding.

`MaxFullscreenRestoreFailures` controls how many times fakeviewport-win tries to put the Live View grid back into fullscreen before restarting Chrome.

`HideCursor` and `HideUiElements` inject a small CSS cleanup layer after fullscreen and refresh it periodically with `CleanDisplayEveryMinutes`.

`setup-fakeviewport-win-profile.cmd` opens a normal Chrome window to `setup-guide.html` and does not run kiosk mode, browser fullscreen, or the Protect fullscreen click. It is only for signing in and configuring the dedicated Chrome profile. Set `SetupUrl` only if you want setup mode to open a different page.

If the view still does not enter camera fullscreen, run `setup-fakeviewport-win-profile.cmd`, navigate to the exact camera or live-view page you want, copy that final URL into `ProtectUrl`, and try again. You can also increase `FullscreenAfterSeconds` if UniFi needs longer to load.

## Commands

Start:

```powershell
.\start-fakeviewport-win.cmd
```

Setup the Chrome profile:

```powershell
.\setup-fakeviewport-win-profile.cmd
```

Install autostart on Windows login:

```batch
.\install-startup-shortcut.cmd
```

This creates a shortcut named `fakeviewport-win.lnk` in the current user's Windows Startup folder:

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
```

That shortcut runs `start-fakeviewport-win.cmd` whenever this Windows user signs in.

Remove autostart:

```batch
.\uninstall-startup-shortcut.cmd
```

This removes the `fakeviewport-win.lnk` shortcut from the Startup folder.

Stop:

Close the PowerShell window, then close Chrome. If you installed the startup shortcut, uninstall it first if you no longer want fakeviewport-win to start at login.

## Notes

Chrome kiosk mode does not expose tabs or normal browser controls. Press `Alt+F4` to close it, or use `Ctrl+Alt+Del` / Task Manager if the display machine does not have a keyboard.

UniFi Protect stream quality is controlled by the Protect web app. Set it once in the dedicated Chrome profile and it should persist for later launches.
