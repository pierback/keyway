const nativeHostName = "com.fpieringer.keyway.chromium";
const protocolVersion = 2;
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
  sendNative({ type: "hello", protocolVersion });
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

function candidateID(documentID, frameId, mediaId) {
  return `${documentID}:${frameId}:${mediaId}`;
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
  const runtimeID = chrome.runtime.id || "runtime";
  return {
    key: `${info.key}-${runtimeID}`,
    family: info.key,
    runtimeID,
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
    protocolVersion,
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
  const candidateKey = candidateID(message.documentID, frameId, message.mediaId);
  const existingSource = sources.get(id);
  const source = existingSource || {
    type: "target",
    id,
    browser: browser.name,
    browserFamily: browser.family,
    browserRuntimeID: browser.runtimeID,
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
    documentID: message.documentID,
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
  source.browserFamily = browser.family;
  source.browserRuntimeID = browser.runtimeID;
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
    documentID: selected.documentID,
    frameId: selected.frameId,
    mediaId: selected.mediaId,
  };
  source.updatedAt = updatedAt;
  source.lastActiveAt = lastActiveAt;
}

function selectPrimaryCandidate(source) {
  const now = Date.now();
  const current = source.route ? source.candidates.get(source.route.candidateKey) : null;
  const audible = bestCandidate(source, candidate => isAudiblePlayback(candidate), current, now);
  if (audible) {
    if (current && current.candidateKey !== audible.candidateKey && isAudiblePlayback(current)) {
      return current;
    }
    return audible;
  }

  if (current && isStickyCandidate(current, now)) {
    return current;
  }

  return bestCandidate(source, () => true, current, now);
}

function bestCandidate(source, predicate, current, now) {
  let selected = null;
  for (const candidate of source.candidates.values()) {
    if (!predicate(candidate)) continue;
    if (!selected || compareCandidates(candidate, selected, current, now) < 0) {
      selected = candidate;
    }
  }
  return selected;
}

function isStickyCandidate(candidate, now) {
  return now - candidate.updatedAt <= targetStaleAfterMs
    && (candidate.playing || (candidate.lastActiveAt > 0 && now - candidate.lastActiveAt <= recentlyActiveAfterMs));
}

function compareCandidates(left, right, current, now) {
  const scoreDifference = candidateScore(right, current, now) - candidateScore(left, current, now);
  if (scoreDifference !== 0) return scoreDifference;
  if (right.updatedAt !== left.updatedAt) return right.updatedAt - left.updatedAt;
  return left.candidateKey.localeCompare(right.candidateKey);
}

function candidateScore(candidate, current, now) {
  let score = 0;
  if (isAudiblePlayback(candidate)) {
    score += 100000;
  } else if (candidate.playing && !candidate.muted) {
    score += 50000;
  } else if (candidate.playing) {
    score += 1000;
  }
  if (current?.candidateKey === candidate.candidateKey && isStickyCandidate(candidate, now)) score += 75000;
  if (candidate.lastActiveAt > 0 && now - candidate.lastActiveAt <= recentlyActiveAfterMs) score += 20000;
  if (candidate.duration !== null && candidate.duration > 0) score += 500;
  if (candidate.hasMediaSessionMetadata) score += 100;
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
    browserFamily: source.browserFamily,
    browserRuntimeID: source.browserRuntimeID,
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
      if (tab.url && !tab.url.startsWith("http://") && !tab.url.startsWith("https://")) continue;
      chrome.scripting.executeScript(
        { target: { tabId: tab.id, allFrames: true }, files: ["content_script.js"] },
        () => {
          chrome.runtime.lastError;
          chrome.tabs.sendMessage(tab.id, { type: "keywayProbeMedia", protocolVersion }, () => {
            chrome.runtime.lastError;
          });
        }
      );
    }
  });
}

function handleNativeMessage(message) {
  if (message.protocolVersion !== protocolVersion) {
    rejectUnsupportedProtocol(message);
    return;
  }

  if (message.type === "reloadExtension") {
    chrome.runtime.reload();
    return;
  }
  if (message.type === "command") {
    handleCommandMessage(message);
    return;
  }
  if (message.type === "focusTarget") {
    handleFocusMessage(message);
  }
}

function rejectUnsupportedProtocol(message) {
  if (message.type === "command") {
    sendNative({
      type: "commandResult",
      protocolVersion,
      requestID: message.requestID,
      targetID: message.targetID,
      command: message.command,
      ok: false,
      unsupported: true,
      message: "Chromium extension protocol mismatch.",
      backend: "chromium_extension",
    });
  }
  if (message.type === "focusTarget") {
    sendNative({
      type: "focusResult",
      protocolVersion,
      requestID: message.requestID,
      targetID: message.targetID,
      ok: false,
      message: "Chromium extension protocol mismatch.",
      backend: "chromium_extension",
      failureReason: "chromium_extension_protocol_mismatch",
    });
  }
}

function handleCommandMessage(message) {
  removeStaleSources();
  const source = sources.get(message.targetID);
  const route = source?.route;
  if (!source || !route) {
    sendNative({
      type: "commandResult",
      protocolVersion,
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

  const selected = source.candidates.get(route.candidateKey);
  if (!selected || !selected.supportedCommands.includes(message.command)) {
    sendNative({
      type: "commandResult",
      protocolVersion,
      requestID: message.requestID,
      targetID: message.targetID,
      command: message.command,
      ok: false,
      unsupported: true,
      message: `${message.command} is unsupported for this Chromium media source.`,
      backend: "chromium_extension",
    });
    return;
  }

  chrome.tabs.sendMessage(
    source.tabId,
    {
      type: "keywayCommand",
      requestID: message.requestID,
      documentID: route.documentID,
      mediaId: route.mediaId,
      command: message.command,
      volumeDelta: message.volumeDelta || 0,
    },
    { frameId: route.frameId },
    response => {
      const error = chrome.runtime.lastError;
      sendNative({
        type: "commandResult",
        protocolVersion,
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
  if (!source) {
    sendNative({
      type: "focusResult",
      protocolVersion,
      requestID: message.requestID,
      targetID: message.targetID,
      ok: false,
      message: "Chromium extension target is no longer available.",
      backend: "chromium_extension",
      failureReason: "browser_target_unavailable",
    });
    return;
  }

  chrome.tabs.get(source.tabId, tab => {
    const lookupError = chrome.runtime.lastError;
    if (lookupError || !tab) {
      sendNative({
        type: "focusResult",
        protocolVersion,
        requestID: message.requestID,
        targetID: message.targetID,
        ok: false,
        message: lookupError ? lookupError.message || "Could not find browser tab." : "Could not find browser tab.",
        backend: "chromium_extension",
        failureReason: "browser_target_unavailable",
      });
      return;
    }

    if (!Number.isInteger(tab.id) || !Number.isInteger(tab.windowId)) {
      sendNative({
        type: "focusResult",
        protocolVersion,
        requestID: message.requestID,
        targetID: message.targetID,
        ok: false,
        message: "Could not resolve browser tab.",
        backend: "chromium_extension",
        failureReason: "browser_target_unavailable",
      });
      return;
    }

    chrome.tabs.update(tab.id, { active: true }, () => {
      const tabError = chrome.runtime.lastError;
      if (tabError) {
        sendNative({
          type: "focusResult",
          protocolVersion,
          requestID: message.requestID,
          targetID: message.targetID,
          ok: false,
          message: tabError.message || "Could not activate browser tab.",
          backend: "chromium_extension",
          failureReason: "browser_target_unavailable",
        });
        return;
      }

      chrome.windows.update(tab.windowId, { focused: true }, () => {
        const windowError = chrome.runtime.lastError;
        if (windowError) {
          sendNative({
            type: "focusResult",
            protocolVersion,
            requestID: message.requestID,
            targetID: message.targetID,
            ok: false,
            message: windowError.message || "Could not focus browser window.",
            backend: "chromium_extension",
            failureReason: "browser_activation_failed",
          });
          return;
        }

        chrome.tabs.query({ active: true, windowId: tab.windowId }, activeTabs => {
          const queryError = chrome.runtime.lastError;
          const selected = !queryError && activeTabs.some(activeTab => activeTab.id === tab.id);
          const errorMessage = queryError
            ? queryError.message || "Could not confirm active browser tab."
            : "Could not activate browser tab.";

          sendNative({
            type: "focusResult",
            protocolVersion,
            requestID: message.requestID,
            targetID: message.targetID,
            ok: selected,
            message: selected ? "focused" : errorMessage,
            backend: "chromium_extension",
            failureReason: selected ? undefined : "browser_target_unavailable",
          });
        });
      });
    });
  });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "keywayMediaState") {
    const tab = sender.tab;
    if (!tab || sender.frameId === undefined || !message.documentID) {
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
        const key = candidateID(message.documentID, sender.frameId, message.mediaId);
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
