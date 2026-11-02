// Privacy and Terms: English and Chinese live in the page; this shows one, sharing the home page's saved choice.
const articles = document.querySelectorAll('.legal')
const buttons = document.querySelectorAll('[data-lang]')

function show (lang) {
  articles.forEach(a => { a.hidden = a.dataset.lang !== lang })
  buttons.forEach(b => b.setAttribute('aria-pressed', String(b.dataset.lang === lang)))
  document.documentElement.lang = lang === 'zh' ? 'zh-Hans' : 'en'
  document.querySelectorAll('[data-zh]').forEach(a => {
    a.dataset.en ??= a.textContent
    a.textContent = lang === 'zh' ? a.dataset.zh : a.dataset.en
  })
  try { localStorage.setItem('qt-lang', lang) } catch (_) {}
}

buttons.forEach(b => b.addEventListener('click', () => show(b.dataset.lang)))
let saved = null
try { saved = localStorage.getItem('qt-lang') } catch (_) {}
show(saved || (navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en'))
