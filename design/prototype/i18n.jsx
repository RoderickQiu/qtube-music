// i18n: en-US (source strings) and zh-CN. Language follows the system unless the user picks one.
// Keys are the English strings; {name} placeholders are interpolated. Helper is tr() — `t` is the track elsewhere.

const QT_LOCALES = ["en-US", "zh-CN"];

const QT_STRINGS = {
  "zh-CN": {
    // navigation
    "Home": "首页", "Explore": "探索", "Library": "资料库", "Songs": "歌曲", "Albums": "专辑", "Artists": "艺人",
    "Liked Songs": "喜欢的音乐", "History": "最近播放", "Playlists": "歌单", "Playlist": "歌单",
    "Search music": "搜索音乐", "Back": "后退", "Forward": "前进", "Not in this prototype yet": "原型中暂未实现",
    // playlist view
    "{n} songs · {m} min": "{n} 首 · {m} 分钟", "Play": "播放", "Pause": "暂停", "Shuffle": "随机播放", "More": "更多",
    "Filter Liked Songs": "筛选喜欢的音乐", "Filter": "筛选", "Title": "标题", "Album": "专辑", "Time": "时长",
    "Not available in your region": "所在地区不可播放", "Word lyrics": "逐字歌词", "Jump to letter": "按字母跳转",
    "No songs match “{q}”.": "没有与“{q}”匹配的歌曲。",
    // context menu + toasts
    "Play Next": "下一首播放", "Add to Queue": "添加到播放队列", "Added to Up Next": "已添加到接下来播放",
    "Play Music Video": "播放 MV", "No Music Video": "暂无 MV", "Go to Album · {x}": "前往专辑 · {x}", "Go to Artist · {x}": "前往艺人 · {x}",
    "Add to Playlist": "添加到歌单", "Remove from Liked Songs": "从喜欢的音乐中移除", "Like": "喜欢", "Copy Link": "复制链接",
    "Link copied": "链接已复制", "“{x}” will play next": "“{x}”将在下一首播放", "Added to Liked Songs": "已添加到喜欢的音乐",
    "Removed from Liked Songs": "已从喜欢的音乐中移除", "Added “{x}” to {y}": "已将“{x}”添加到{y}", "Undo": "撤销",
    "Lyrics timing {x} s": "歌词偏移 {x} 秒", "No official music video for this song": "这首歌没有官方 MV",
    // panel + queue
    "Song": "歌曲", "Video": "视频", "Now Playing": "正在播放", "Queue": "播放队列", "Up Next": "接下来播放", "Clear": "清空",
    "Cleared Up Next": "已清空接下来播放", "Nothing queued": "队列为空", "Autoplay": "自动播放",
    "Hide panel": "隐藏面板", "Show panel": "显示面板", "Open Stage": "打开沉浸播放",
    // player bar + transport
    "Lyrics": "歌词", "AirPlay": "隔空播放", "Mini player": "迷你播放器", "Stage": "沉浸播放", "Previous": "上一首", "Next": "下一首",
    "Repeat": "循环播放", "Advertisement": "广告", "Then: {x}": "接下来：{x}", "Volume": "音量",
    // ad
    "Ad": "广告", "Skip": "跳过", "Skip in {n}": "{n} 秒后可跳过",
    // stage
    "Art + lyrics": "封面 + 歌词", "Art": "封面", "Blur": "模糊", "Cover": "封面", "Vinyl": "黑胶", "Visualizer": "可视化",
    "Appearance": "外观", "Premium": "Premium 专享", "Close": "关闭", "Close queue": "关闭播放队列", "Instrumental": "纯音乐",
    "Blurred artwork": "模糊封面", "Full-bleed cover": "全屏封面", "Music video": "MV", "Current": "当前",
    "Back to the current line": "回到当前歌词",
    // lyrics options
    "No lyrics": "暂无歌词", "Word timing": "逐字", "Line timing": "逐行", "Translation": "翻译", "Unofficial sources": "非官方歌词源",
    "NetEase, Kugou and QQ Music — unofficial, may stop working": "网易云音乐、酷狗和 QQ 音乐 — 非官方，可能失效",
    "Timing": "时间偏移", "Earlier": "提前", "Later": "延后", "Other versions": "其他版本", "Wrong lyrics": "歌词有误", "Reported": "已反馈",
    "Lyrics options": "歌词选项", "NetEase": "网易云音乐", "LRCLIB": "LRCLIB", "YouTube Music": "YouTube Music",
    // home
    "Good morning": "早上好", "Good afternoon": "下午好", "Good evening": "晚上好", "Good night": "夜深了",
    "Relax": "放松", "Energize": "活力", "Focus": "专注", "Commute": "通勤", "Romance": "浪漫", "Sleep": "睡眠", "Feel good": "好心情",
    "Listen again": "再次收听", "Quick picks": "为你精选", "Music videos": "MV", "Your playlists": "你的歌单",
    "Scroll left": "向左滚动", "Scroll right": "向右滚动", "Play {x}": "播放 {x}",
    // desktop
    "File": "文件", "Edit": "编辑", "Controls": "控制", "View": "显示", "Window": "窗口", "Help": "帮助",
    "Song ⇄ Music Video": "歌曲 ⇄ MV", "Mini Player": "迷你播放器", "Desktop Lyrics": "桌面歌词",
    "Lyrics Earlier": "歌词提前", "Lyrics Later": "歌词延后", "Double-click to switch size": "双击切换大小",
    // tweaks (designer panel)
    "Tweaks": "调整", "Surface": "界面", "Mini + menu bar": "迷你 + 菜单栏", "Stage layout": "沉浸布局", "Stage background": "沉浸背景",
    "Account": "账户", "Premium engine": "Premium 引擎", "Free (ads)": "免费（含广告）", "Play an ad now": "立即播放广告",
    "Window theme": "窗口主题", "Dark": "深色", "Light": "浅色", "Translation line": "翻译行", "On": "开", "Off": "关",
    "Language": "语言", "Auto": "自动", "Interface language": "界面语言", "Lyrics translation": "歌词翻译",
    "Translate to": "翻译为", "Song is already in {x}": "歌曲本身就是{x}", "Translating…": "正在翻译…",
    "Translation unavailable on this device": "此设备不支持该翻译", "On-device translation": "设备端机器翻译",
    "Translation by {x}": "翻译来自{x}", "Download {x} for offline translation": "下载{x}离线翻译模型",
  },
};

window.QT_LANG = "en-US";

function resolveLang(pref) {
  if (QT_LOCALES.includes(pref)) return pref;
  const sys = (navigator.languages?.[0] || navigator.language || "en-US").toLowerCase();
  return sys.startsWith("zh") ? "zh-CN" : "en-US";
}

function tr(s, vars) {
  const dict = QT_STRINGS[window.QT_LANG];
  let out = (dict && dict[s]) || s;
  if (vars) for (const [k, v] of Object.entries(vars)) out = out.split(`{${k}}`).join(v);
  return out;
}

// "Label  ⌥⌘N" style tooltips: translate the label, keep the shortcut.
const tk = (s, keys) => `${tr(s)}  ${keys}`;

const formatClock = (d = new Date()) =>
  new Intl.DateTimeFormat(window.QT_LANG, { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(d);

Object.assign(window, { QT_LOCALES, QT_STRINGS, resolveLang, tr, tk, formatClock });
