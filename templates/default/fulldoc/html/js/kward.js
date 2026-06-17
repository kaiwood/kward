const resetScrollPosition = () => {
  if (window.location.hash) return

  document.documentElement.scrollTop = 0
  if (document.body) document.body.scrollTop = 0
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
if (window.requestAnimationFrame) window.requestAnimationFrame(resetScrollPosition)

const setupGuideSearch = () => {
  const form = document.querySelector('.kward-guide-search')
  const input = document.getElementById('kward-guide-search-input')
  const results = document.getElementById('kward-guide-search-results')
  const indexNode = document.getElementById('kward-guide-search-index')

  if (!form || !input || !results || !indexNode) return

  let index = []
  try {
    index = JSON.parse(indexNode.textContent || '[]')
  } catch (_error) {
    return
  }

  const closeResults = () => {
    results.classList.remove('open')
    results.innerHTML = ''
  }

  const excerpt = (text, query) => {
    const normalizedText = text.toLowerCase()
    const normalizedQuery = query.toLowerCase()
    const matchIndex = normalizedText.indexOf(normalizedQuery)
    const start = Math.max(0, matchIndex - 70)
    const end = Math.min(text.length, (matchIndex < 0 ? 0 : matchIndex) + normalizedQuery.length + 120)
    const prefix = start > 0 ? '…' : ''
    const suffix = end < text.length ? '…' : ''
    return `${prefix}${text.slice(start, end).trim()}${suffix}`
  }

  const search = (query) => {
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
    if (terms.length === 0) return []

    return index
      .map((item) => {
        const title = item.title || ''
        const path = item.path || ''
        const text = item.text || ''
        const haystack = `${title} ${path} ${text}`.toLowerCase()
        if (!terms.every((term) => haystack.includes(term))) return null

        const normalizedTitle = title.toLowerCase()
        const normalizedPath = path.toLowerCase()
        const titleMatches = terms.filter((term) => normalizedTitle.includes(term)).length
        const pathMatches = terms.filter((term) => normalizedPath.includes(term)).length
        return { item, score: titleMatches * 3 + pathMatches * 2 }
      })
      .filter(Boolean)
      .sort((left, right) => right.score - left.score || left.item.title.localeCompare(right.item.title))
      .slice(0, 6)
      .map((result) => result.item)
  }

  const renderResults = () => {
    const query = input.value.trim()
    if (query.length < 2) {
      closeResults()
      return
    }

    const matches = search(query)
    results.innerHTML = ''

    if (matches.length === 0) {
      const empty = document.createElement('div')
      empty.className = 'kward-guide-search-empty'
      empty.textContent = 'No guide results'
      results.appendChild(empty)
      results.classList.add('open')
      return
    }

    matches.forEach((item) => {
      const link = document.createElement('a')
      link.href = item.url
      link.setAttribute('role', 'option')

      const title = document.createElement('strong')
      title.textContent = item.title
      link.appendChild(title)

      const summary = document.createElement('span')
      summary.textContent = excerpt(item.text, query)
      link.appendChild(summary)

      results.appendChild(link)
    })

    results.classList.add('open')
  }

  input.addEventListener('input', renderResults)

  input.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      input.value = ''
      closeResults()
      input.blur()
    }
  })

  form.addEventListener('submit', (event) => {
    event.preventDefault()
    const firstResult = results.querySelector('a')
    if (firstResult) window.location.href = firstResult.href
  })

  document.addEventListener('click', (event) => {
    if (!form.contains(event.target)) closeResults()
  })
}

document.addEventListener('DOMContentLoaded', () => {
  resetScrollPosition()
  setupGuideSearch()

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
    'doc/personas.md': 'file.personas.html',
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
