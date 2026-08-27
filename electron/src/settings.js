'use strict'

async function render() {
  const s = await window.api.getSettings()
  const info = await window.api.appInfo()
  const { list, active } = await window.api.getCameras()

  // Electron's login-item API is a no-op on Linux — hide the row there.
  if (info.platform === 'linux') {
    const row = document.getElementById('login').closest('.row')
    if (row) row.style.display = 'none'
  }

  const sel = document.getElementById('camera')
  sel.innerHTML = ''
  if (!list.length) {
    const o = document.createElement('option')
    o.textContent = 'No cameras found'
    sel.appendChild(o); sel.disabled = true
  } else {
    sel.disabled = false
    list.forEach((c, i) => {
      const o = document.createElement('option')
      o.value = c.deviceId
      o.textContent = c.label || ('Camera ' + (i + 1))
      if (c.deviceId === active) o.selected = true
      sel.appendChild(o)
    })
    sel.onchange = () => window.api.selectCamera(sel.value)
  }

  const login = document.getElementById('login')
  login.checked = await window.api.getLoginItem()
  login.onchange = async () => { login.checked = await window.api.setLoginItem(login.checked) }

  const startfs = document.getElementById('startfs')
  startfs.checked = !!s.startFullScreen
  startfs.onchange = () => window.api.setSetting('startFullScreen', startfs.checked)

  const hideptr = document.getElementById('hideptr')
  hideptr.checked = s.hidePointerFullScreen !== false
  hideptr.onchange = () => window.api.setSetting('hidePointerFullScreen', hideptr.checked)
}

render()
