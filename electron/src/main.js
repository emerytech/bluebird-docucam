'use strict'
const {
  app, BrowserWindow, Menu, Tray, ipcMain, shell, dialog,
  nativeImage, session, systemPreferences,
} = require('electron')
const path = require('path')
const fs = require('fs')
const https = require('https')

const APP_NAME = 'BlueBird DocuCam'
const REPO_URL = 'https://github.com/emerytech/bluebird-docucam'
const RELEASES_URL = REPO_URL + '/releases/latest'
const KOFI_URL = 'https://ko-fi.com/ets3d'
const LATEST_API = 'https://api.github.com/repos/emerytech/bluebird-docucam/releases/latest'
const ICON = path.join(__dirname, 'icon.png')   // packaged copy (src/ is in the files glob)

// ── Settings store (JSON in userData) ──────────────────────────────────────────
const SETTINGS_PATH = path.join(app.getPath('userData'), 'settings.json')
let settings = {}
try { settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8')) } catch { settings = {} }
function saveSettings() { try { fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings)) } catch {} }
function getSetting(k, d) { return settings[k] === undefined ? d : settings[k] }
function setSetting(k, v) { settings[k] = v; saveSettings() }

let mainWindow = null
let aboutWindow = null
let settingsWindow = null
let tray = null
let isQuitting = false

// Camera list is discovered in the renderer (getUserMedia) and reported up here so
// the native Camera menu can list devices.
let cameraList = []       // [{ deviceId, label }]
let activeCameraId = null

function icon() { return nativeImage.createFromPath(ICON) }
function send(cmd, arg) {
  if (mainWindow && !mainWindow.isDestroyed() && !mainWindow.webContents.isDestroyed()) {
    mainWindow.webContents.send('command', cmd, arg)
  }
}
// Single-key accelerators (Space/R/H/V/F/F11) must only drive the main viewer when it
// is the focused window — otherwise they fire while About/Settings is focused.
function mainFocused() { return !!mainWindow && BrowserWindow.getFocusedWindow() === mainWindow }
function sendMain(cmd, arg) { if (mainFocused()) send(cmd, arg) }

// ── Main window ────────────────────────────────────────────────────────────────
function createMainWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    backgroundColor: '#000000',
    title: APP_NAME,
    icon: icon(),
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  })
  mainWindow.loadFile(path.join(__dirname, 'index.html'))
  mainWindow.once('ready-to-show', () => {
    mainWindow.show()
    if (getSetting('startFullScreen', false)) mainWindow.setFullScreen(true)
  })
  mainWindow.on('enter-full-screen', () => send('fullscreen', true))
  mainWindow.on('leave-full-screen', () => send('fullscreen', false))
  mainWindow.on('closed', () => { mainWindow = null })
}

function showMainWindow() {
  if (!mainWindow) createMainWindow()
  else { if (mainWindow.isMinimized()) mainWindow.restore(); mainWindow.show(); mainWindow.focus() }
}

function toggleFullScreen() {
  showMainWindow()
  if (mainWindow) mainWindow.setFullScreen(!mainWindow.isFullScreen())
}

// ── Native application menu (also provides the keyboard shortcuts) ──────────────
function buildMenu() {
  const cameraItems = cameraList.length
    ? cameraList.map((c, i) => ({
        label: c.label || `Camera ${i + 1}`,
        type: 'checkbox',
        checked: c.deviceId === activeCameraId,
        accelerator: i < 9 ? `CmdOrCtrl+${i + 1}` : undefined,
        click: () => sendMain('select-camera', c.deviceId),
      }))
    : [{ label: 'No cameras found', enabled: false }]

  const template = [
    {
      label: APP_NAME,
      submenu: [
        { label: `About ${APP_NAME}`, click: showAbout },
        { label: 'Check for Updates…', click: () => checkForUpdates(true) },
        { label: 'Support the Developer…', click: () => shell.openExternal(KOFI_URL) },
        { type: 'separator' },
        { label: 'Settings…', accelerator: 'CmdOrCtrl+,', click: showSettings },
        { type: 'separator' },
        { role: 'quit', label: `Quit ${APP_NAME}` },
      ],
    },
    {
      label: 'Camera',
      submenu: [
        ...cameraItems,
        { type: 'separator' },
        { label: 'Refresh Cameras', accelerator: 'CmdOrCtrl+R', click: () => sendMain('refresh-cameras') },
      ],
    },
    {
      label: 'View',
      submenu: [
        { label: 'Freeze / Go Live', accelerator: 'Space', click: () => sendMain('freeze-toggle') },
        { label: 'Rotate', accelerator: 'R', click: () => sendMain('rotate') },
        { label: 'Flip Horizontal', accelerator: 'H', click: () => sendMain('flip-h') },
        { label: 'Flip Vertical', accelerator: 'V', click: () => sendMain('flip-v') },
        { label: 'Fill Screen', accelerator: 'F', click: () => sendMain('fill-toggle') },
        { type: 'separator' },
        { label: 'Full Screen', accelerator: 'F11', click: () => { if (mainFocused()) toggleFullScreen() } },
      ],
    },
    {
      label: 'Help',
      submenu: [
        { label: 'View on GitHub', click: () => shell.openExternal(REPO_URL) },
        { label: 'Support on Ko‑fi', click: () => shell.openExternal(KOFI_URL) },
      ],
    },
  ]
  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}

// ── Tray (parity with the macOS menu-bar item) ─────────────────────────────────
function buildTray() {
  try {
    const img = icon().resize({ width: 18, height: 18 })
    tray = new Tray(img)
    tray.setToolTip(APP_NAME)
  } catch { return }
  const menu = Menu.buildFromTemplate([
    { label: `Open ${APP_NAME}`, click: showMainWindow },
    { type: 'separator' },
    { label: 'Freeze / Go Live', click: () => { showMainWindow(); send('freeze-toggle') } },
    { label: 'Full Screen', click: toggleFullScreen },
    { type: 'separator' },
    { label: 'Settings…', click: showSettings },
    { label: `About ${APP_NAME}`, click: showAbout },
    { label: 'Check for Updates…', click: () => checkForUpdates(true) },
    { label: 'Support the Developer…', click: () => shell.openExternal(KOFI_URL) },
    { type: 'separator' },
    { label: `Quit ${APP_NAME}`, click: () => { isQuitting = true; app.quit() } },
  ])
  tray.setContextMenu(menu)
  tray.on('click', showMainWindow)
}

// ── About / Settings child windows ─────────────────────────────────────────────
function childWindow(file, w, h) {
  const win = new BrowserWindow({
    width: w, height: h,
    resizable: false, minimizable: false, maximizable: false,
    fullscreenable: false, title: '', icon: icon(),
    backgroundColor: '#1c1c1e', show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true, nodeIntegration: false,
    },
  })
  win.setMenuBarVisibility(false)
  win.loadFile(path.join(__dirname, file))
  win.once('ready-to-show', () => win.show())
  return win
}

function showAbout() {
  if (aboutWindow) { aboutWindow.show(); aboutWindow.focus(); return }
  aboutWindow = childWindow('about.html', 380, 470)
  aboutWindow.on('closed', () => { aboutWindow = null })
}

function showSettings() {
  if (settingsWindow) { settingsWindow.show(); settingsWindow.focus(); return }
  settingsWindow = childWindow('settings.html', 460, 340)
  settingsWindow.on('closed', () => { settingsWindow = null })
}

// ── Check for updates (GitHub latest release) ──────────────────────────────────
function versionIsNewer(a, b) {
  const x = a.split('.').map(n => parseInt(n, 10) || 0)
  const y = b.split('.').map(n => parseInt(n, 10) || 0)
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const xi = x[i] || 0, yi = y[i] || 0
    if (xi !== yi) return xi > yi
  }
  return false
}

function checkForUpdates(userInitiated) {
  const req = https.request(LATEST_API, {
    headers: { 'User-Agent': 'BlueBird-DocuCam', Accept: 'application/vnd.github+json' },
    timeout: 10000,
  }, (res) => {
    let body = ''
    res.on('data', d => { body += d })
    res.on('end', () => {
      let tag
      try { tag = JSON.parse(body).tag_name } catch {}
      if (!tag) { if (userInitiated) info('Couldn’t check for updates', 'Please try again later.'); return }
      const latest = tag.startsWith('v') ? tag.slice(1) : tag
      if (versionIsNewer(latest, app.getVersion())) {
        dialog.showMessageBox({
          type: 'info', icon: icon(),
          message: 'Update available',
          detail: `${APP_NAME} ${latest} is available. You have ${app.getVersion()}.`,
          buttons: ['Download', 'Later'], defaultId: 0, cancelId: 1,
        }).then(r => { if (r.response === 0) shell.openExternal(RELEASES_URL) })
      } else if (userInitiated) {
        info('You’re up to date', `${APP_NAME} ${app.getVersion()} is the latest version.`)
      }
    })
  })
  req.on('error', () => { if (userInitiated) info('Couldn’t check for updates', 'Please try again later.') })
  req.on('timeout', () => req.destroy(new Error('timeout')))   // pass an error so 'error' fires
  req.end()
}

function info(message, detail) {
  dialog.showMessageBox({ type: 'info', icon: icon(), message, detail, buttons: ['OK'] })
}

// ── IPC ────────────────────────────────────────────────────────────────────────
ipcMain.handle('settings:all', () => settings)
ipcMain.handle('settings:set', (_e, k, v) => {
  setSetting(k, v)
  if (k === 'hidePointerFullScreen') send('setting-hidepointer', v)   // apply live in the viewer
  return true
})
ipcMain.handle('app:info', () => ({
  name: APP_NAME, version: app.getVersion(), copyright: '© 2026 Taylor Emery — ETS3D LLC',
  repoURL: REPO_URL, kofiURL: KOFI_URL, platform: process.platform,
}))
ipcMain.handle('login-item:get', () => {
  try { return app.getLoginItemSettings().openAtLogin } catch { return false }
})
ipcMain.handle('login-item:set', (_e, on) => {
  try { app.setLoginItemSettings({ openAtLogin: !!on }); return app.getLoginItemSettings().openAtLogin }
  catch { return false }
})
ipcMain.on('cameras:list', (_e, list) => { cameraList = Array.isArray(list) ? list : []; buildMenu() })
ipcMain.on('cameras:active', (_e, id) => { activeCameraId = id; buildMenu() })
ipcMain.handle('cameras:get', () => ({ list: cameraList, active: activeCameraId }))
ipcMain.on('open-external', (_e, url) => {
  if (typeof url === 'string' && /^https:\/\//.test(url)) shell.openExternal(url)
})
ipcMain.on('check-updates', () => checkForUpdates(true))
ipcMain.on('select-camera', (_e, id) => send('select-camera', id))

// ── Lifecycle ────────────────────────────────────────────────────────────────
const gotLock = app.requestSingleInstanceLock()
if (!gotLock) {
  app.quit()
} else {
  app.on('second-instance', showMainWindow)

  app.whenReady().then(async () => {
    // Grant camera only to our own local pages; deny everything else.
    session.defaultSession.setPermissionRequestHandler((wc, permission, cb) => {
      const url = wc && wc.getURL ? wc.getURL() : ''
      cb(permission === 'media' && url.startsWith('file://'))
    })
    // Block new-window and off-app navigation everywhere.
    app.on('web-contents-created', (_e, contents) => {
      contents.setWindowOpenHandler(() => ({ action: 'deny' }))
      contents.on('will-navigate', (e, url) => { if (!url.startsWith('file://')) e.preventDefault() })
    })
    if (process.platform === 'darwin') {
      try { await systemPreferences.askForMediaAccess('camera') } catch {}
    }
    createMainWindow()
    buildMenu()
    buildTray()
  })

  // Keep running in the tray after the window is closed (parity with the mac menu-bar app),
  // but if there is no tray (headless Linux, or tray init failed) don't become an invisible
  // zombie with no quit path — quit instead.
  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin' && !tray) app.quit()
  })
  app.on('activate', showMainWindow)
  app.on('before-quit', () => { isQuitting = true })
}
