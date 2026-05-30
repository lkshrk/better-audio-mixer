// Minimal Stream Deck Property Inspector runtime shared by every BAM action PI.
// Handles the Elgato PI websocket handshake, settings persistence, and the
// device dropdown fed by the plugin (globalSettings cache + live listMixes).

let ws = null;
let piUUID = null;
let actionUUID = null;
let controller = "Keypad"; // "Keypad" or "Encoder" — set from actionInfo
let settings = {};
let onMixes = null; // optional callback([{id,name,emoji}])
let onOutputs = null; // optional callback([{uid,name,active}])

// Stream Deck calls this global on load.
function connectElgatoStreamDeckSocket(inPort, inUUID, inRegisterEvent, inInfo, inActionInfo) {
  piUUID = inUUID;
  const actionInfo = JSON.parse(inActionInfo);
  actionUUID = actionInfo.action;
  // controller lives in payload for the PI's actionInfo (top-level only in willAppear).
  controller = (actionInfo.payload && actionInfo.payload.controller)
    || actionInfo.controller || "Keypad";
  settings = (actionInfo.payload && actionInfo.payload.settings) || {};

  ws = new WebSocket("ws://127.0.0.1:" + inPort);
  ws.onopen = () => {
    ws.send(JSON.stringify({ event: inRegisterEvent, uuid: inUUID }));
    if (typeof piReady === "function") piReady(settings);
    requestMixes();
  };
  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.event === "didReceiveGlobalSettings") {
      const mixes = (msg.payload && msg.payload.settings && msg.payload.settings.mixes) || [];
      if (onMixes) onMixes(mixes);
    } else if (msg.event === "sendToPropertyInspector") {
      if (msg.payload && msg.payload.t === "mixes" && onMixes) onMixes(msg.payload.mixes || []);
      if (msg.payload && msg.payload.t === "outputs" && onOutputs) onOutputs(msg.payload.outputs || []);
    }
  };
}

function saveSettings() {
  if (!ws) return;
  ws.send(JSON.stringify({ event: "setSettings", context: piUUID, payload: settings }));
}

function setSetting(key, value) {
  settings[key] = value;
  saveSettings();
}

// Ask for both the cached list (globalSettings) and a live refresh (via plugin).
function requestMixes() {
  if (!ws) return;
  ws.send(JSON.stringify({ event: "getGlobalSettings", context: piUUID }));
  ws.send(JSON.stringify({
    event: "sendToPlugin", action: actionUUID, context: piUUID,
    payload: { t: "listMixes" }
  }));
}

// Ask the plugin for the live hardware-output list (served as {t:"outputs"}).
function requestOutputs() {
  if (!ws) return;
  ws.send(JSON.stringify({
    event: "sendToPlugin", action: actionUUID, context: piUUID,
    payload: { t: "listOutputs" }
  }));
}

// Populate a <select> with outputs; preserves the current binding even if offline.
// `key` is the settings field the selection writes to (e.g. "a" or "b").
function fillOutputDropdown(selectEl, outputs, key, { allowNone = false } = {}) {
  const current = settings[key];
  selectEl.innerHTML = "";
  if (allowNone) {
    const opt = document.createElement("option");
    opt.value = ""; opt.textContent = "(none)";
    selectEl.appendChild(opt);
  }
  if (!outputs.length && !allowNone) {
    const opt = document.createElement("option");
    opt.value = ""; opt.textContent = "BAM offline";
    selectEl.appendChild(opt);
  }
  let found = false;
  for (const o of outputs) {
    const opt = document.createElement("option");
    opt.value = o.uid;
    opt.textContent = o.name + (o.active ? " ●" : "");
    if (o.uid === current) { opt.selected = true; found = true; }
    selectEl.appendChild(opt);
  }
  if (current && !found) {
    const opt = document.createElement("option");
    opt.value = current; opt.textContent = "(unplugged)"; opt.selected = true;
    selectEl.appendChild(opt);
  }
}

// Populate a <select> with mixes; preserves the current binding even if offline.
// The Default catch-all ("mix-default") is listed last; when nothing is bound
// yet the first real device is selected and persisted.
const DEFAULT_MIX_ID = "mix-default";

function fillMixDropdown(selectEl, mixes) {
  const current = settings.mix;
  const ordered = mixes
    .slice()
    .sort((a, b) => (a.id === DEFAULT_MIX_ID) - (b.id === DEFAULT_MIX_ID));
  selectEl.innerHTML = "";
  if (!ordered.length) {
    const opt = document.createElement("option");
    opt.value = ""; opt.textContent = "BAM offline";
    selectEl.appendChild(opt);
  }
  let found = false;
  for (const m of ordered) {
    const opt = document.createElement("option");
    opt.value = m.id;
    opt.textContent = (m.emoji ? m.emoji + " " : "") + m.name;
    if (m.id === current) { opt.selected = true; found = true; }
    selectEl.appendChild(opt);
  }
  if (current && !found) {
    const opt = document.createElement("option");
    opt.value = current; opt.textContent = "(removed)"; opt.selected = true;
    selectEl.appendChild(opt);
  }
  if (!current && ordered.length) {
    selectEl.value = ordered[0].id;
    setSetting("mix", ordered[0].id);
  }
}
