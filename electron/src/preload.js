'use strict'
const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('api', {
  getSettings: () => ipcRenderer.invoke('settings:all'),
  setSetting: (k, v) => ipcRenderer.invoke('settings:set', k, v),
  appInfo: () => ipcRenderer.invoke('app:info'),
  getLoginItem: () => ipcRenderer.invoke('login-item:get'),
  setLoginItem: (on) => ipcRenderer.invoke('login-item:set', on),
  reportCameras: (list) => ipcRenderer.send('cameras:list', list),
  reportActiveCamera: (id) => ipcRenderer.send('cameras:active', id),
  getCameras: () => ipcRenderer.invoke('cameras:get'),
  selectCamera: (id) => ipcRenderer.send('select-camera', id),
  openExternal: (url) => ipcRenderer.send('open-external', url),
  checkUpdates: () => ipcRenderer.send('check-updates'),
  onCommand: (cb) => ipcRenderer.on('command', (_e, cmd, arg) => cb(cmd, arg)),
})
