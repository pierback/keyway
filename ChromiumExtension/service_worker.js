const nativeHostName = "com.fpieringer.keyway.chromium";
let nativePort = null;
let reconnectTimer = null;
let heartbeatTimer = null;
let cachedBrowserInfo = null;
const sources = new Map();
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

function sourceID(message) {
  return ["chromium-extension", message.browserKey, message.tabId].join(":");
}

function candidateID(frameId, mediaId) {
  return `${frameId}:${mediaId}`;
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
  removeStaleSources();
  sendNative({
    type: "snapshot",
    protocolVersion: 1,
    createdAt: Date.now(),
    targets: Array.from(sources.values()).map(materializeSource).filter(Boolean).filter(isVisibleTarget),
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

function removeStaleSources() {
  const now = Date.now();
  for (const [id, source] of sources) {
    for (const [candidateKey, candidate] of source.candidates) {
      if (now - candidate.updatedAt > targetStaleAfterMs) {
        source.candidates.delete(candidateKey);
      }
    }

    if (source.candidates.size === 0) {
      sources.delete(id);
    } else {
      refreshSource(source);
    }
  }
}

function clearSourcesForTab(tabId) {
  let changed = false;
  for (const [id, source] of sources) {
    if (source.tabId === tabId) {
      sources.delete(id);
      changed = true;
    }
  }
  if (changed) publishSnapshot();
}

function upsertCandidate(browser, tab, frameId, message) {
  const now = Date.now();
  const id = sourceID({
    browserKey: browser.key,
    tabId: tab.id,
  });
  const candidateKey = candidateID(frameId, message.mediaId);
  const existingSource = sources.get(id);
  const source = existingSource || {
    type: "target",
    id,
    browser: browser.name,
    tabId: tab.id,
    windowId: tab.windowId,
    tabTitle: tab.title || "",
    tabUrl: tab.url || "",
    candidates: new Map(),
    route: null,
    updatedAt: now,
    lastActiveAt: 0,
  };
  const existingCandidate = source.candidates.get(candidateKey);
  const candidate = {
    candidateKey,
    frameId,
    mediaId: message.mediaId,
    url: message.url || tab.url || "",
    frameTitle: message.pageTitle || "",
    tabTitle: tab.title || "",
    tabUrl: tab.url || "",
    title: message.title || "",
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
    updatedAt: now,
    lastActiveAt: 0,
  };

  candidate.lastActiveAt = isAudiblePlayback(candidate)
    ? now
    : existingCandidate?.lastActiveAt || 0;
  source.browser = browser.name;
  source.windowId = tab.windowId;
  source.tabTitle = tab.title || source.tabTitle || "";
  source.tabUrl = tab.url || source.tabUrl || "";
  source.candidates.set(candidateKey, candidate);
  refreshSource(source);
  sources.set(source.id, source);
  return source;
}

function refreshSource(source) {
  const selected = selectPrimaryCandidate(source);
  if (!selected) {
    source.route = null;
    source.updatedAt = Date.now();
    source.lastActiveAt = 0;
    return;
  }

  let updatedAt = 0;
  let lastActiveAt = 0;
  for (const candidate of source.candidates.values()) {
    updatedAt = Math.max(updatedAt, candidate.updatedAt);
    lastActiveAt = Math.max(lastActiveAt, candidate.lastActiveAt);
  }

  source.route = {
    candidateKey: selected.candidateKey,
    frameId: selected.frameId,
    mediaId: selected.mediaId,
  };
  source.updatedAt = updatedAt;
  source.lastActiveAt = lastActiveAt;
}

function selectPrimaryCandidate(source) {
  let selected = null;
  const now = Date.now();
  for (const candidate of source.candidates.values()) {
    if (!selected || compareCandidates(candidate, selected, source.route, now) < 0) {
      selected = candidate;
    }
  }
  return selected;
}

function compareCandidates(left, right, currentRoute, now) {
  const scoreDifference = candidateScore(right, currentRoute, now) - candidateScore(left, currentRoute, now);
  if (scoreDifference !== 0) return scoreDifference;
  if (right.updatedAt !== left.updatedAt) return right.updatedAt - left.updatedAt;
  return left.candidateKey.localeCompare(right.candidateKey);
}

function candidateScore(candidate, currentRoute, now) {
  let score = 0;
  if (isAudiblePlayback(candidate)) {
    score += 100000;
  } else if (candidate.playing) {
    score += 50000;
  }
  if (candidate.hasMediaSessionMetadata) score += 10000;
  if (candidate.duration !== null && candidate.duration > 0) score += 1000;
  if (candidate.lastActiveAt > 0 && now - candidate.lastActiveAt <= recentlyActiveAfterMs) score += 500;
  if (currentRoute?.candidateKey === candidate.candidateKey) score += 10;
  score += Math.max(0, 100 - Math.floor((now - candidate.updatedAt) / 100));
  return score;
}

function materializeSource(source) {
  const selected = source.route ? source.candidates.get(source.route.candidateKey) : selectPrimaryCandidate(source);
  if (!selected) return null;

  const pageTitle = source.tabTitle || selected.frameTitle || "";
  const title = selected.hasMediaSessionMetadata && selected.title
    ? selected.title
    : source.tabTitle || selected.title || selected.frameTitle || "Browser media";
  return {
    type: "target",
    id: source.id,
    browser: source.browser,
    tabId: source.tabId,
    windowId: source.windowId,
    frameId: selected.frameId,
    mediaId: selected.mediaId,
    url: source.tabUrl || selected.url,
    pageTitle,
    title,
    artist: selected.artist,
    album: selected.album,
    playing: selected.playing,
    muted: selected.muted,
    volume: selected.volume,
    duration: selected.duration,
    elapsedTime: selected.elapsedTime,
    hasMediaSessionMetadata: selected.hasMediaSessionMetadata,
    supportedCommands: selected.supportedCommands,
    updatedAt: source.updatedAt,
    lastActiveAt: source.lastActiveAt,
  };
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
  removeStaleSources();
  const source = sources.get(message.targetID);
  const route = source?.route;
  if (!source || !route) {
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
    source.tabId,
    {
      type: "keywayCommand",
      requestID: message.requestID,
      mediaId: route.mediaId,
      command: message.command,
      volumeDelta: message.volumeDelta || 0,
    },
    { frameId: route.frameId },
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
  removeStaleSources();
  const source = sources.get(message.targetID);
  if (!source) return;

  chrome.windows.update(source.windowId, { focused: true }, () => {
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

    chrome.tabs.update(source.tabId, { active: true }, () => {
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
      upsertCandidate(browser, tab, sender.frameId, message);
      publishSnapshot();
      sendResponse({ ok: true });
    });
    return true;
  }

  if (message.type === "keywayMediaGone") {
    let changed = false;
    for (const [id, source] of sources) {
      if (source.tabId === sender.tab?.id) {
        const key = candidateID(sender.frameId, message.mediaId);
        if (source.candidates.delete(key)) {
          changed = true;
          if (source.candidates.size === 0) {
            sources.delete(id);
          } else {
            refreshSource(source);
          }
        }
      }
    }
    if (changed) publishSnapshot();
    sendResponse({ ok: true });
    return false;
  }

  return false;
});

chrome.tabs.onRemoved.addListener(tabId => {
  clearSourcesForTab(tabId);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.url || changeInfo.status === "loading") {
    clearSourcesForTab(tabId);
  }
});

connectNativeHost();
