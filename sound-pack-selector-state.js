(function installSoundPackSelectorState(root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.ClaudioSoundPackSelectorState = api;
  }
})(typeof globalThis === "undefined" ? this : globalThis, function makeSoundPackSelectorState() {
  "use strict";

  function resolveStoredSelection(stored, knownPackIds, defaultPackIds) {
    if (!Array.isArray(stored)) return [...defaultPackIds];
    const known = new Set(knownPackIds);
    const valid = stored.filter(id => known.has(id));
    return stored.length === 0 || valid.length ? valid : [...defaultPackIds];
  }

  function changeBlindPack(nextPackId, stopAllAudio) {
    stopAllAudio();
    return {
      packId: nextPackId,
      round: null,
      correct: 0,
      total: 0,
      startLabel: "开始盲听",
      prompt: "点击“开始盲听”，不要先看下面的事件标签。",
      result: "答案会在你选择后揭晓。"
    };
  }

  function replaceSelection(nextSelection, effects) {
    effects.stopAllAudio();
    const selected = new Set(nextSelection);
    effects.setSelection(selected);
    effects.saveSelection();
    effects.render();
    return selected;
  }

  return Object.freeze({
    changeBlindPack,
    replaceSelection,
    resolveStoredSelection
  });
});
