'use strict'

const video = document.getElementById('video')
const freeze = document.getElementById('freeze')
const stage = document.getElementById('stage')
const message = document.getElementById('message')

const state = { rotation: 0, flipH: false, flipV: false, fill: false, frozen: false, deviceId: null }
let currentStream = null
let isFullscreen = false
let hidePointer = true
let manualSelection = false     // true once the user explicitly picks a camera
let knownDeviceIds = []
let idleTimer = null

function showMessage(t) {
  if (t) { message.textContent = t; message.classList.remove('hidden') }
  else message.classList.add('hidden')
}

// Heuristic: prefer an external (document) camera over the built-in webcam.
function isExternalLabel(label) {
  const l = (label || '').toLowerCase()
  return !(l.includes('facetime') || l.includes('built-in') || l.includes('builtin') ||
           l.includes('integrated') || l.includes('internal'))
}

async function listCameras() {
  const devices = await navigator.mediaDevices.enumerateDevices()
  return devices.filter(d => d.kind === 'videoinput').map(d => ({ deviceId: d.deviceId, label: d.label }))
}

// Acquire the NEW stream before stopping the old one, so a failed switch never drops
// the working camera. `interactive` = user-initiated switch (keep current on failure);
// otherwise (startup / auto) fall back to the default when a saved device is gone.
async function startCamera(deviceId, interactive) {
  const previousStream = currentStream
  const previousDeviceId = state.deviceId
  try {
    const constraints = { video: deviceId ? { deviceId: { exact: deviceId } } : true, audio: false }
    const stream = await navigator.mediaDevices.getUserMedia(constraints)
    if (previousStream) previousStream.getTracks().forEach(t => t.stop())
    currentStream = stream
    video.srcObject = stream
    const track = stream.getVideoTracks()[0]
    const s = track && track.getSettings ? track.getSettings() : {}
    state.deviceId = s.deviceId || deviceId || null
    window.api.setSetting('deviceId', state.deviceId)
    showMessage(null)
    const cams = await listCameras()
    knownDeviceIds = cams.map(c => c.deviceId)
    window.api.reportCameras(cams)
    window.api.reportActiveCamera(state.deviceId)
    applyTransform()
  } catch (e) {
    if (interactive && previousDeviceId) {
      // Keep the working camera; just report the transient failure.
      showMessage('That camera is unavailable — it may be in use by another app.')
      setTimeout(() => showMessage(null), 2500)
      return
    }
    if (deviceId) { await startCamera(null, false); return }   // saved device gone → default
    showMessage('Could not open the camera.\n\n' + (e && e.message ? e.message : '') +
      '\n\nCheck the camera privacy settings, then reopen — or plug in your document camera.')
  }
}

function applyTransform() {
  const cw = stage.clientWidth, ch = stage.clientHeight
  const swapped = state.rotation % 180 !== 0
  const fit = state.fill ? 'cover' : 'contain'
  for (const el of [video, freeze]) {
    el.style.objectFit = fit
    el.style.width = (swapped ? ch : cw) + 'px'
    el.style.height = (swapped ? cw : ch) + 'px'
    // Scale is applied in SCREEN space (after rotate) so flips are always
    // screen-horizontal / screen-vertical regardless of the rotation.
    el.style.transform =
      `translate(-50%, -50%) scaleX(${state.flipH ? -1 : 1}) scaleY(${state.flipV ? -1 : 1}) rotate(${state.rotation}deg)`
  }
  freeze.style.display = state.frozen ? 'block' : 'none'
}

function doFreeze() {
  if (state.frozen) { state.frozen = false; applyTransform(); return }
  const vw = video.videoWidth, vh = video.videoHeight
  if (!vw || !vh) return
  const c = document.createElement('canvas')
  c.width = vw; c.height = vh
  c.getContext('2d').drawImage(video, 0, 0, vw, vh)
  freeze.src = c.toDataURL('image/png')
  state.frozen = true
  applyTransform()
}

function resetIdle() {
  document.body.classList.remove('hide-cursor')
  clearTimeout(idleTimer)
  if (isFullscreen && hidePointer) {
    idleTimer = setTimeout(() => document.body.classList.add('hide-cursor'), 3000)
  }
}

function wireCommands() {
  window.api.onCommand(async (cmd, arg) => {
    switch (cmd) {
      case 'freeze-toggle': doFreeze(); break
      case 'rotate':
        state.rotation = (state.rotation + 90) % 360
        window.api.setSetting('rotation', state.rotation); applyTransform(); break
      case 'flip-h':
        state.flipH = !state.flipH; window.api.setSetting('flipH', state.flipH); applyTransform(); break
      case 'flip-v':
        state.flipV = !state.flipV; window.api.setSetting('flipV', state.flipV); applyTransform(); break
      case 'fill-toggle':
        state.fill = !state.fill; window.api.setSetting('fill', state.fill); applyTransform(); break
      case 'select-camera':
        manualSelection = true; await startCamera(arg, true); break
      case 'refresh-cameras': {
        const cams = await listCameras()
        knownDeviceIds = cams.map(c => c.deviceId)
        window.api.reportCameras(cams)
        if (!state.deviceId && cams[0]) await startCamera(cams[0].deviceId, false)
        break
      }
      case 'fullscreen': isFullscreen = !!arg; resetIdle(); break
      case 'setting-hidepointer': hidePointer = !!arg; resetIdle(); break
    }
  })
}

async function onDeviceChange() {
  const cams = await listCameras()
  window.api.reportCameras(cams)
  const prev = knownDeviceIds
  knownDeviceIds = cams.map(c => c.deviceId)

  // Active device unplugged → fall back to another camera.
  if (!cams.find(c => c.deviceId === state.deviceId)) {
    const next = cams.find(c => isExternalLabel(c.label)) || cams[0]
    if (next) await startCamera(next.deviceId, false)
    else showMessage('No camera found.\n\nPlug in your document camera — it will connect automatically.')
    return
  }
  // A new external doc-cam was just plugged in while we're on a built-in camera → switch to it
  // (unless the user has explicitly chosen the current camera).
  if (!manualSelection) {
    const currentLabel = (cams.find(c => c.deviceId === state.deviceId) || {}).label
    if (!isExternalLabel(currentLabel)) {
      const fresh = cams.find(c => isExternalLabel(c.label) && !prev.includes(c.deviceId))
      if (fresh) await startCamera(fresh.deviceId, false)
    }
  }
}

async function init() {
  // Register the command listener BEFORE any await so early main→renderer messages
  // (e.g. the fullscreen event on a start-fullscreen launch) aren't dropped.
  wireCommands()

  const s = await window.api.getSettings()
  state.rotation = s.rotation || 0
  state.flipH = !!s.flipH
  state.flipV = !!s.flipV
  state.fill = !!s.fill
  hidePointer = s.hidePointerFullScreen !== false

  const target = s.deviceId || null
  await startCamera(target, false)
  // First run (no saved device): prefer an external doc-cam once labels are available.
  if (!target) {
    const cams = await listCameras()
    const ext = cams.find(c => isExternalLabel(c.label))
    if (ext && ext.deviceId && ext.deviceId !== state.deviceId) await startCamera(ext.deviceId, false)
  }
  applyTransform()

  window.addEventListener('resize', applyTransform)
  window.addEventListener('mousemove', resetIdle)
  navigator.mediaDevices.addEventListener('devicechange', onDeviceChange)
}

init()
