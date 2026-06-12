const nativeHostName = "com.fpieringer.keyway.chromium";
let nativePort = null;
let reconnectTimer = null;
let heartbeatTimer = null;
let cachedBrowserInfo = null;
const targets = new Map();
const targetStaleAfterMs = 3500;
const recentlyActiveAfterMs = 15000;

function connectNativeHost() {
  if (nativePort) return;

  nativePort = chrome.runtime.connectNative(nativeHostName);
  nativePort.onMessage.addListener(handleNativeMessage);
  nativePort.onDisconnect.addListener(() => {
    nativePort = null;
    stopHeartbeat();
    scheduleReconnect();
  });
  sendNative({ type: "hello", protocolVersion: 1 });
  probeTabsForMedia();
  publishSnapshot();
  startHeartbeat();
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNativeHost();
  }, 1000);
}

function sendNative(message) {
  if (!nativePort) return;
  nativePort.postMessage(message);
}

function startHeartbeat() {
  if (heartbeatTimer) return;
  heartbeatTimer = setInterval(publishSnapshot, 1000);
}

function stopHeartbeat() {
  if (!heartbeatTimer) return;
  clearInterval(heartbeatTimer);
  heartbeatTimer = null;
}

function targetID(message) {
  return [
    "chromium-extension",
    message.browserKey,
    message.windowId,
    message.tabId,
    message.frameId,
    message.mediaId,
  ].join(":");
}

function browserInfo() {
  if (cachedBrowserInfo) return Promise.resolve(cachedBrowserInfo);

  const userAgent = navigator.userAgent || "";
  if (navigator.brave && typeof navigator.brave.isBrave === "function") {
    return navigator.brave.isBrave().then(isBrave => {
      cachedBrowserInfo = runtimeScopedBrowserInfo(
        isBrave ? { key: "brave", name: "Brave" } : browserInfoFromUserAgent(userAgent)
      );
      return cachedBrowserInfo;
    });
  }

  cachedBrowserInfo = runtimeScopedBrowserInfo(browserInfoFromUserAgent(userAgent));
  return Promise.resolve(cachedBrowserInfo);
}

function runtimeScopedBrowserInfo(info) {
  return {
    key: `${info.key}-${chrome.runtime.id || "runtime"}`,
    name: info.name,
  };
}

function browserInfoFromUserAgent(userAgent) {
  if (userAgent.includes("Arc/")) return { key: "arc", name: "Arc" };
  if (userAgent.includes("Edg/")) return { key: "edge", name: "Microsoft Edge" };
  if (userAgent.includes("OPR/") || userAgent.includes("Opera/")) return { key: "opera", name: "Opera" };
  if (userAgent.includes("Vivaldi/")) return { key: "vivaldi", name: "Vivaldi" };
  if (userAgent.includes("Helium/")) return { key: "helium", name: "Helium" };
  if (userAgent.includes("Chromium/")) return { key: "chromium", name: "Chromium" };
  if (userAgent.includes("Chrome/")) return { key: "chrome", name: "Chrome" };
  return { key: "chromium", name: "Chromium" };
}

function publishSnapshot() {
  removeStaleTargets();
  sendNative({
    type: "snapshot",
    protocolVersion: 1,
    createdAt: Date.now(),
    targets: Array.from(targets.values()).filter(isVisibleTarget),
  });
}

function isVisibleTarget(target) {
  if (isAudiblePlayback(target)) return true;
  if (target.hasMediaSessionMetadata) return true;
  return Date.now() - target.lastActiveAt <= recentlyActiveAfterMs;
}

function isAudiblePlayback(target) {
  return target.playing && !target.muted && target.volume !== 0;
}

function removeStaleTargets() {
  const now = Date.now();
  for (const [id, target] of targets) {
    if (now - target.updatedAt > targetStaleAfterMs) {
      targets.delete(id);
    }
  }
}

function clearTargetsForTab(tabId) {
  let changed = false;
  for (const [id, target] of targets) {
    if (target.tabId === tabId) {
      targets.delete(id);
      changed = true;
    }
  }
  if (changed) publishSnapshot();
}

function probeTabsForMedia() {
  chrome.tabs.query({}, tabs => {
    for (const tab of tabs) {
      if (tab.id === undefined) continue;
      chrome.tabs.sendMessage(tab.id, { type: "keywayProbeMedia" }, () => {
        chrome.runtime.lastError;
      });
    }
  });
}

function handleNativeMessage(message) {
  if (message.type === "command") {
    handleCommandMessage(message);
    return;
  }
  if (message.type === "focusTarget") {
    handleFocusMessage(message);
  }
}

function handleCommandMessage(message) {
  if (!targets.has(message.targetID)) {
    sendNative({
      type: "commandResult",
      requestID: message.requestID,
      targetID: message.targetID,
      command: message.command,
      ok: false,
      unsupported: false,
      message: "Chromium extension target is no longer available.",
      backend: "chromium_extension",
    });
    return;
  }

  chrome.tabs.sendMessage(
    message.tabId,
    {
      type: "keywayCommand",
      requestID: message.requestID,
      mediaId: message.mediaId,
      command: message.command,
      volumeDelta: message.volumeDelta || 0,
    },
    { frameId: message.frameId },
    response => {
      const error = chrome.runtime.lastError;
      sendNative({
        type: "commandResult",
        requestID: message.requestID,
        targetID: message.targetID,
        command: message.command,
        ok: !error && Boolean(response && response.ok),
        unsupported: Boolean(response && response.unsupported),
        message: error ? error.message || "Chromium tab command failed." : response && response.message ? response.message : "Chromium tab did not acknowledge the command.",
        backend: "chromium_extension",
      });
    }
  );
}

function handleFocusMessage(message) {
  const target = targets.get(message.targetID);
  if (!target) return;

  chrome.windows.update(target.windowId, { focused: true }, () => {
    const windowError = chrome.runtime.lastError;
    if (windowError) {
      sendNative({
        type: "focusResult",
        requestID: message.requestID,
        targetID: message.targetID,
        ok: false,
        message: windowError.message || "Could not focus browser window.",
        backend: "chromium_extension",
        failureReason: "browser_activation_failed",
      });
      return;
    }

    chrome.tabs.update(target.tabId, { active: true }, () => {
      const tabError = chrome.runtime.lastError;
      sendNative({
        type: "focusResult",
        requestID: message.requestID,
        targetID: message.targetID,
        ok: !tabError,
        message: tabError ? tabError.message || "Could not activate browser tab." : "focused",
        backend: "chromium_extension",
        failureReason: tabError ? "browser_target_unavailable" : undefined,
      });
    });
  });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "keywayMediaState") {
    const tab = sender.tab;
    if (!tab || sender.frameId === undefined) {
      sendResponse({ ok: false });
      return false;
    }

    browserInfo().then(browser => {
      const stateID = targetID({
        browserKey: browser.key,
        windowId: tab.windowId,
        tabId: tab.id,
        frameId: sender.frameId,
        mediaId: message.mediaId,
      });
      const existingState = targets.get(stateID);
      const state = {
        type: "target",
        id: stateID,
        browser: browser.name,
        tabId: tab.id,
        windowId: tab.windowId,
        frameId: sender.frameId,
        mediaId: message.mediaId,
        url: message.url || tab.url || "",
        pageTitle: message.pageTitle || tab.title || "",
        title: message.title || tab.title || "Browser media",
        artist: message.artist || "",
        album: message.album || "",
        playing: Boolean(message.playing),
        muted: Boolean(message.muted),
        volume: Number.isFinite(message.volume) ? message.volume : null,
        duration: Number.isFinite(message.duration) ? message.duration : null,
        elapsedTime: Number.isFinite(message.elapsedTime) ? message.elapsedTime : null,
        hasMediaSessionMetadata: Boolean(message.hasMediaSessionMetadata),
        supportedCommands: Array.isArray(message.supportedCommands)
          ? message.supportedCommands
          : ["play", "pause", "playPause", "mute", "volumeDelta"],
        updatedAt: Date.now(),
      };
      state.lastActiveAt = isAudiblePlayback(state) ? state.updatedAt : existingState?.lastActiveAt || 0;
      targets.set(state.id, state);
      publishSnapshot();
      sendResponse({ ok: true });
    });
    return true;
  }

  if (message.type === "keywayMediaGone") {
    for (const [id, target] of targets) {
      if (target.tabId === sender.tab?.id && target.frameId === sender.frameId && target.mediaId === message.mediaId) {
        targets.delete(id);
      }
    }
    publishSnapshot();
    sendResponse({ ok: true });
    return false;
  }

  return false;
});

chrome.tabs.onRemoved.addListener(tabId => {
  clearTargetsForTab(tabId);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.url || changeInfo.status === "loading") {
    clearTargetsForTab(tabId);
  }
});

connectNativeHost();
