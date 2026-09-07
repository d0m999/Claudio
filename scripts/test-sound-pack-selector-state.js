#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const selectorState = require("../sound-pack-selector-state.js");

const root = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(root, "sound-pack-selector.html"), "utf8");
const catalogSource = html.match(/const packs = \[([\s\S]*?)\n    \];/);
assert.ok(catalogSource, "selector pack catalog must remain readable");
const catalogIds = [...catalogSource[1].matchAll(/\n\s+id: "([a-z0-9-]+)"/g)]
  .map(match => match[1])
  .sort();
const repositoryPackIds = fs.readdirSync(path.join(root, "packs"), { withFileTypes: true })
  .filter(entry => entry.isDirectory() && entry.name !== "license-snapshots")
  .map(entry => entry.name)
  .sort();
assert.deepEqual(catalogIds, repositoryPackIds, "selector must list every repository pack");
assert.match(html, /src="sound-pack-selector-state\.js"/);
assert.match(html, /selectorState\.changeBlindPack\(/);
assert.match(html, /selectorState\.replaceSelection\(/);
assert.match(html, /selectorState\.resolveStoredSelection\(/);

const known = ["minimal-chime", "night-console"];
const defaults = ["minimal-chime"];
assert.deepEqual(selectorState.resolveStoredSelection(null, known, defaults), defaults);
assert.deepEqual(selectorState.resolveStoredSelection([], known, defaults), []);
assert.deepEqual(
  selectorState.resolveStoredSelection(["night-console", "removed-pack"], known, defaults),
  ["night-console"]
);
assert.deepEqual(
  selectorState.resolveStoredSelection(["removed-pack"], known, defaults),
  defaults
);

const blindEffects = [];
const reset = selectorState.changeBlindPack("night-console", () => blindEffects.push("stop"));
assert.deepEqual(blindEffects, ["stop"]);
assert.deepEqual(
  { packId: reset.packId, round: reset.round, correct: reset.correct, total: reset.total },
  { packId: "night-console", round: null, correct: 0, total: 0 }
);

const replacementEffects = [];
let landedSelection = null;
selectorState.replaceSelection(new Set(["night-console"]), {
  stopAllAudio() { replacementEffects.push("stop"); },
  setSelection(value) {
    replacementEffects.push("set");
    landedSelection = value;
  },
  saveSelection() { replacementEffects.push("save"); },
  render() { replacementEffects.push("render"); }
});
assert.deepEqual(replacementEffects, ["stop", "set", "save", "render"]);
assert.deepEqual([...landedSelection], ["night-console"]);

console.log("✓ sound-pack selector executable state seam passed");
