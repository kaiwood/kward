(() => {
const guideLinks = {
  'doc/getting-started.md': 'file.getting-started.html',
  'doc/usage.md': 'file.usage.html',
  'doc/configuration.md': 'file.configuration.html',
  'doc/authentication.md': 'file.authentication.html',
  'doc/troubleshooting.md': 'file.troubleshooting.html',
  'doc/session-management.md': 'file.session-management.html',
  'doc/memory.md': 'file.memory.html',
  'doc/personas.md': 'file.personas.html',
  'doc/skills.md': 'file.skills.html',
  'doc/extensibility.md': 'file.extensibility.html',
  'doc/plugins.md': 'file.plugins.html',
  'doc/lifecycle-hooks.md': 'file.lifecycle-hooks.html',
  'doc/agent-tools.md': 'file.agent-tools.html',
  'doc/workspace-tools.md': 'file.workspace-tools.html',
  'doc/web-search.md': 'file.web-search.html',
  'doc/code-search.md': 'file.code-search.html',
  'doc/context-tools.md': 'file.context-tools.html',
  'doc/rpc.md': 'file.rpc.html',
  'doc/releasing.md': 'file.releasing.html'
}

let pageController = null
let navigating = false

const scrollToCurrentHash = () => {
  if (!window.location.hash) {
    window.scrollTo({ top: 0 })
    return
  }

  const id = decodeURIComponent(window.location.hash.slice(1))
  const target = document.getElementById(id) || document.getElementsByName(id)[0]
  if (target) target.scrollIntoView()
}

const replacePage = async (url, pushState = true) => {
  if (navigating) return
  navigating = true
  document.documentElement.classList.add('kward-navigating')

  try {
    const response = await fetch(url, { headers: { 'X-Requested-With': 'Kward-Docs' } })
    if (!response.ok) throw new Error(`Navigation failed with ${response.status}`)

    const html = await response.text()
    const nextDocument = new DOMParser().parseFromString(html, 'text/html')
    if (!nextDocument.body) throw new Error('Navigation response did not include a body')

    document.title = nextDocument.title
    document.body.className = nextDocument.body.className
    document.body.innerHTML = nextDocument.body.innerHTML

    if (pushState) window.history.pushState({ kwardDocs: true }, '', url)
    initializePage()
    scrollToCurrentHash()
  } catch (_error) {
    window.location.href = url
  } finally {
    navigating = false
    document.documentElement.classList.remove('kward-navigating')
  }
}

const isNavigableLink = (event, link) => {
  if (event.defaultPrevented || event.button !== 0) return false
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return false
  if (link.target && link.target !== '_self') return false
  if (link.download || link.dataset.noTurbo) return false

  const url = new URL(link.href, window.location.href)
  if (url.origin !== window.location.origin) return false
  if (url.pathname === window.location.pathname && url.search === window.location.search) return false

  return url.pathname === '/' || url.pathname.endsWith('/') || url.pathname.endsWith('.html')
}

const visitLink = (link) => replacePage(link.href)

const setupTurbolinks = (signal) => {
  document.addEventListener('click', (event) => {
    const link = event.target.closest('a[href]')
    if (!link || !isNavigableLink(event, link)) return

    event.preventDefault()
    visitLink(link)
  }, { signal })

  window.addEventListener('popstate', () => {
    replacePage(window.location.href, false)
  }, { signal })
}

const setupGuideSearch = (signal) => {
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

  let selectedIndex = -1

  const closeResults = () => {
    results.classList.remove('open')
    results.innerHTML = ''
    selectedIndex = -1
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

  const updateActiveItem = () => {
    const items = results.querySelectorAll('a')
    items.forEach((item, i) => {
      if (i === selectedIndex) {
        item.classList.add('kward-search-active')
        item.scrollIntoView({ block: 'nearest' })
      } else {
        item.classList.remove('kward-search-active')
      }
    })
  }

  const renderResults = () => {
    const query = input.value.trim()
    if (query.length < 2) {
      closeResults()
      return
    }

    const matches = search(query)
    results.innerHTML = ''
    selectedIndex = -1

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
      summary.textContent = excerpt(item.text || '', query)
      link.appendChild(summary)

      results.appendChild(link)
    })

    results.classList.add('open')
  }

  input.addEventListener('input', renderResults, { signal })

  input.addEventListener('keydown', (event) => {
    const items = results.querySelectorAll('a')

    if (event.key === 'Escape') {
      input.value = ''
      closeResults()
      input.blur()
      return
    }

    if (items.length === 0) return

    if (event.key === 'ArrowDown') {
      event.preventDefault()
      selectedIndex = Math.min(selectedIndex + 1, items.length - 1)
      updateActiveItem()
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      selectedIndex = Math.max(selectedIndex - 1, 0)
      updateActiveItem()
    } else if (event.key === 'Enter') {
      if (selectedIndex >= 0 && items[selectedIndex]) {
        event.preventDefault()
        visitLink(items[selectedIndex])
      }
    }
  }, { signal })

  form.addEventListener('submit', (event) => {
    event.preventDefault()
    const firstResult = results.querySelector('a')
    if (firstResult) visitLink(firstResult)
  }, { signal })

  document.addEventListener('click', (event) => {
    if (!form.contains(event.target)) closeResults()
  }, { signal })
}

const setupNavigation = (signal) => {
  const toggle = document.querySelector('.kward-nav-toggle')
  const nav = document.getElementById('kward-primary-nav')

  const closeMenu = () => {
    document.body.classList.remove('kward-nav-open')
    if (toggle) toggle.setAttribute('aria-expanded', 'false')
    document.querySelectorAll('.kward-nav-menu.open').forEach((menu) => {
      menu.classList.remove('open')
      const btn = menu.querySelector('.kward-nav-menu-button')
      if (btn) btn.setAttribute('aria-expanded', 'false')
    })
  }

  if (toggle) {
    // The inline onclick handles the toggle. We only need to close
    // sub-menus when the main menu closes.
    toggle.addEventListener('click', () => {
      if (!document.body.classList.contains('kward-nav-open')) {
        document.querySelectorAll('.kward-nav-menu.open').forEach((menu) => {
          menu.classList.remove('open')
          const btn = menu.querySelector('.kward-nav-menu-button')
          if (btn) btn.setAttribute('aria-expanded', 'false')
        })
      }
    }, { signal })
  }

  document.querySelectorAll('.kward-nav-menu-button').forEach((button) => {
    button.addEventListener('click', (event) => {
      event.stopPropagation()
      const menu = button.parentElement
      const wasOpen = menu.classList.contains('open')
      document.querySelectorAll('.kward-nav-menu.open').forEach((m) => {
        m.classList.remove('open')
        const b = m.querySelector('.kward-nav-menu-button')
        if (b) b.setAttribute('aria-expanded', 'false')
      })
      if (!wasOpen) {
        menu.classList.add('open')
        button.setAttribute('aria-expanded', 'true')
      }
    }, { signal })
  })

  // Close menu when a nav link is clicked (mobile navigation)
  if (nav) {
    nav.addEventListener('click', (event) => {
      const link = event.target.closest('a[href]')
      if (link) closeMenu()
    }, { signal })
  }

  // Close on outside click
  document.addEventListener('click', (event) => {
    if (document.body.classList.contains('kward-nav-open')) {
      if (nav && !nav.contains(event.target) && toggle && !toggle.contains(event.target)) {
        closeMenu()
      }
    }
    document.querySelectorAll('.kward-nav-menu.open').forEach((menu) => {
      if (!menu.contains(event.target)) {
        menu.classList.remove('open')
        const btn = menu.querySelector('.kward-nav-menu-button')
        if (btn) btn.setAttribute('aria-expanded', 'false')
      }
    })
  }, { signal })

  // Close on Escape
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && document.body.classList.contains('kward-nav-open')) {
      closeMenu()
      if (toggle) toggle.focus()
    }
  }, { signal })
}

const rewriteGuideLinks = () => {
  document.querySelectorAll('#filecontents a[href]').forEach((link) => {
    const target = guideLinks[link.getAttribute('href')]
    if (target) link.setAttribute('href', target)
  })
}

const setupTableOfContents = () => {
  const existingToc = document.getElementById('toc')
  if (document.querySelector('.kward-no-toc')) {
    if (existingToc) existingToc.remove()
    return
  }

  const fileContents = document.getElementById('filecontents')
  const content = document.getElementById('content')
  if (!fileContents || !content || content.querySelector('#toc')) return

  const headingTags = ['h2', 'h3', 'h4', 'h5', 'h6']
  if (fileContents.querySelectorAll('h1').length > 1) headingTags.unshift('h1')

  const headings = Array.from(fileContents.querySelectorAll(headingTags.join(', ')))
    .filter((heading) => !heading.closest('.method_details .docstring') && heading.id !== 'filecontents')
  if (headings.length === 0) return

  const topLevel = document.createElement('ol')
  topLevel.className = 'top'

  let currentList = topLevel
  let currentItem = null
  let counter = 0
  let lastLevel = parseInt(headingTags[0].slice(1), 10)

  headings.forEach((heading) => {
    const level = parseInt(heading.tagName.slice(1), 10)

    if (!heading.id) {
      let proposedId = heading.getAttribute('toc-id')
      if (!proposedId) {
        proposedId = heading.textContent.replace(/[^a-z0-9-]/gi, '_')
        if (document.getElementById(proposedId)) {
          proposedId += counter
          counter += 1
        }
      }
      heading.id = proposedId
    }

    if (level > lastLevel) {
      while (level > lastLevel) {
        if (!currentItem) {
          currentItem = document.createElement('li')
          currentList.appendChild(currentItem)
        }
        const nestedList = document.createElement('ol')
        currentItem.appendChild(nestedList)
        currentList = nestedList
        currentItem = null
        lastLevel += 1
      }
    } else if (level < lastLevel) {
      while (level < lastLevel && currentList.parentElement) {
        currentList = currentList.parentElement.parentElement
        lastLevel -= 1
      }
    }

    const title = heading.getAttribute('toc-title') || heading.textContent
    const item = document.createElement('li')
    const link = document.createElement('a')
    link.href = `#${heading.id}`
    link.textContent = title
    item.appendChild(link)
    currentList.appendChild(item)
    currentItem = item
  })

  const toc = document.createElement('div')
  toc.id = 'toc'
  toc.innerHTML = '<p class="title hide_toc"><a href="#"><strong>Table of Contents</strong></a></p>'
  toc.appendChild(topLevel)
  content.insertBefore(toc, content.firstChild)

  const hideLink = toc.querySelector('.hide_toc')
  hideLink.addEventListener('click', (event) => {
    event.preventDefault()
    const hidden = toc.classList.toggle('hidden')
    topLevel.style.display = hidden ? 'none' : ''
  })
}

const setupCodeCopy = () => {
  document.querySelectorAll('pre').forEach((block) => {
    if (block.closest('.code-copy-wrapper')) return

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
}

const initializePage = () => {
  if (pageController) pageController.abort()
  pageController = new AbortController()

  setupTurbolinks(pageController.signal)
  setupGuideSearch(pageController.signal)
  setupNavigation(pageController.signal)
  rewriteGuideLinks()
  setupTableOfContents()
  setupCodeCopy()
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initializePage, { once: true })
} else {
  initializePage()
}
})()
