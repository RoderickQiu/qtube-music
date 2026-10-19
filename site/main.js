// QTube Music site: lyric lines that light up in turn (like the app), English/中文, install popover, "Why" dialog.

const zh = {
  subtitle: '为 YouTube Music 打造的原生 Mac 应用',
  l1: '歌词逐字亮起。',
  l2: '每一行下面都有翻译。',
  l3: '在歌曲和它的 MV 之间切换。',
  l4: '全屏播放器、迷你播放器、菜单栏播放器。',
  l5: '免费账号和 Premium 都能用。',
  l6: '空闲时 CPU 不到 1%。',
  l7: '只有音乐：没有 Shorts，没有播客，没有评论。',
  free: '免费',
  req: 'macOS 15 或更高版本<br>Apple 芯片与 Intel',
  download: '下载 QTube Music Mac 版',
  downloadLink: '下载 Mac 版',
  howTo: '如何安装',
  installTitle: '安装',
  s1: '打开磁盘映像，把 <b>QTube Music</b> 拖到<b>应用程序</b>。',
  s2: '应用还没有经过公证。第一次打开时点<b>完成</b>，然后前往<b>系统设置 › 隐私与安全性</b>，点<b>仍要打开</b>。',
  s3: '或者在终端里运行：',
  whyBtn: '为什么做它？',
  whyTitle: '为什么要做 QTube Music',
  whyLead: '灵感来自<b>网易云音乐</b>。它的播放页是我用过最好的：歌词一个字一个字地亮，下面跟着翻译；全屏播放有转动的黑胶唱片；还有桌面歌词。我想在 YouTube Music 上也用到这些，可 Mac 上的 YouTube Music 客户端，没有一个接近网易云。',
  w1t: 'YouTube Music 网页版',
  w1d: '根本没有 Mac 应用。资料库要一边滚一边加载，没法排序，也没法按字母跳转；播放队列很难找。歌词不能逐字，也没有翻译。',
  w5t: 'Electron 套壳应用',
  w5d: '比如 th-ch 的 YouTube Music：把网页版装进一个窗口，底下再跑一整份 Chrome。界面还是网页版那套，网页版缺的，它也都缺。',
  w2d: '没有全屏播放页。大多数歌的 MV 按钮是灰的，也没法在歌曲和 MV 之间切换。歌有时播完不切下一首，“正在播放”里会出现两个它，单击歌曲就直接播放，没法先选中。',
  w3d: '只有 Premium 账号能用。所谓的“歌曲/视频”切换只换了音轨，根本看不到画面。歌词只到逐行，没有翻译。每首歌都要单独起一个 yt-dlp 进程，所以没有无缝播放，YouTube 一改就可能坏。',
  w4d: '没有全屏播放页，也不能看 MV。它靠一个隐藏的 YouTube 播放器放歌，有些歌直接报错放不了。在我的 Mac 上，它暂停时 CPU 接近 100%，内存约 800 MB。窗口按钮在右边，是 Windows 的样子；⌘空格 搜索还和聚焦搜索冲突。',
  whyOurs: '<b>QTube Music</b> 把这些都做了：全屏播放页有五种背景；歌词逐字亮起，每行下面带翻译；能看真正的 MV，切换不丢进度；还有桌面歌词和迷你播放器。它用 SwiftUI 和 AppKit 写成，空闲时 CPU 不到 1%，免费账号也能用。',
  foot: '非官方客户端，与 Google 和 YouTube 无关。基于 MPL-2.0 <a href="https://github.com/RoderickQiu/qtube-music">开源</a>。由 <a href="https://r-q.name">Tianrun Qiu</a> 制作。'
}

// Remember the English text so switching back restores it.
const en = {}
document.querySelectorAll('[data-i18n]').forEach(el => { en[el.dataset.i18n] = el.textContent })
document.querySelectorAll('[data-i18n-html]').forEach(el => { en[el.dataset.i18nHtml] = el.innerHTML })
document.querySelectorAll('[data-i18n-aria]').forEach(el => { en[el.dataset.i18nAria] = el.getAttribute('aria-label') })

function setLanguage (lang) {
  const t = lang === 'zh' ? zh : en
  document.documentElement.lang = lang === 'zh' ? 'zh-Hans' : 'en'
  document.querySelectorAll('[data-i18n]').forEach(el => { if (t[el.dataset.i18n]) el.textContent = t[el.dataset.i18n] })
  document.querySelectorAll('[data-i18n-html]').forEach(el => { if (t[el.dataset.i18nHtml]) el.innerHTML = t[el.dataset.i18nHtml] })
  document.querySelectorAll('[data-i18n-aria]').forEach(el => { if (t[el.dataset.i18nAria]) el.setAttribute('aria-label', t[el.dataset.i18nAria]) })
  document.querySelectorAll('[data-lang]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.lang === lang)))
  try { localStorage.setItem('qt-lang', lang) } catch (_) {}
  layout()
}

// Lyrics: the current line stays at a fixed height in the view, the rest scroll past and blur with distance.
const view = document.querySelector('.lyrics-view')
const list = document.querySelector('[data-lyrics]')
const lines = [...list.children]
const fill = document.querySelector('[data-fill]')
const elapsed = document.querySelector('[data-elapsed]')
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches
let current = 0

function layout () {
  lines.forEach((li, i) => {
    li.classList.toggle('is-current', i === current)
    li.dataset.d = String(Math.min(4, Math.abs(i - current)))
  })
  const line = lines[current]
  const anchor = view.clientHeight * 0.38
  list.style.transform = `translateY(${Math.round(anchor - line.offsetTop - line.offsetHeight / 2)}px)`
  fill.style.width = `${12 + (current / (lines.length - 1)) * 80}%`
}

lines.forEach((li, i) => li.addEventListener('click', () => { current = i; layout(); restart() }))

let timer
function restart () {
  clearInterval(timer)
  if (!reduceMotion) timer = setInterval(() => { current = (current + 1) % lines.length; layout() }, 3200)
}

// The clock runs like a playing song, from 0:31.
let seconds = 31
setInterval(() => {
  seconds += 1
  elapsed.textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`
}, 1000)

// Install popover
const installButton = document.querySelector('[data-install]')
const popover = document.getElementById('install')
function setPopover (open) {
  popover.hidden = !open
  installButton.setAttribute('aria-expanded', String(open))
}
installButton.addEventListener('click', e => { e.stopPropagation(); setPopover(popover.hidden) })
document.addEventListener('click', e => { if (!popover.hidden && !popover.contains(e.target)) setPopover(false) })
document.addEventListener('keydown', e => { if (e.key === 'Escape') setPopover(false) })

// "Why QTube Music" dialog
const why = document.getElementById('why')
function openWhy () { document.documentElement.classList.add('is-locked'); why.showModal() }
why.addEventListener('close', () => document.documentElement.classList.remove('is-locked'))
document.querySelector('[data-why]').addEventListener('click', openWhy)
document.querySelector('[data-why-close]').addEventListener('click', () => why.close())
why.addEventListener('click', e => { if (e.target === why) why.close() })

document.querySelectorAll('[data-lang]').forEach(b => b.addEventListener('click', () => setLanguage(b.dataset.lang)))
addEventListener('resize', layout)

let saved = null
try { saved = localStorage.getItem('qt-lang') } catch (_) {}
setLanguage(saved || (navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en'))
if (location.hash === '#why') openWhy()
restart()
