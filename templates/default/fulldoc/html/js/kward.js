const resetScrollPosition = () => {
  if (window.location.hash) return

  document.documentElement.scrollTop = 0
  document.body.scrollTop = 0
  window.scrollTo(0, 0)

  const main = document.getElementById('main')
  if (main) {
    main.scrollTop = 0
    main.scrollLeft = 0
  }
}

if (!window.location.hash && 'scrollRestoration' in history) {
  history.scrollRestoration = 'manual'
}

resetScrollPosition()
window.addEventListener('load', resetScrollPosition)
window.addEventListener('pageshow', resetScrollPosition)
window.addEventListener('DOMContentLoaded', resetScrollPosition)
window.setTimeout(resetScrollPosition, 0)
window.setTimeout(resetScrollPosition, 50)
window.setTimeout(resetScrollPosition, 250)
window.requestAnimationFrame(resetScrollPosition)

document.addEventListener('DOMContentLoaded', () => {
  resetScrollPosition()

  const toggle = document.querySelector('.kward-nav-toggle')

  if (toggle) {
    toggle.addEventListener('click', () => {
      const isOpen = document.body.classList.toggle('kward-nav-open')
      toggle.setAttribute('aria-expanded', String(isOpen))
    })
  }

  document.querySelectorAll('.kward-nav-menu-button').forEach((button) => {
    button.addEventListener('click', (event) => {
      event.stopPropagation()
      button.parentElement.classList.toggle('open')
    })
  })

  document.addEventListener('click', (event) => {
    document.querySelectorAll('.kward-nav-menu.open').forEach((menu) => {
      if (!menu.contains(event.target)) menu.classList.remove('open')
    })
  })

  const guideLinks = {
    'doc/getting-started.md': 'file.getting-started.html',
    'doc/usage.md': 'file.usage.html',
    'doc/configuration.md': 'file.configuration.html',
    'doc/authentication.md': 'file.authentication.html',
    'doc/troubleshooting.md': 'file.troubleshooting.html',
    'doc/memory.md': 'file.memory.html',
    'doc/extensibility.md': 'file.extensibility.html',
    'doc/plugins.md': 'file.plugins.html',
    'doc/web-search.md': 'file.web-search.html',
    'doc/code-search.md': 'file.code-search.html',
    'doc/rpc.md': 'file.rpc.html',
    'doc/releasing.md': 'file.releasing.html'
  }

  document.querySelectorAll('#filecontents a[href]').forEach((link) => {
    const target = guideLinks[link.getAttribute('href')]
    if (target) link.setAttribute('href', target)
  })

  document.querySelectorAll('pre').forEach((block) => {
    const code = block.querySelector('code')
    if (!code || !navigator.clipboard) return

    const wrapper = document.createElement('div')
    wrapper.className = 'code-copy-wrapper'
    block.parentNode.insertBefore(wrapper, block)
    wrapper.appendChild(block)

    const button = document.createElement('button')
    button.className = 'copy-code-button'
    button.type = 'button'
    button.textContent = 'Copy'

    button.addEventListener('click', async () => {
      await navigator.clipboard.writeText(code.textContent || '')
      button.textContent = 'Copied'
      window.setTimeout(() => {
        button.textContent = 'Copy'
      }, 1200)
    })

    wrapper.appendChild(button)
  })
})
