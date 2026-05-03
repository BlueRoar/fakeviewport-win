[CmdletBinding()]
param(
    [string]$ConfigPath = ".\config.json",
    [switch]$Once,
    [switch]$Setup
)

$ErrorActionPreference = "Stop"

function Resolve-PathFromBase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Write-FakeViewportWinLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO",
        [System.Exception]$Exception
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line
    if ($Exception) {
        Add-Content -LiteralPath $script:LogFile -Value $Exception.ToString()
    }
}

function Initialize-InputHelpers {
    if ("FakeViewportWinInput" -as [type]) {
        return
    }

    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class FakeViewportWinInput {
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);
}
"@
}

function Invoke-MouseClick {
    param(
        [Parameter(Mandatory = $true)]
        [double]$XPercent,
        [Parameter(Mandatory = $true)]
        [double]$YPercent,
        [int]$Count = 1
    )

    Initialize-InputHelpers

    $screenWidth = [FakeViewportWinInput]::GetSystemMetrics(0)
    $screenHeight = [FakeViewportWinInput]::GetSystemMetrics(1)
    $x = [Math]::Max(0, [Math]::Min($screenWidth - 1, [int]($screenWidth * $XPercent)))
    $y = [Math]::Max(0, [Math]::Min($screenHeight - 1, [int]($screenHeight * $YPercent)))

    [FakeViewportWinInput]::SetCursorPos($x, $y) | Out-Null
    for ($i = 0; $i -lt $Count; $i++) {
        [FakeViewportWinInput]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 80
        [FakeViewportWinInput]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 140
    }
}

function Invoke-CdpCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebSocketUrl,
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutSeconds = 10
    )

    $client = [System.Net.WebSockets.ClientWebSocket]::new()
    $uri = [Uri]$WebSocketUrl
    $bufferSize = 65536
    $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))

    try {
        $client.ConnectAsync($uri, $cts.Token).GetAwaiter().GetResult()

        $message = @{
            id = 1
            method = $Method
            params = $Params
        } | ConvertTo-Json -Depth 20 -Compress

        $bytes = [Text.Encoding]::UTF8.GetBytes($message)
        $segment = [ArraySegment[byte]]::new($bytes)
        $client.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()

        while ($true) {
            $received = New-Object System.Collections.Generic.List[byte]
            do {
                $buffer = [byte[]]::new($bufferSize)
                $receiveSegment = [ArraySegment[byte]]::new($buffer)
                $result = $client.ReceiveAsync($receiveSegment, $cts.Token).GetAwaiter().GetResult()
                if ($result.Count -gt 0) {
                    $chunk = [byte[]]::new($result.Count)
                    [Array]::Copy($buffer, 0, $chunk, 0, $result.Count)
                    $received.AddRange($chunk)
                }
            } while (-not $result.EndOfMessage)

            $json = [Text.Encoding]::UTF8.GetString($received.ToArray())
            $response = $json | ConvertFrom-Json
            if ($response.id -eq 1) {
                return $response
            }
        }
    } finally {
        if ($client.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $client.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        }
        $cts.Dispose()
        $client.Dispose()
    }
}

function Get-ChromeDebugPage {
    param(
        [Parameter(Mandatory = $true)]
        [int]$DebugPort,
        [Parameter(Mandatory = $true)]
        [string]$ProtectUrl,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $endpoint = "http://127.0.0.1:$DebugPort/json"
    $protectHost = ""
    try {
        $protectHost = ([Uri]$ProtectUrl).Host
    } catch {
        $protectHost = ""
    }

    while ((Get-Date) -lt $deadline) {
        try {
            $pages = Invoke-RestMethod -Uri $endpoint -UseBasicParsing -TimeoutSec 2
            $page = @($pages) | Where-Object {
                $matchesProtectHost = $false
                if ($protectHost -and $_.url) {
                    try {
                        $matchesProtectHost = ([Uri]$_.url).Host -eq $protectHost
                    } catch {
                        $matchesProtectHost = $false
                    }
                }

                $_.type -eq "page" -and
                $_.webSocketDebuggerUrl -and
                ($_.url -eq $ProtectUrl -or $_.url -like "*unifi.ui.com*" -or $matchesProtectHost)
            } | Select-Object -First 1

            if (-not $page) {
                $page = @($pages) | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl } | Select-Object -First 1
            }

            if ($page) {
                return $page
            }
        } catch {
            Start-Sleep -Milliseconds 500
        }

        Start-Sleep -Milliseconds 500
    }

    return $null
}

function Invoke-LiveViewFullscreenButton {
    param(
        [Parameter(Mandatory = $true)]
        [int]$DebugPort,
        [Parameter(Mandatory = $true)]
        [string]$ProtectUrl,
        [Parameter(Mandatory = $true)]
        [string]$ParentSelector,
        [Parameter(Mandatory = $true)]
        [string]$ButtonSelector
    )

    $page = Get-ChromeDebugPage -DebugPort $DebugPort -ProtectUrl $ProtectUrl
    if (-not $page) {
        Write-FakeViewportWinLog "Could not find Chrome DevTools page."
        return $false
    }

    $script = @"
(function() {
  const parentSelector = '$($ParentSelector.Replace("\", "\\").Replace("'", "\'"))';
  const buttonSelector = '$($ButtonSelector.Replace("\", "\\").Replace("'", "\'"))';
  const cleanStyle = document.getElementById('fakeviewport-win-clean-display');
  if (cleanStyle) {
    cleanStyle.remove();
  }
  const parent = document.querySelector(parentSelector);
  if (!parent) {
    return { ok: false, reason: 'fullscreen parent not found', title: document.title, url: location.href };
  }
  parent.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window }));
  parent.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, cancelable: true, view: window }));
  const button = parent.querySelector(buttonSelector) || parent.querySelector(':scope > ' + buttonSelector);
  if (!button) {
    return { ok: false, reason: 'fullscreen button not found', title: document.title, url: location.href };
  }
  const rect = button.getBoundingClientRect();
  return {
    ok: true,
    x: rect.left + rect.width / 2,
    y: rect.top + rect.height / 2,
    title: document.title,
    url: location.href
  };
})()
"@

    $evaluation = Invoke-CdpCommand -WebSocketUrl $page.webSocketDebuggerUrl -Method "Runtime.evaluate" -Params @{
        expression = $script
        returnByValue = $true
        awaitPromise = $true
    }

    $value = $evaluation.result.result.value
    if (-not $value -or -not $value.ok) {
        $reason = if ($value) { $value.reason } else { "no result from Runtime.evaluate" }
        Write-FakeViewportWinLog "Protect fullscreen button lookup failed: $reason"
        return $false
    }

    Invoke-CdpCommand -WebSocketUrl $page.webSocketDebuggerUrl -Method "Input.dispatchMouseEvent" -Params @{
        type = "mouseMoved"
        x = [double]$value.x
        y = [double]$value.y
    } | Out-Null
    Start-Sleep -Milliseconds 200
    Invoke-CdpCommand -WebSocketUrl $page.webSocketDebuggerUrl -Method "Input.dispatchMouseEvent" -Params @{
        type = "mousePressed"
        x = [double]$value.x
        y = [double]$value.y
        button = "left"
        buttons = 1
        clickCount = 1
    } | Out-Null
    Start-Sleep -Milliseconds 100
    Invoke-CdpCommand -WebSocketUrl $page.webSocketDebuggerUrl -Method "Input.dispatchMouseEvent" -Params @{
        type = "mouseReleased"
        x = [double]$value.x
        y = [double]$value.y
        button = "left"
        buttons = 0
        clickCount = 1
    } | Out-Null

    Write-FakeViewportWinLog "Clicked Protect Live View fullscreen button."
    return $true
}

function Get-ProtectHealth {
    param(
        [Parameter(Mandatory = $true)]
        [int]$DebugPort,
        [Parameter(Mandatory = $true)]
        [string]$ProtectUrl
    )

    $page = Get-ChromeDebugPage -DebugPort $DebugPort -ProtectUrl $ProtectUrl -TimeoutSeconds 3
    if (-not $page) {
        return [PSCustomObject]@{
            ok = $false
            reason = "Chrome DevTools page not found"
        }
    }

    $script = @"
(function() {
  const text = document.body ? document.body.innerText : '';
  const offline = /Console Offline|Protect Offline/i.test(text);
  const title = document.title || '';
  const host = location.hostname || '';
  const path = location.pathname || '';
  const hasPasswordField = !!document.querySelector('input[type="password"], input[name="password"]');
  const hasUsernameField = !!document.querySelector('input[name^="user"], input[type="email"]');
  const hasSubmitLogin = !!Array.from(document.querySelectorAll('button[type="submit"], button')).find(button => /sign in|log in|login/i.test(button.innerText || ''));
  const onLoginHost = /(^|\.)account\.ui\.com$/i.test(host);
  const onLoginPath = /\/login|\/signin|\/sign-in/i.test(path);
  const loginExpired = onLoginHost || onLoginPath || /Ubiquiti Account/i.test(title) || ((hasPasswordField || hasUsernameField) && hasSubmitLogin);
  const noDevices = /Get started|Adopt Devices/i.test(text);
  const loading = !!document.querySelector("div[class*='TimedDotsLoader']");
  const wrapper = !!document.querySelector("div[class*='liveview__ViewportsWrapper']");
  const fullscreen = !!document.fullscreenElement;
  return {
    ok: document.readyState === 'complete' && wrapper && fullscreen && !offline && !noDevices && !loginExpired,
    reason: offline ? 'Protect or console offline' :
            loginExpired ? 'Login expired or sign-in page visible' :
            noDevices ? 'No cameras available' :
            loading ? 'Loading indicator visible' :
            !wrapper ? 'Live View wrapper not found' :
            !fullscreen ? 'Live View is not fullscreen' :
            document.readyState !== 'complete' ? 'Page still loading' :
            'Healthy',
    status: offline ? 'offline' :
            loginExpired ? 'login-expired' :
            noDevices ? 'no-devices' :
            loading ? 'loading' :
            !wrapper ? 'missing-wrapper' :
            !fullscreen ? 'not-fullscreen' :
            document.readyState !== 'complete' ? 'loading' :
            'healthy',
    title: document.title,
    host: host,
    path: path,
    url: location.href,
    loading: loading,
    wrapper: wrapper,
    fullscreen: fullscreen
  };
})()
"@

    try {
        $evaluation = Invoke-CdpCommand -WebSocketUrl $page.webSocketDebuggerUrl -Method "Runtime.evaluate" -Params @{
            expression = $script
            returnByValue = $true
            awaitPromise = $true
        }

        return $evaluation.result.result.value
    } catch {
        return [PSCustomObject]@{
            ok = $false
            reason = "Health check failed: $($_.Exception.Message)"
        }
    }
}

function Invoke-ProtectReload {
    param(
        [Parameter(Mandatory = $true)]
        [int]$DebugPort,
        [Parameter(Mandatory = $true)]
        [string]$ProtectUrl
    )

    $page = Get-ChromeDebugPage -DebugPort $DebugPort -ProtectUrl $ProtectUrl -TimeoutSeconds 5
    if (-not $page) {
        Write-FakeViewportWinLog "Could not find Chrome DevTools page for reload." -Level "WARNING"
        return $false
    }

    try {
        Invoke-CdpCommand -WebSocketUrl $page.webSocketDebuggerUrl -Method "Page.reload" -Params @{
            ignoreCache = $true
        } -TimeoutSeconds $script:DevToolsTimeoutSeconds | Out-Null
        Write-FakeViewportWinLog "Reloaded Protect page through Chrome DevTools."
        return $true
    } catch {
        Write-FakeViewportWinLog "Protect page reload failed: $($_.Exception.Message)" -Level "WARNING" -Exception $_.Exception
        return $false
    }
}

function Invoke-ProtectLogin {
    param(
        [Parameter(Mandatory = $true)]
        [int]$DebugPort,
        [Parameter(Mandatory = $true)]
        [string]$ProtectUrl,
        [string]$Username,
        [string]$Password,
        [bool]$TrustDevice = $true
    )

    if (-not $Username -or -not $Password) {
        Write-FakeViewportWinLog "Login page detected, but LoginUsername/LoginPassword are not configured." -Level "WARNING"
        return $false
    }

    $page = Get-ChromeDebugPage -DebugPort $DebugPort -ProtectUrl $ProtectUrl -TimeoutSeconds 5
    if (-not $page) {
        Write-FakeViewportWinLog "Could not find Chrome DevTools page for login." -Level "WARNING"
        return $false
    }

    $escapedUsername = $Username.Replace("\", "\\").Replace("'", "\'")
    $escapedPassword = $Password.Replace("\", "\\").Replace("'", "\'")
    $trust = if ($TrustDevice) { "true" } else { "false" }
    $script = @"
(async function() {
  const username = '$escapedUsername';
  const password = '$escapedPassword';
  const trustDevice = $trust;
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const setValue = (input, value) => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  };

  const userField = document.querySelector('input[name^="user"], input[type="email"], input[autocomplete="username"]');
  const passwordField = document.querySelector('input[type="password"], input[name="password"], input[autocomplete="current-password"]');
  if (!userField || !passwordField) {
    return { ok: false, reason: 'login fields not found', title: document.title, url: location.href };
  }

  userField.focus();
  setValue(userField, username);
  await sleep(250);
  passwordField.focus();
  setValue(passwordField, password);
  await sleep(250);

  const buttons = Array.from(document.querySelectorAll('button[type="submit"], button'));
  const submit = buttons.find(button => /sign in|log in|login/i.test(button.innerText || '')) || document.querySelector('button[type="submit"]');
  if (!submit) {
    return { ok: false, reason: 'login submit button not found', title: document.title, url: location.href };
  }
  submit.click();

  if (trustDevice) {
    await sleep(5000);
    const trustButton = Array.from(document.querySelectorAll('button, span')).find(el => /trust this device/i.test(el.innerText || ''));
    if (trustButton) {
      const button = trustButton.closest('button') || trustButton;
      button.click();
    }
  }

  return { ok: true, reason: 'submitted login form', title: document.title, url: location.href };
})()
"@

    try {
        $evaluation = Invoke-CdpCommand -WebSocketUrl $page.webSocketDebuggerUrl -Method "Runtime.evaluate" -Params @{
            expression = $script
            returnByValue = $true
            awaitPromise = $true
        } -TimeoutSeconds ([Math]::Max($script:DevToolsTimeoutSeconds, 15))

        $value = $evaluation.result.result.value
        if ($value -and $value.ok) {
            Write-FakeViewportWinLog "Submitted UniFi login form."
            return $true
        }

        $reason = if ($value) { $value.reason } else { "no result from Runtime.evaluate" }
        Write-FakeViewportWinLog "UniFi login automation failed: $reason" -Level "WARNING"
        return $false
    } catch {
        Write-FakeViewportWinLog "UniFi login automation failed: $($_.Exception.Message)" -Level "WARNING" -Exception $_.Exception
        return $false
    }
}

function Invoke-CleanDisplayInjection {
    param(
        [Parameter(Mandatory = $true)]
        [int]$DebugPort,
        [Parameter(Mandatory = $true)]
        [string]$ProtectUrl,
        [bool]$HideCursor = $true,
        [bool]$HideUiElements = $true
    )

    if (-not $HideCursor -and -not $HideUiElements) {
        return $true
    }

    $page = Get-ChromeDebugPage -DebugPort $DebugPort -ProtectUrl $ProtectUrl -TimeoutSeconds 5
    if (-not $page) {
        Write-FakeViewportWinLog "Could not find Chrome DevTools page for clean display injection." -Level "WARNING"
        return $false
    }

    $cursorRule = if ($HideCursor) { "html, body, body * { cursor: none !important; }" } else { "" }
    $uiRule = if ($HideUiElements) {
@"
[class*='LiveviewControls'],
[class*='LiveViewControls'],
[class*='PlayerControls'],
[class*='liveviewControls'],
[class*='playbackControls'],
[class*='Controls__ButtonGroup'] {
  opacity: 0 !important;
  pointer-events: none !important;
  transition: none !important;
}
"@
    } else { "" }

    $css = ($cursorRule + "`n" + $uiRule).Replace("\", "\\").Replace("`r", "").Replace("`n", "\n").Replace("'", "\'")
    $script = @"
(function() {
  const id = 'fakeviewport-win-clean-display';
  let style = document.getElementById(id);
  if (!style) {
    style = document.createElement('style');
    style.id = id;
    document.documentElement.appendChild(style);
  }
  style.textContent = '$css';
  return { ok: true };
})()
"@

    try {
        Invoke-CdpCommand -WebSocketUrl $page.webSocketDebuggerUrl -Method "Runtime.evaluate" -Params @{
            expression = $script
            returnByValue = $true
            awaitPromise = $true
        } -TimeoutSeconds $script:DevToolsTimeoutSeconds | Out-Null
        Write-FakeViewportWinLog "Injected clean display CSS."
        return $true
    } catch {
        Write-FakeViewportWinLog "Clean display injection failed: $($_.Exception.Message)" -Level "WARNING" -Exception $_.Exception
        return $false
    }
}

function Invoke-ProtectFullscreen {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$ChromeProcess,
        [Parameter(Mandatory = $true)]
        [int]$DebugPort,
        [Parameter(Mandatory = $true)]
        [string]$ProtectUrl,
        [Parameter(Mandatory = $true)]
        [string]$FullscreenParentSelector,
        [Parameter(Mandatory = $true)]
        [string]$FullscreenButtonSelector,
        [int]$DelaySeconds = 12,
        [int]$Attempts = 3,
        [string]$KeySequence = "f",
        [bool]$ClickCenterFirst = $true,
        [bool]$DoubleClickCenterFirst = $true
    )

    if ($Attempts -le 0) {
        return
    }

    Write-FakeViewportWinLog "Waiting $DelaySeconds seconds before Protect fullscreen attempt."
    Start-Sleep -Seconds $DelaySeconds

    $shell = New-Object -ComObject WScript.Shell

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if ($ChromeProcess.HasExited) {
            Write-FakeViewportWinLog "Chrome exited before fullscreen attempt."
            return
        }

        Write-FakeViewportWinLog "Running Protect fullscreen attempt $attempt of $Attempts."
        $activated = $shell.AppActivate($ChromeProcess.Id)
        if (-not $activated) {
            $activated = $shell.AppActivate("UniFi")
        }
        Start-Sleep -Milliseconds 700

        $clickedButton = Invoke-LiveViewFullscreenButton -DebugPort $DebugPort -ProtectUrl $ProtectUrl -ParentSelector $FullscreenParentSelector -ButtonSelector $FullscreenButtonSelector
        if ($clickedButton) {
            Start-Sleep -Seconds 3
            return
        }

        if ($KeySequence) {
            if ($ClickCenterFirst) {
                Invoke-MouseClick -XPercent 0.50 -YPercent 0.50 -Count 1
                Start-Sleep -Milliseconds 300
            }

            if ($DoubleClickCenterFirst) {
                Invoke-MouseClick -XPercent 0.50 -YPercent 0.50 -Count 2
                Start-Sleep -Milliseconds 500
            }

            $shell.SendKeys($KeySequence)
        }

        Start-Sleep -Seconds 3
    }
}

function Find-Chrome {
    param([string]$ConfiguredPath)

    if ($ConfiguredPath -and (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $ConfiguredPath).Path
    }

    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    $fromPath = Get-Command "chrome.exe" -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    throw "Google Chrome was not found. Install Chrome or set ChromePath in config.json."
}

function Get-FakeViewportWinChromeProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileDirectory,
        [Parameter(Mandatory = $true)]
        [int]$DebugPort
    )

    $matches = Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue | Where-Object {
        ($_.CommandLine -and $_.CommandLine.Contains($ProfileDirectory)) -or
        ($DebugPort -gt 0 -and $_.CommandLine -and $_.CommandLine.Contains("--remote-debugging-port=$DebugPort"))
    } | Sort-Object CreationDate -Descending

    foreach ($match in $matches) {
        $process = Get-Process -Id $match.ProcessId -ErrorAction SilentlyContinue
        if ($process) {
            return $process
        }
    }

    return $null
}

function Start-FakeViewportWinChrome {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChromePath,
        [Parameter(Mandatory = $true)]
        [string]$ProfileDirectory,
        [Parameter(Mandatory = $true)]
        [string]$ProtectUrl,
        [Parameter(Mandatory = $true)]
        [bool]$Kiosk,
        [Parameter(Mandatory = $true)]
        [int]$DebugPort,
        [bool]$SetupMode = $false
    )

    $arguments = @(
        "--new-window",
        "--no-first-run",
        "--disable-features=Translate",
        "--disable-infobars",
        "--autoplay-policy=no-user-gesture-required"
    )

    if ($SetupMode) {
        $arguments += @(
            "--window-size=1280,900"
        )
    } else {
        $modeFlag = if ($Kiosk) { "--kiosk" } else { "--start-fullscreen" }
        $arguments += $modeFlag
    }

    $arguments += @(
        "--remote-debugging-address=127.0.0.1",
        "--remote-debugging-port=$DebugPort",
        "--user-data-dir=$ProfileDirectory",
        $ProtectUrl
    )

    Write-FakeViewportWinLog "Starting Chrome at $ProtectUrl"
    $launchedProcess = Start-Process -FilePath $ChromePath -ArgumentList $arguments -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2

    $trackedProcess = Get-FakeViewportWinChromeProcess -ProfileDirectory $ProfileDirectory -DebugPort $DebugPort
    if ($trackedProcess) {
        Write-FakeViewportWinLog "Tracking Chrome process $($trackedProcess.Id)."
        return $trackedProcess
    }

    Write-FakeViewportWinLog "Could not find Chrome by profile/debug port; tracking launcher process $($launchedProcess.Id)." -Level "WARNING"
    return $launchedProcess
}

function Stop-FakeViewportWinChrome {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$ChromeProcess,
        [string]$ProfileDirectory,
        [int]$DebugPort = 0
    )

    Write-FakeViewportWinLog "Stopping Chrome."
    Stop-Process -Id $ChromeProcess.Id -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    if (-not $ChromeProcess.HasExited) {
        Stop-Process -Id $ChromeProcess.Id -Force -ErrorAction SilentlyContinue
    }

    $matches = Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue | Where-Object {
        ($_.CommandLine -and $_.CommandLine.Contains($ProfileDirectory)) -or
        ($DebugPort -gt 0 -and $_.CommandLine -and $_.CommandLine.Contains("--remote-debugging-port=$DebugPort"))
    }

    foreach ($process in $matches) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$resolvedConfigPath = Resolve-PathFromBase -PathValue $ConfigPath -BasePath $scriptRoot

if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
    throw "Config file not found: $resolvedConfigPath"
}

$configBase = Split-Path -Parent $resolvedConfigPath
$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json

$protectUrl = [string]$config.ProtectUrl
if (-not $protectUrl) {
    throw "ProtectUrl is required in config.json."
}

if ($Setup) {
    $defaultSetupGuide = (Join-Path $scriptRoot "setup-guide.html")
    $setupUrl = if ($config.SetupUrl) {
        [string]$config.SetupUrl
    } elseif (Test-Path -LiteralPath $defaultSetupGuide -PathType Leaf) {
        (New-Object System.Uri($defaultSetupGuide)).AbsoluteUri
    } else {
        "https://unifi.ui.com/"
    }
    $protectUrl = $setupUrl
}

$chromePath = Find-Chrome -ConfiguredPath ([string]$config.ChromePath)
$profileDirectory = Resolve-PathFromBase -PathValue ([string]$config.ProfileDirectory) -BasePath $configBase
$script:LogFile = Resolve-PathFromBase -PathValue ([string]$config.LogFile) -BasePath $configBase
$kiosk = if ($Setup) { $false } elseif ($null -eq $config.Kiosk) { $true } else { [bool]$config.Kiosk }
$restartIfChromeExits = if ($null -eq $config.RestartIfChromeExits) { $true } else { [bool]$config.RestartIfChromeExits }
$checkEverySeconds = if ($config.CheckEverySeconds) { [int]$config.CheckEverySeconds } else { 15 }
$restartEveryMinutes = if ($config.RestartEveryMinutes) { [int]$config.RestartEveryMinutes } elseif ($config.ReloadEveryMinutes) { [int]$config.ReloadEveryMinutes } else { 1440 }
$debugPort = if ($config.DebugPort) { [int]$config.DebugPort } else { 9222 }
$fullscreenAfterSeconds = if ($config.FullscreenAfterSeconds) { [int]$config.FullscreenAfterSeconds } else { 12 }
$fullscreenAttempts = if ($config.FullscreenAttempts) { [int]$config.FullscreenAttempts } else { 3 }
$fullscreenKeySequence = if ($null -ne $config.FullscreenKeySequence) { [string]$config.FullscreenKeySequence } else { "f" }
$clickCenterBeforeFullscreen = if ($null -eq $config.ClickCenterBeforeFullscreen) { $true } else { [bool]$config.ClickCenterBeforeFullscreen }
$doubleClickCenterBeforeFullscreen = if ($null -eq $config.DoubleClickCenterBeforeFullscreen) { $false } else { [bool]$config.DoubleClickCenterBeforeFullscreen }
$fullscreenParentSelector = if ($config.FullscreenParentSelector) { [string]$config.FullscreenParentSelector } else { "div[class*='LiveviewControls__ButtonGroup']" }
$fullscreenButtonSelector = if ($config.FullscreenButtonSelector) { [string]$config.FullscreenButtonSelector } else { ":nth-child(2) > button" }
$healthCheckEnabled = if ($null -eq $config.HealthCheckEnabled) { $true } else { [bool]$config.HealthCheckEnabled }
$maxHealthFailures = if ($config.MaxHealthFailures) { [int]$config.MaxHealthFailures } else { 4 }
$maxOfflineReloads = if ($config.MaxOfflineReloads) { [int]$config.MaxOfflineReloads } else { 2 }
$maxUnresponsiveFailures = if ($config.MaxUnresponsiveFailures) { [int]$config.MaxUnresponsiveFailures } else { 3 }
$maxFullscreenRestoreFailures = if ($config.MaxFullscreenRestoreFailures) { [int]$config.MaxFullscreenRestoreFailures } else { 3 }
$script:DevToolsTimeoutSeconds = if ($config.DevToolsTimeoutSeconds) { [int]$config.DevToolsTimeoutSeconds } else { 8 }
$hideCursor = if ($null -eq $config.HideCursor) { $true } else { [bool]$config.HideCursor }
$hideUiElements = if ($null -eq $config.HideUiElements) { $true } else { [bool]$config.HideUiElements }
$cleanDisplayEveryMinutes = if ($config.CleanDisplayEveryMinutes) { [int]$config.CleanDisplayEveryMinutes } else { 5 }
$autoLoginEnabled = if ($null -eq $config.AutoLoginEnabled) { $true } else { [bool]$config.AutoLoginEnabled }
$loginUsername = if ($config.LoginUsername) { [string]$config.LoginUsername } else { "" }
$loginPassword = if ($config.LoginPassword) { [string]$config.LoginPassword } else { "" }
$trustThisDevice = if ($null -eq $config.TrustThisDevice) { $true } else { [bool]$config.TrustThisDevice }

New-Item -ItemType Directory -Force -Path $profileDirectory | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:LogFile) | Out-Null

Write-FakeViewportWinLog "fakeviewport-win starting."
Write-FakeViewportWinLog "Chrome: $chromePath"
Write-FakeViewportWinLog "Profile: $profileDirectory"

$chrome = Start-FakeViewportWinChrome -ChromePath $chromePath -ProfileDirectory $profileDirectory -ProtectUrl $protectUrl -Kiosk $kiosk -DebugPort $debugPort -SetupMode:$Setup
$lastRestart = Get-Date
$healthFailures = 0
$offlineReloads = 0
$unresponsiveFailures = 0
$fullscreenRestoreFailures = 0
$lastCleanDisplay = (Get-Date).AddMinutes(-1 * $cleanDisplayEveryMinutes)

if ($Once -or $Setup) {
    Write-FakeViewportWinLog "Started once; exiting watchdog."
    exit 0
}

Invoke-ProtectFullscreen -ChromeProcess $chrome -DebugPort $debugPort -ProtectUrl $protectUrl -FullscreenParentSelector $fullscreenParentSelector -FullscreenButtonSelector $fullscreenButtonSelector -DelaySeconds $fullscreenAfterSeconds -Attempts $fullscreenAttempts -KeySequence $fullscreenKeySequence -ClickCenterFirst $clickCenterBeforeFullscreen -DoubleClickCenterFirst $doubleClickCenterBeforeFullscreen
Invoke-CleanDisplayInjection -DebugPort $debugPort -ProtectUrl $protectUrl -HideCursor $hideCursor -HideUiElements $hideUiElements | Out-Null
$lastCleanDisplay = Get-Date

while ($true) {
    Start-Sleep -Seconds $checkEverySeconds
    try {

    if ($chrome.HasExited) {
        $trackedChrome = Get-FakeViewportWinChromeProcess -ProfileDirectory $profileDirectory -DebugPort $debugPort
        if ($trackedChrome) {
            Write-FakeViewportWinLog "Launcher process exited, but Chrome is still running as process $($trackedChrome.Id); continuing without opening a duplicate window."
            $chrome = $trackedChrome
        }
    }

    if ($chrome.HasExited) {
        Write-FakeViewportWinLog "Chrome exited with code $($chrome.ExitCode)."
        if (-not $restartIfChromeExits) {
            Write-FakeViewportWinLog "RestartIfChromeExits is false; exiting."
            exit $chrome.ExitCode
        }

        $chrome = Start-FakeViewportWinChrome -ChromePath $chromePath -ProfileDirectory $profileDirectory -ProtectUrl $protectUrl -Kiosk $kiosk -DebugPort $debugPort
        $lastRestart = Get-Date
        $healthFailures = 0
        $offlineReloads = 0
        $unresponsiveFailures = 0
        $fullscreenRestoreFailures = 0
        Invoke-ProtectFullscreen -ChromeProcess $chrome -DebugPort $debugPort -ProtectUrl $protectUrl -FullscreenParentSelector $fullscreenParentSelector -FullscreenButtonSelector $fullscreenButtonSelector -DelaySeconds $fullscreenAfterSeconds -Attempts $fullscreenAttempts -KeySequence $fullscreenKeySequence -ClickCenterFirst $clickCenterBeforeFullscreen -DoubleClickCenterFirst $doubleClickCenterBeforeFullscreen
        Invoke-CleanDisplayInjection -DebugPort $debugPort -ProtectUrl $protectUrl -HideCursor $hideCursor -HideUiElements $hideUiElements | Out-Null
        $lastCleanDisplay = Get-Date
        continue
    }

    if ($healthCheckEnabled) {
        $health = Get-ProtectHealth -DebugPort $debugPort -ProtectUrl $protectUrl
        if ($health.ok) {
            if ($healthFailures -gt 0) {
                Write-FakeViewportWinLog "Protect health recovered."
            }
            $healthFailures = 0
            $offlineReloads = 0
            $unresponsiveFailures = 0
            $fullscreenRestoreFailures = 0

            if ($cleanDisplayEveryMinutes -gt 0 -and ((Get-Date) - $lastCleanDisplay).TotalMinutes -ge $cleanDisplayEveryMinutes) {
                Invoke-CleanDisplayInjection -DebugPort $debugPort -ProtectUrl $protectUrl -HideCursor $hideCursor -HideUiElements $hideUiElements | Out-Null
                $lastCleanDisplay = Get-Date
            }
        } else {
            $healthFailures += 1
            Write-FakeViewportWinLog "Protect health check failed ($healthFailures/$maxHealthFailures): $($health.reason) [title='$($health.title)' host='$($health.host)' path='$($health.path)']"

            if ($health.reason -like "*DevTools page not found*" -or $health.reason -like "*Health check failed*") {
                $unresponsiveFailures += 1
                Write-FakeViewportWinLog "Chrome/DevTools unresponsive failure ($unresponsiveFailures/$maxUnresponsiveFailures)." -Level "WARNING"
            }

            if ($health.status -eq "not-fullscreen") {
                $fullscreenRestoreFailures += 1
                Write-FakeViewportWinLog "Live View is not fullscreen; attempting restore ($fullscreenRestoreFailures/$maxFullscreenRestoreFailures)." -Level "WARNING"
                Invoke-ProtectFullscreen -ChromeProcess $chrome -DebugPort $debugPort -ProtectUrl $protectUrl -FullscreenParentSelector $fullscreenParentSelector -FullscreenButtonSelector $fullscreenButtonSelector -DelaySeconds 1 -Attempts $fullscreenAttempts -KeySequence $fullscreenKeySequence -ClickCenterFirst $clickCenterBeforeFullscreen -DoubleClickCenterFirst $doubleClickCenterBeforeFullscreen
                Invoke-CleanDisplayInjection -DebugPort $debugPort -ProtectUrl $protectUrl -HideCursor $hideCursor -HideUiElements $hideUiElements | Out-Null
                $lastCleanDisplay = Get-Date

                $restoreHealth = Get-ProtectHealth -DebugPort $debugPort -ProtectUrl $protectUrl
                if ($restoreHealth.ok) {
                    Write-FakeViewportWinLog "Live View fullscreen restored."
                    $healthFailures = 0
                    $fullscreenRestoreFailures = 0
                    continue
                }

                if ($fullscreenRestoreFailures -ge $maxFullscreenRestoreFailures) {
                    Write-FakeViewportWinLog "Fullscreen restore limit reached; restarting Chrome." -Level "ERROR"
                    Stop-FakeViewportWinChrome -ChromeProcess $chrome -ProfileDirectory $profileDirectory -DebugPort $debugPort
                    Start-Sleep -Seconds 2
                    $chrome = Start-FakeViewportWinChrome -ChromePath $chromePath -ProfileDirectory $profileDirectory -ProtectUrl $protectUrl -Kiosk $kiosk -DebugPort $debugPort
                    $lastRestart = Get-Date
                    $healthFailures = 0
                    $offlineReloads = 0
                    $unresponsiveFailures = 0
                    $fullscreenRestoreFailures = 0
                    Invoke-ProtectFullscreen -ChromeProcess $chrome -DebugPort $debugPort -ProtectUrl $protectUrl -FullscreenParentSelector $fullscreenParentSelector -FullscreenButtonSelector $fullscreenButtonSelector -DelaySeconds $fullscreenAfterSeconds -Attempts $fullscreenAttempts -KeySequence $fullscreenKeySequence -ClickCenterFirst $clickCenterBeforeFullscreen -DoubleClickCenterFirst $doubleClickCenterBeforeFullscreen
                    Invoke-CleanDisplayInjection -DebugPort $debugPort -ProtectUrl $protectUrl -HideCursor $hideCursor -HideUiElements $hideUiElements | Out-Null
                    $lastCleanDisplay = Get-Date
                    continue
                }

                continue
            }

            if ($health.status -eq "login-expired" -and $autoLoginEnabled) {
                Write-FakeViewportWinLog "Login page detected; attempting configured UniFi login." -Level "WARNING"
                if (Invoke-ProtectLogin -DebugPort $debugPort -ProtectUrl $protectUrl -Username $loginUsername -Password $loginPassword -TrustDevice $trustThisDevice) {
                    Start-Sleep -Seconds $fullscreenAfterSeconds
                    Invoke-ProtectFullscreen -ChromeProcess $chrome -DebugPort $debugPort -ProtectUrl $protectUrl -FullscreenParentSelector $fullscreenParentSelector -FullscreenButtonSelector $fullscreenButtonSelector -DelaySeconds 1 -Attempts $fullscreenAttempts -KeySequence $fullscreenKeySequence -ClickCenterFirst $clickCenterBeforeFullscreen -DoubleClickCenterFirst $doubleClickCenterBeforeFullscreen
                    Invoke-CleanDisplayInjection -DebugPort $debugPort -ProtectUrl $protectUrl -HideCursor $hideCursor -HideUiElements $hideUiElements | Out-Null
                    $lastCleanDisplay = Get-Date
                    $healthFailures = 0
                    continue
                }
            }

            if ($health.status -in @("offline", "login-expired", "loading", "missing-wrapper") -and $offlineReloads -lt $maxOfflineReloads) {
                $offlineReloads += 1
                Write-FakeViewportWinLog "Reloading Protect page for status '$($health.status)' ($offlineReloads/$maxOfflineReloads)." -Level "WARNING"
                if (Invoke-ProtectReload -DebugPort $debugPort -ProtectUrl $protectUrl) {
                    Start-Sleep -Seconds $fullscreenAfterSeconds
                    Invoke-ProtectFullscreen -ChromeProcess $chrome -DebugPort $debugPort -ProtectUrl $protectUrl -FullscreenParentSelector $fullscreenParentSelector -FullscreenButtonSelector $fullscreenButtonSelector -DelaySeconds 1 -Attempts $fullscreenAttempts -KeySequence $fullscreenKeySequence -ClickCenterFirst $clickCenterBeforeFullscreen -DoubleClickCenterFirst $doubleClickCenterBeforeFullscreen
                    Invoke-CleanDisplayInjection -DebugPort $debugPort -ProtectUrl $protectUrl -HideCursor $hideCursor -HideUiElements $hideUiElements | Out-Null
                    $lastCleanDisplay = Get-Date
                    continue
                }
            }
        }

        if ($unresponsiveFailures -ge $maxUnresponsiveFailures) {
            Write-FakeViewportWinLog "Chrome/DevTools unresponsive limit reached; restarting Chrome." -Level "ERROR"
            Stop-FakeViewportWinChrome -ChromeProcess $chrome -ProfileDirectory $profileDirectory -DebugPort $debugPort
            Start-Sleep -Seconds 2
            $chrome = Start-FakeViewportWinChrome -ChromePath $chromePath -ProfileDirectory $profileDirectory -ProtectUrl $protectUrl -Kiosk $kiosk -DebugPort $debugPort
            $lastRestart = Get-Date
            $healthFailures = 0
            $offlineReloads = 0
            $unresponsiveFailures = 0
            $fullscreenRestoreFailures = 0
            Invoke-ProtectFullscreen -ChromeProcess $chrome -DebugPort $debugPort -ProtectUrl $protectUrl -FullscreenParentSelector $fullscreenParentSelector -FullscreenButtonSelector $fullscreenButtonSelector -DelaySeconds $fullscreenAfterSeconds -Attempts $fullscreenAttempts -KeySequence $fullscreenKeySequence -ClickCenterFirst $clickCenterBeforeFullscreen -DoubleClickCenterFirst $doubleClickCenterBeforeFullscreen
            Invoke-CleanDisplayInjection -DebugPort $debugPort -ProtectUrl $protectUrl -HideCursor $hideCursor -HideUiElements $hideUiElements | Out-Null
            $lastCleanDisplay = Get-Date
            continue
        }

        if ($healthFailures -ge $maxHealthFailures) {
            Write-FakeViewportWinLog "Health failure limit reached; restarting Chrome."
            Stop-FakeViewportWinChrome -ChromeProcess $chrome -ProfileDirectory $profileDirectory -DebugPort $debugPort
            Start-Sleep -Seconds 2
            $chrome = Start-FakeViewportWinChrome -ChromePath $chromePath -ProfileDirectory $profileDirectory -ProtectUrl $protectUrl -Kiosk $kiosk -DebugPort $debugPort
            $lastRestart = Get-Date
            $healthFailures = 0
            $offlineReloads = 0
            $unresponsiveFailures = 0
            $fullscreenRestoreFailures = 0
            Invoke-ProtectFullscreen -ChromeProcess $chrome -DebugPort $debugPort -ProtectUrl $protectUrl -FullscreenParentSelector $fullscreenParentSelector -FullscreenButtonSelector $fullscreenButtonSelector -DelaySeconds $fullscreenAfterSeconds -Attempts $fullscreenAttempts -KeySequence $fullscreenKeySequence -ClickCenterFirst $clickCenterBeforeFullscreen -DoubleClickCenterFirst $doubleClickCenterBeforeFullscreen
            Invoke-CleanDisplayInjection -DebugPort $debugPort -ProtectUrl $protectUrl -HideCursor $hideCursor -HideUiElements $hideUiElements | Out-Null
            $lastCleanDisplay = Get-Date
            continue
        }
    }

    if ($restartEveryMinutes -gt 0 -and ((Get-Date) - $lastRestart).TotalMinutes -ge $restartEveryMinutes) {
        Write-FakeViewportWinLog "Scheduled restart interval reached; quitting and restarting Chrome."
        Stop-FakeViewportWinChrome -ChromeProcess $chrome -ProfileDirectory $profileDirectory -DebugPort $debugPort
        Start-Sleep -Seconds 2
        $chrome = Start-FakeViewportWinChrome -ChromePath $chromePath -ProfileDirectory $profileDirectory -ProtectUrl $protectUrl -Kiosk $kiosk -DebugPort $debugPort
        $lastRestart = Get-Date
        $healthFailures = 0
        $offlineReloads = 0
        $unresponsiveFailures = 0
        $fullscreenRestoreFailures = 0
        Invoke-ProtectFullscreen -ChromeProcess $chrome -DebugPort $debugPort -ProtectUrl $protectUrl -FullscreenParentSelector $fullscreenParentSelector -FullscreenButtonSelector $fullscreenButtonSelector -DelaySeconds $fullscreenAfterSeconds -Attempts $fullscreenAttempts -KeySequence $fullscreenKeySequence -ClickCenterFirst $clickCenterBeforeFullscreen -DoubleClickCenterFirst $doubleClickCenterBeforeFullscreen
        Invoke-CleanDisplayInjection -DebugPort $debugPort -ProtectUrl $protectUrl -HideCursor $hideCursor -HideUiElements $hideUiElements | Out-Null
        $lastCleanDisplay = Get-Date
    }
    } catch {
        Write-FakeViewportWinLog "Unexpected watchdog loop error: $($_.Exception.Message)" -Level "ERROR" -Exception $_.Exception
        $healthFailures += 1
        if ($healthFailures -ge $maxHealthFailures) {
            Write-FakeViewportWinLog "Restarting Chrome after repeated watchdog errors." -Level "ERROR"
            Stop-FakeViewportWinChrome -ChromeProcess $chrome -ProfileDirectory $profileDirectory -DebugPort $debugPort
            Start-Sleep -Seconds 2
            $chrome = Start-FakeViewportWinChrome -ChromePath $chromePath -ProfileDirectory $profileDirectory -ProtectUrl $protectUrl -Kiosk $kiosk -DebugPort $debugPort
            $lastRestart = Get-Date
            $healthFailures = 0
            $offlineReloads = 0
            $unresponsiveFailures = 0
            $fullscreenRestoreFailures = 0
            Invoke-ProtectFullscreen -ChromeProcess $chrome -DebugPort $debugPort -ProtectUrl $protectUrl -FullscreenParentSelector $fullscreenParentSelector -FullscreenButtonSelector $fullscreenButtonSelector -DelaySeconds $fullscreenAfterSeconds -Attempts $fullscreenAttempts -KeySequence $fullscreenKeySequence -ClickCenterFirst $clickCenterBeforeFullscreen -DoubleClickCenterFirst $doubleClickCenterBeforeFullscreen
            Invoke-CleanDisplayInjection -DebugPort $debugPort -ProtectUrl $protectUrl -HideCursor $hideCursor -HideUiElements $hideUiElements | Out-Null
            $lastCleanDisplay = Get-Date
        }
    }
}
