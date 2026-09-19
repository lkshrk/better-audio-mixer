// Shared Property Inspector runtime on sdpi-components: settings persistence and plugin-fed dropdowns.

const client = SDPIComponents.streamDeckClient;
let controller = "Keypad";
let settings = {};
let onSettings = null;
let onReady = null;
let onMixes = null;
let onOutputs = null;

const DEFAULT_MIX_ID = "mix-default";

client.didReceiveSettings.subscribe((msg) => {
  const payload = msg.payload || {};
  controller = payload.controller || controller;
  settings = payload.settings || {};
  if (onSettings) onSettings(settings);
});
client.didReceiveGlobalSettings.subscribe((msg) => {
  const s = (msg.payload && msg.payload.settings) || {};
  if (onMixes) onMixes(s.mixes || []);
});
client.sendToPropertyInspector.subscribe((msg) => {
  const payload = msg.payload || {};
  if (payload.t === "mixes" && onMixes) onMixes(payload.mixes || []);
  if (payload.t === "outputs" && onOutputs) onOutputs(payload.outputs || []);
});
client.getConnectionInfo().then(() => { if (onReady) onReady(); });

// Writes through sdpi's settings store so bound components and manual fields never clobber each other.
function setSetting(key, value) {
  const [, save] = SDPIComponents.useSettings(key, null, null, true);
  save(value);
}

// Ask for both the cached list (globalSettings) and a live refresh (via plugin).
function requestMixes() {
  client.send("getGlobalSettings");
  client.send("sendToPlugin", { t: "listMixes" });
}

function requestOutputs() {
  client.send("sendToPlugin", { t: "listOutputs" });
}

function normalizeStyle(value) {
  if (value === "combined" || value === "slider") return "channel";
  if (value === "bars") return "meter";
  if (value === "radial") return "retro";
  return value;
}

function show(el, visible) {
  el.style.display = visible ? "" : "none";
}

// Live label while dragging; the component only commits its value on release.
function bindRange(rangeEl, labelEl, format, commit) {
  rangeEl.addEventListener("input", (e) => {
    labelEl.textContent = format(e.composedPath()[0].valueAsNumber);
  });
  rangeEl.addEventListener("valuechange", () => {
    labelEl.textContent = format(+rangeEl.value);
    commit(+rangeEl.value);
  });
}

// Device and Master share one PI; only the device dropdown differs.
function initVolumePI({ hasMix }) {
  const el = (id) => document.getElementById(id);
  const mixEl = hasMix ? el("mix") : null;
  const modeEl = el("mode");
  const stepEl = el("step");
  const stepVal = el("stepVal");
  const posEl = el("pos");
  const posVal = el("posVal");
  const fmtStep = (v) => (v > 0 ? "+" : "") + v + "%";
  const fmtPos = (v) => v + "%";
  const mode = () => modeEl.value || settings.mode || "mute";

  // Dial: positive rotate sensitivity + LCD style; key: rows follow the mode.
  function applyMode() {
    const isDial = controller === "Encoder";
    const m = mode();
    show(el("modeRow"), !isDial);
    show(el("dialHint"), !isDial);
    stepEl.min = isDial ? 1 : -25;
    if (isDial && +stepEl.value < 1) {
      stepEl.value = 5;
      setSetting("step", 0.05);
    }
    stepVal.textContent = fmtStep(+stepEl.value);
    show(el("stepRow"), isDial || m === "adjust");
    show(el("posRow"), !isDial && m === "set");
    show(el("styleRow"), isDial);
    show(el("keyStyleRow"), !isDial);
  }

  onSettings = (s) => {
    stepEl.value = Math.round((s.step ?? 0.05) * 100);
    posEl.value = Math.round((s.pos ?? 0.5) * 100);
    posVal.textContent = fmtPos(+posEl.value);
    for (const key of ["style", "keyStyle"]) {
      if (s[key] && normalizeStyle(s[key]) !== s[key]) setSetting(key, normalizeStyle(s[key]));
    }
    applyMode();
  };

  if (hasMix) {
    onMixes = (mixes) => fillMixDropdown(mixEl, mixes);
    onReady = requestMixes;
  }
  modeEl.addEventListener("valuechange", applyMode);
  bindRange(stepEl, stepVal, fmtStep, (v) => setSetting("step", v / 100));
  bindRange(posEl, posVal, fmtPos, (v) => setSetting("pos", Math.min(100, Math.max(0, v)) / 100));
}

// Dropdown emoji for the SF Symbol the app reports for a hardware output.
function outputEmoji(icon) {
  switch (icon) {
    case "headphones": return "🎧";
    case "display": return "🖥️";
    case "airplayaudio": return "📡";
    case "hifispeaker.fill": return "🔈";
    default: return "🔊"; // speaker.wave.2.fill + fallback
  }
}

function option(value, text) {
  const opt = document.createElement("option");
  opt.value = value;
  opt.textContent = text;
  return opt;
}

// Outputs into an <sdpi-select> bound to settings[key]; keeps an unplugged binding selectable.
function fillOutputDropdown(selectEl, outputs, key, { allowNone = false } = {}) {
  const current = settings[key];
  const options = [];
  if (allowNone) options.push(option("", "(none)"));
  if (!outputs.length && !allowNone) options.push(option("", "BAM offline"));
  for (const o of outputs) {
    options.push(option(o.uid, outputEmoji(o.icon) + " " + o.name + (o.active ? " ●" : "")));
  }
  if (current && !outputs.some((o) => o.uid === current)) options.push(option(current, "(unplugged)"));
  selectEl.replaceChildren(...options);
}

// Mixes into the device <sdpi-select>; Default last, removed binding kept selectable.
function fillMixDropdown(selectEl, mixes) {
  const current = settings.mix;
  const ordered = mixes
    .slice()
    .sort((a, b) => (a.id === DEFAULT_MIX_ID) - (b.id === DEFAULT_MIX_ID));
  const options = [];
  if (!ordered.length) options.push(option("", "BAM offline"));
  for (const m of ordered) options.push(option(m.id, (m.emoji ? m.emoji + " " : "") + m.name));
  if (current && !ordered.some((m) => m.id === current)) options.push(option(current, "(removed)"));
  selectEl.replaceChildren(...options);
  if (!current && ordered.length) selectEl.value = ordered[0].id;
}
