import { DocumentAuthorityRegistry } from "./document_authority.js";
import {
  isAudiblePlayback,
  isVisibleTarget,
  materializeSource,
  refreshSource,
} from "./media_source_selection.js";

const nativeHostName = "com.fpieringer.keyway.chromium";
const protocolVersion = 4;
const profileGuidStorageKey = "profileGuid";
const snapshotStorageKey = "lastPublishedSnapshotTargets";
const snapshotEpochStorageKey = "snapshotEpoch";
const nativePortAlarmName = "keyway-native-port-dead-man";
const activeHeartbeatIntervalMs = 1000;
const idleKeepaliveIntervalMs = 25000;
const resumeBridgeMaxAgeMs = 10000;
let nativePort = null;
let nativePortGeneration = 0;
let reconnectTimer = null;
let heartbeatTimer = null;
let heartbeatMode = null;
let cachedBrowserInfo = null;
let profileGuid = null;
let profileGuidLoading = false;
let snapshotEpoch = 0;
let resumeStateGeneration = 0;
let pendingResumeTargets = null;
let pendingResumeExpiresAt = 0;
const profileGuidCallbacks = [];
const sources = new Map();
const documentAuthorities = new DocumentAuthorityRegistry();
const targetStaleAfterMs = 15000;

function connectNativeHost() {
  if (nativePort) return;

  const port = chrome.runtime.connectNative(nativeHostName);
  nativePortGeneration += 1;
  const generation = nativePortGeneration;
  nativePort = port;
  resumeStateGeneration = 0;
  port.onMessage.addListener(message => {
    if (!isCurrentNativePort(port, generation)) return;
    handleNativeMessage(message, port, generation);
  });
  port.onDisconnect.addListener(() => {
    if (!isCurrentNativePort(port, generation)) return;
    nativePort = null;
    resumeStateGeneration = 0;
    stopHeartbeat();
    scheduleReconnect();
  });
  loadResumeState(resume => {
    if (!isCurrentNativePort(port, generation)) return;
    snapshotEpoch = resume.epoch;
    resumeStateGeneration = generation;
    setPendingResumeTargets(resume.resumed ? resume.snapshot : null);
    sendNative({
      type: "hello",
      protocolVersion,
      profileGuid,
      epoch: snapshotEpoch,
      resumed: resume.resumed,
      ...(resume.resumed ? { snapshot: resume.snapshot } : {}),
    }, port, generation);
    probeTabsForMedia();
    publishSnapshot(port, generation);
  });
}

function isCurrentNativePort(port, generation) {
  return nativePort === port && nativePortGeneration === generation;
}

function loadProfileGuid(callback) {
  if (profileGuid) {
    callback();
    return;
  }
  profileGuidCallbacks.push(callback);
  if (profileGuidLoading) return;
  profileGuidLoading = true;

  chrome.storage.local.get([profileGuidStorageKey], result => {
    void chrome.runtime.lastError;
    const storedProfileGuid = result && result[profileGuidStorageKey];
    if (typeof storedProfileGuid === "string" && storedProfileGuid) {
      profileGuid = storedProfileGuid;
      flushProfileGuidCallbacks();
      return;
    }

    profileGuid = crypto.randomUUID();
    chrome.storage.local.set({ [profileGuidStorageKey]: profileGuid }, flushProfileGuidCallbacks);
  });
}

function flushProfileGuidCallbacks() {
  profileGuidLoading = false;
  const callbacks = profileGuidCallbacks.splice(0);
  for (const callback of callbacks) {
    callback();
  }
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNativeHost();
  }, 1000);
}

function sendNative(message, port = nativePort, generation = nativePortGeneration) {
  if (!port || !isCurrentNativePort(port, generation)) return;
  port.postMessage(message);
}

function startHeartbeat(mode, port, generation) {
  if (!isCurrentNativePort(port, generation)) return;
  if (heartbeatTimer && heartbeatMode === mode) return;
  stopHeartbeat();
  heartbeatMode = mode;
  heartbeatTimer = setInterval(
    () => {
      if (mode === "active") {
        publishSnapshot(port, generation);
      } else {
        publishKeepalive(port, generation);
      }
    },
    mode === "active" ? activeHeartbeatIntervalMs : idleKeepaliveIntervalMs
  );
}

function stopHeartbeat() {
  if (!heartbeatTimer) return;
  clearInterval(heartbeatTimer);
  heartbeatTimer = null;
  heartbeatMode = null;
}

function setPendingResumeTargets(targets) {
  pendingResumeTargets = targets && targets.length > 0 ? targets : null;
  pendingResumeExpiresAt = pendingResumeTargets ? Date.now() + resumeBridgeMaxAgeMs : 0;
}

function clearPendingResumeTargets() {
  pendingResumeTargets = null;
  pendingResumeExpiresAt = 0;
}

function currentPendingResumeTargets() {
  if (!pendingResumeTargets) return null;
  if (Date.now() > pendingResumeExpiresAt) {
    clearPendingResumeTargets();
    return null;
  }
  return pendingResumeTargets;
}

function prunePendingResumeTargets(predicate) {
  if (!pendingResumeTargets) return false;
  const targets = pendingResumeTargets.filter(predicate);
  if (targets.length === pendingResumeTargets.length) return false;
  setPendingResumeTargets(targets);
  return true;
}

function publishKeepalive(port = nativePort, generation = nativePortGeneration) {
  if (!isCurrentNativePort(port, generation)) return;
  sendNative({
    type: "keepalive",
    protocolVersion,
    profileGuid,
    createdAt: Date.now(),
  }, port, generation);
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

function publishSnapshot(port = nativePort, generation = nativePortGeneration) {
  if (!isCurrentNativePort(port, generation)) return;
  // Guard against a message-triggered wake (e.g. keywayMediaState) calling this
  // before connectNativeHost()'s loadResumeState() callback has set the real
  // epoch -- publishing early would write epoch 1 into chrome.storage.session,
  // regressing the persisted epoch and widening the resume-wedge window a crash
  // could land in. Nothing is lost: `sources` stays in memory, and the
  // connect-time publish (which runs after resume state loads) covers it.
  if (resumeStateGeneration !== generation) return;
  removeStaleSources();
  const materializedTargets = Array.from(sources.values())
    .map(source => materializeSource(source, Date.now(), targetStaleAfterMs))
    .filter(Boolean);
  let targets = materializedTargets.filter(isVisibleTarget);
  if (materializedTargets.length > 0) {
    clearPendingResumeTargets();
  } else {
    const resumeTargets = currentPendingResumeTargets();
    if (targets.length === 0 && resumeTargets) {
      targets = resumeTargets;
    }
  }
  snapshotEpoch += 1;
  sendNative({
    type: "snapshot",
    protocolVersion,
    epoch: snapshotEpoch,
    createdAt: Date.now(),
    targets,
  }, port, generation);
  chrome.storage.session.set({
    [snapshotStorageKey]: targets,
    [snapshotEpochStorageKey]: snapshotEpoch,
  });
  const hasTargets = sources.size > 0
    || targets.length > 0
    || (pendingResumeTargets && pendingResumeTargets.length > 0);
  startHeartbeat(hasTargets ? "active" : "idle", port, generation);
}

function loadResumeState(callback) {
  chrome.storage.session.get([snapshotStorageKey, snapshotEpochStorageKey], result => {
    const storedSnapshot = result && result[snapshotStorageKey];
    const storedEpoch = result && result[snapshotEpochStorageKey];
    if (!Array.isArray(storedSnapshot) || !Number.isInteger(storedEpoch)) {
      callback({ resumed: false, epoch: 0, snapshot: [] });
      return;
    }

    chrome.tabs.query({}, tabs => {
      const liveTabIds = new Set(tabs.map(tab => tab.id).filter(Number.isInteger));
      callback({
        resumed: true,
        epoch: storedEpoch,
        snapshot: storedSnapshot.filter(target => liveTabIds.has(target.tabId)),
      });
    });
  });
}

function removeStaleSources() {
  const now = Date.now();
  for (const [id, source] of sources) {
    let removedCandidate = false;
    for (const [candidateKey, candidate] of source.candidates) {
      if (now - candidate.updatedAt > targetStaleAfterMs) {
        source.candidates.delete(candidateKey);
        removedCandidate = true;
      }
    }

    if (source.candidates.size === 0) {
      sources.delete(id);
    } else if (removedCandidate) {
      refreshSource(source, now, targetStaleAfterMs);
    }
  }
}

function clearSourcesForTab(tabId) {
  let changed = false;
  documentAuthorities.retireTab(tabId);
  if (prunePendingResumeTargets(target => target.tabId !== tabId)) {
    changed = true;
  }
  for (const [id, source] of sources) {
    if (source.tabId === tabId) {
      sources.delete(id);
      changed = true;
    }
  }
  if (changed) publishSnapshot();
}

function clearSourcesForFrame(tabId, frameId) {
  let changed = false;
  for (const [id, source] of sources) {
    if (source.tabId !== tabId) continue;
    let sourceChanged = false;
    for (const [candidateKey, candidate] of source.candidates) {
      if (candidate.frameId === frameId) {
        source.candidates.delete(candidateKey);
        changed = true;
        sourceChanged = true;
      }
    }
    if (source.candidates.size === 0) {
      sources.delete(id);
    } else if (sourceChanged) {
      refreshSource(source, Date.now(), targetStaleAfterMs);
    }
  }
  if (changed) publishSnapshot();
}

function reactivateCommittedFrameTree(tabId, mainAuthority) {
  chrome.webNavigation.getAllFrames({ tabId }, frames => {
    const error = chrome.runtime.lastError;
    const currentMain = documentAuthorities.authority(tabId, 0);
    if (error
        || !Array.isArray(frames)
        || !currentMain
        || currentMain.generation !== mainAuthority.generation
        || currentMain.browserDocumentID !== mainAuthority.browserDocumentID) {
      return;
    }

    for (const frame of frames) {
      if (!Number.isInteger(frame.frameId)
          || frame.frameId === 0
          || typeof frame.documentId !== "string"
          || !frame.documentId
          || frame.documentLifecycle !== "active") {
        continue;
      }

      const authority = documentAuthorities.reactivateRetired(tabId, frame.frameId, frame.documentId);
      if (!authority) continue;
      chrome.tabs.sendMessage(
        tabId,
        { type: "keywayProbeMedia", protocolVersion },
        { documentId: frame.documentId },
        () => {
          void chrome.runtime.lastError;
        }
      );
    }
  });
}

function commitDocumentAuthority(details) {
  if (!Number.isInteger(details.tabId)
      || !Number.isInteger(details.frameId)
      || typeof details.documentId !== "string"
      || !details.documentId) {
    return;
  }

  const existing = documentAuthorities.authority(details.tabId, details.frameId);
  if (existing?.browserDocumentID === details.documentId) return;

  if (details.frameId === 0) {
    clearSourcesForTab(details.tabId);
    const authority = documentAuthorities.activateCommitted(details.tabId, details.frameId, details.documentId);
    reactivateCommittedFrameTree(details.tabId, authority);
    return;
  } else {
    if (existing) documentAuthorities.retire(existing);
    clearSourcesForFrame(details.tabId, details.frameId);
  }
  documentAuthorities.activateCommitted(details.tabId, details.frameId, details.documentId);
}

function upsertCandidate(browser, tab, frameId, message, authority) {
  if (!documentAuthorities.isCurrent(authority)) return null;
  const now = Date.now();
  const id = ["chromium-tab", profileGuid, tab.id].join(":");
  const candidateKey = candidateID(message.documentID, frameId, message.mediaId);
  const existingSource = sources.get(id);
  const source = existingSource || {
    type: "target",
    id,
    browser: browser.name,
    browserFamily: browser.family,
    browserRuntimeID: browser.runtimeID,
    profileGuid,
    tabId: tab.id,
    windowId: tab.windowId,
    tabTitle: tab.title || "",
    tabUrl: tab.url || "",
    muted: Boolean(tab.mutedInfo?.muted),
    tabAudible: typeof tab.audible === "boolean" ? tab.audible : null,
    candidates: new Map(),
    route: null,
    updatedAt: now,
    lastActiveAt: 0,
  };
  const existingCandidate = source.candidates.get(candidateKey);
  const candidate = {
    candidateKey,
    documentID: message.documentID,
    documentAuthorityGeneration: authority.generation,
    browserDocumentID: authority.browserDocumentID,
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
    volume: Number.isFinite(message.volume) ? message.volume : null,
    duration: Number.isFinite(message.duration) ? message.duration : null,
    elapsedTime: Number.isFinite(message.elapsedTime) ? message.elapsedTime : null,
    hasMediaSessionMetadata: Boolean(message.hasMediaSessionMetadata),
    hasPlaybackActivity: Boolean(message.hasPlaybackActivity),
    supportedCommands: Array.isArray(message.supportedCommands)
      ? message.supportedCommands
      : ["play", "pause", "playPause", "mute", "volumeDelta"],
    updatedAt: now,
    lastActiveAt: 0,
  };

  source.muted = Boolean(tab.mutedInfo?.muted);
  source.tabAudible = typeof tab.audible === "boolean" ? tab.audible : source.tabAudible;
  candidate.lastActiveAt = isAudiblePlayback(candidate, source)
    ? now
    : existingCandidate?.lastActiveAt || 0;
  candidate.hasPlaybackActivity = candidate.hasPlaybackActivity
    || Boolean(existingCandidate?.hasPlaybackActivity)
    || candidate.lastActiveAt > 0;
  source.browser = browser.name;
  source.browserFamily = browser.family;
  source.browserRuntimeID = browser.runtimeID;
  source.windowId = tab.windowId;
  source.tabTitle = tab.title || source.tabTitle || "";
  source.tabUrl = tab.url || source.tabUrl || "";
  source.candidates.set(candidateKey, candidate);
  refreshSource(source, now, targetStaleAfterMs);
  sources.set(source.id, source);
  return source;
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

function handleNativeMessage(message, port, generation) {
  if (message.protocolVersion !== protocolVersion) {
    rejectUnsupportedProtocol(message, port, generation);
    return;
  }

  if (message.type === "reloadExtension") {
    chrome.runtime.reload();
    return;
  }
  if (message.type === "command") {
    handleCommandMessage(message, port, generation);
    return;
  }
  if (message.type === "focusTarget") {
    handleFocusMessage(message, port, generation);
  }
}

function rejectUnsupportedProtocol(message, port, generation) {
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
    }, port, generation);
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
    }, port, generation);
  }
}

function handleCommandMessage(message, port, generation) {
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
    }, port, generation);
    return;
  }

  const selected = source.candidates.get(route.candidateKey);
  const routeAuthority = {
    tabId: source.tabId,
    frameId: route.frameId,
    browserDocumentID: route.browserDocumentID,
    contentDocumentID: route.documentID,
    generation: route.documentAuthorityGeneration,
  };
  if (!selected || !documentAuthorities.isCurrent(routeAuthority)) {
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
    }, port, generation);
    return;
  }
  if (!selected.supportedCommands.includes(message.command)) {
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
    }, port, generation);
    return;
  }

  if (message.command === "mute") {
    handleTabMuteCommand(message, source, port, generation);
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
      }, port, generation);
    }
  );
}

function sendCommandResult(message, ok, unsupported, resultMessage, port, generation) {
  sendNative({
    type: "commandResult",
    protocolVersion,
    requestID: message.requestID,
    targetID: message.targetID,
    command: message.command,
    ok,
    unsupported,
    message: resultMessage,
    backend: "chromium_extension",
  }, port, generation);
}

function handleTabMuteCommand(message, source, port, generation) {
  chrome.tabs.get(source.tabId, tab => {
    const lookupError = chrome.runtime.lastError;
    if (lookupError || !tab) {
      sendCommandResult(
        message,
        false,
        false,
        lookupError ? lookupError.message || "Could not find browser tab." : "Could not find browser tab.",
        port,
        generation
      );
      return;
    }

    const muted = Boolean(tab.mutedInfo?.muted);
    chrome.tabs.update(source.tabId, { muted: !muted }, updatedTab => {
      const updateError = chrome.runtime.lastError;
      if (updateError) {
        sendCommandResult(
          message,
          false,
          false,
          updateError.message || "Chromium tab mute failed.",
          port,
          generation
        );
        return;
      }

      updateSourceTabState(source.tabId, updatedTab || { mutedInfo: { muted: !muted } });
      sendCommandResult(message, true, false, muted ? "unmuted" : "muted", port, generation);
    });
  });
}

function updateSourceTabState(tabId, tab) {
  let changed = false;
  for (const source of sources.values()) {
    if (source.tabId !== tabId) continue;
    const nextMuted = Boolean(tab.mutedInfo?.muted);
    const nextTabAudible = typeof tab.audible === "boolean" ? tab.audible : source.tabAudible;
    if (source.muted !== nextMuted || source.tabAudible !== nextTabAudible) {
      source.muted = nextMuted;
      source.tabAudible = nextTabAudible;
      refreshSource(source, Date.now(), targetStaleAfterMs);
      changed = true;
    }
  }
  if (changed) publishSnapshot();
}

function handleFocusMessage(message, port, generation) {
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
    }, port, generation);
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
      }, port, generation);
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
      }, port, generation);
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
        }, port, generation);
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
          }, port, generation);
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
          }, port, generation);
        });
      });
    });
  });
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "keywayMediaState") {
    const tab = sender.tab;
    const authority = documentAuthorities.capture(sender, message.documentID);
    if (!tab || !authority) {
      sendResponse({ ok: false });
      return false;
    }

    loadProfileGuid(() => {
      browserInfo().then(browser => {
        if (!documentAuthorities.isCurrent(authority)) {
          sendResponse({ ok: false });
          return;
        }
        upsertCandidate(browser, tab, sender.frameId, message, authority);
        publishSnapshot();
        sendResponse({ ok: true });
      });
    });
    return true;
  }

  if (message.type === "keywayMediaGone") {
    const authority = documentAuthorities.current(sender, message.documentID);
    if (!authority) {
      sendResponse({ ok: false });
      return false;
    }
    let changed = false;
    if (sender.tab?.id !== undefined && prunePendingResumeTargets(target => target.tabId !== sender.tab.id)) {
      changed = true;
    }
    for (const [id, source] of sources) {
      if (source.tabId === sender.tab?.id) {
        const key = candidateID(message.documentID, sender.frameId, message.mediaId);
        if (source.candidates.delete(key)) {
          changed = true;
          if (source.candidates.size === 0) {
            sources.delete(id);
          } else {
            refreshSource(source, Date.now(), targetStaleAfterMs);
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
  if (changeInfo.mutedInfo || typeof changeInfo.audible === "boolean") {
    chrome.tabs.get(tabId, tab => {
      const error = chrome.runtime.lastError;
      if (error || !tab) return;
      updateSourceTabState(tabId, tab);
    });
  }
});

chrome.webNavigation.onCommitted.addListener(commitDocumentAuthority);

chrome.alarms.create(nativePortAlarmName, { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === nativePortAlarmName && !nativePort) {
    loadProfileGuid(connectNativeHost);
  }
});

loadProfileGuid(connectNativeHost);
