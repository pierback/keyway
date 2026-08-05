export function isVisibleTarget(target) {
  if (isAudiblePlayback(target)) return true;
  if (target.hasMediaSessionMetadata) return true;
  return target.hasPlaybackActivity;
}

export function isAudiblePlayback(target, source = null) {
  const muted = source ? source.muted : target.muted;
  if (!target.playing || muted || target.volume === 0) return false;
  if (source && typeof source.tabAudible === "boolean") return source.tabAudible;
  if (typeof target.tabAudible === "boolean") return target.tabAudible;
  return true;
}

export function refreshSource(source, now = Date.now(), staleAfterMs = 15000) {
  const selected = selectPrimaryCandidate(source, now, staleAfterMs);
  if (!selected) {
    source.route = null;
    source.updatedAt = now;
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
    documentAuthorityGeneration: selected.documentAuthorityGeneration,
    browserDocumentID: selected.browserDocumentID,
    frameId: selected.frameId,
    mediaId: selected.mediaId,
  };
  source.updatedAt = updatedAt;
  source.lastActiveAt = lastActiveAt;
}

export function selectPrimaryCandidate(source, now = Date.now(), staleAfterMs = 15000) {
  const current = source.route ? source.candidates.get(source.route.candidateKey) : null;
  const audible = bestCandidate(
    source,
    candidate => isAudiblePlayback(candidate, source),
    current,
    now,
    staleAfterMs
  );
  if (audible) {
    if (current && current.candidateKey !== audible.candidateKey && isAudiblePlayback(current, source)) {
      return current;
    }
    return audible;
  }

  if (current && isStickyCandidate(current, now, staleAfterMs)) {
    return current;
  }

  return bestCandidate(source, () => true, current, now, staleAfterMs);
}

function bestCandidate(source, predicate, current, now, staleAfterMs) {
  let selected = null;
  for (const candidate of source.candidates.values()) {
    if (!predicate(candidate)) continue;
    if (!selected || compareCandidates(candidate, selected, current, now, source, staleAfterMs) < 0) {
      selected = candidate;
    }
  }
  return selected;
}

function isStickyCandidate(candidate, now, staleAfterMs) {
  return now - candidate.updatedAt <= staleAfterMs
    && (candidate.playing || candidate.hasPlaybackActivity);
}

function compareCandidates(left, right, current, now, source, staleAfterMs) {
  const scoreDifference = candidateScore(right, current, now, source, staleAfterMs)
    - candidateScore(left, current, now, source, staleAfterMs);
  if (scoreDifference !== 0) return scoreDifference;
  if (right.updatedAt !== left.updatedAt) return right.updatedAt - left.updatedAt;
  return left.candidateKey.localeCompare(right.candidateKey);
}

function candidateScore(candidate, current, now, source, staleAfterMs) {
  let score = 0;
  if (isAudiblePlayback(candidate, source)) {
    score += 100000;
  } else if (candidate.playing && !source.muted) {
    score += 50000;
  } else if (candidate.playing) {
    score += 1000;
  }
  if (current?.candidateKey === candidate.candidateKey && isStickyCandidate(candidate, now, staleAfterMs)) {
    score += 75000;
  }
  if (candidate.hasPlaybackActivity) score += 20000;
  if (candidate.duration !== null && candidate.duration > 0) score += 500;
  if (candidate.hasMediaSessionMetadata) score += 100;
  score += Math.max(0, 100 - Math.floor((now - candidate.updatedAt) / 100));
  return score;
}

export function materializeSource(source, now = Date.now(), staleAfterMs = 15000) {
  const selected = source.route
    ? source.candidates.get(source.route.candidateKey)
    : selectPrimaryCandidate(source, now, staleAfterMs);
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
    profileGuid: source.profileGuid,
    tabId: source.tabId,
    url: source.tabUrl || selected.url,
    pageTitle,
    title,
    artist: selected.artist,
    album: selected.album,
    playing: selected.playing,
    muted: source.muted,
    tabAudible: source.tabAudible,
    volume: selected.volume,
    duration: selected.duration,
    elapsedTime: selected.elapsedTime,
    hasMediaSessionMetadata: selected.hasMediaSessionMetadata,
    hasPlaybackActivity: selected.hasPlaybackActivity,
    supportedCommands: selected.supportedCommands,
    updatedAt: source.updatedAt,
    lastActiveAt: source.lastActiveAt,
  };
}
