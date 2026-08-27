'use strict'

async function render() {
  const info = await window.api.appInfo()
  const settings = await window.api.getSettings()
  document.getElementById('name').textContent = info.name
  document.getElementById('version').textContent = 'Version ' + info.version
  document.getElementById('copyright').textContent = info.copyright

  const support = document.getElementById('support')
  support.innerHTML = ''
  if (settings.isSupporter) {
    const badge = document.createElement('div')
    badge.className = 'badge'
    badge.textContent = '💙  Supporter — thank you!'
    support.appendChild(badge)
  } else {
    const nudge = document.createElement('div')
    nudge.className = 'muted small nudge'
    nudge.textContent = 'Find DocuCam useful? Consider supporting the developer.'
    const kofi = document.createElement('button')
    kofi.className = 'kofi'
    kofi.textContent = '♥  Support on Ko‑fi'
    kofi.onclick = () => window.api.openExternal(info.kofiURL)
    const mark = document.createElement('div')
    const link = document.createElement('a')
    link.className = 'textlink'
    link.style.fontSize = '10.5px'
    link.textContent = 'I’ve already supported'
    link.onclick = async () => { await window.api.setSetting('isSupporter', true); render() }
    mark.style.marginTop = '8px'
    mark.appendChild(link)
    support.appendChild(nudge)
    support.appendChild(kofi)
    support.appendChild(mark)
  }

  document.getElementById('github').onclick = () => window.api.openExternal(info.repoURL)
  document.getElementById('updates').onclick = () => window.api.checkUpdates()
}

render()
