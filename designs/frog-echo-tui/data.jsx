/* 青蛙导航 · 回声终端 — 模拟书签数据
 * 数据结构对齐 plans/PLAN_MACOSAPP.md：
 * groups:    { id, name, order }
 * bookmarks: { id, title, url, groupId(null=根目录), order, createdAt }
 * 根目录书签与文件夹共享同一根排序序列；文件夹内书签各自有组内排序。
 * 图标由标题首字符和书签 ID 对应的传统色底板在本地生成。
 */

const FROG_SEED = {
  format: "frog-bookmarks",
  schemaVersion: 1,
  groups: [
    { id: "g-dev",    name: "开发工具", order: 3 },
    { id: "g-design", name: "设计灵感", order: 6 },
    { id: "g-read",   name: "资讯阅读", order: 9 },
    { id: "g-media",  name: "影音娱乐", order: 12 },
    { id: "g-life",   name: "生活服务", order: 15 }
  ],
  bookmarks: [
    // ---- 根目录独立书签 ----
    { id: "b-github",   title: "GitHub",       url: "https://github.com",       groupId: null,      order: 1,  createdAt: 1756000000000 },
    { id: "b-chatgpt",  title: "ChatGPT",      url: "https://chatgpt.com",      groupId: null,      order: 2,  createdAt: 1756000100000 },
    { id: "b-google",   title: "Google",       url: "https://www.google.com",   groupId: null,      order: 4,  createdAt: 1756000200000 },
    { id: "b-notion",   title: "Notion",       url: "https://www.notion.so",    groupId: null,      order: 5,  createdAt: 1756000300000   },
    { id: "b-youtube",  title: "YouTube",      url: "https://www.youtube.com",  groupId: null,      order: 7,  createdAt: 1756000400000   },
    { id: "b-figma",    title: "Figma",        url: "https://www.figma.com",    groupId: null,      order: 8,  createdAt: 1756000500000 },
    { id: "b-arxiv",    title: "arXiv",        url: "https://arxiv.org",        groupId: null,      order: 10, createdAt: 1756000600000 },
    { id: "b-hn",       title: "Hacker News",  url: "https://news.ycombinator.com", groupId: null,  order: 11, createdAt: 1756000700000  },
    { id: "b-cloudflare", title: "Cloudflare", url: "https://dash.cloudflare.com", groupId: null,   order: 13, createdAt: 1756000800000  },
    { id: "b-vercel",   title: "Vercel",       url: "https://vercel.com",       groupId: null,      order: 14, createdAt: 1756000900000 },
    { id: "b-kimi",     title: "Kimi",         url: "https://www.kimi.com",     groupId: null,      order: 16, createdAt: 1756001000000 },
    { id: "b-x",        title: "X",            url: "https://x.com",            groupId: null,      order: 17, createdAt: 1756001100000 },
    { id: "b-spotify",  title: "Spotify",      url: "https://open.spotify.com", groupId: null,      order: 18, createdAt: 1756001200000 },

    // ---- 开发工具 ----
    { id: "b-mdn",      title: "MDN Web Docs",    url: "https://developer.mozilla.org", groupId: "g-dev", order: 1, createdAt: 1756010000000 },
    { id: "b-so",       title: "Stack Overflow",  url: "https://stackoverflow.com",       groupId: "g-dev", order: 2, createdAt: 1756010100000  },
    { id: "b-tailwind", title: "Tailwind CSS",    url: "https://tailwindcss.com",         groupId: "g-dev", order: 3, createdAt: 1756010200000 },
    { id: "b-react",    title: "React 文档",       url: "https://react.dev",               groupId: "g-dev", order: 4, createdAt: 1756010300000 },
    { id: "b-swift",    title: "Swift 文档",       url: "https://developer.apple.com/documentation/swiftui", groupId: "g-dev", order: 5, createdAt: 1756010400000 },
    { id: "b-v2ex",     title: "V2EX",            url: "https://www.v2ex.com",            groupId: "g-dev", order: 6, createdAt: 1756010500000 },

    // ---- 设计灵感 ----
    { id: "b-dribbble", title: "Dribbble",        url: "https://dribbble.com",     groupId: "g-design", order: 1, createdAt: 1756020000000 },
    { id: "b-behance",  title: "Behance",         url: "https://www.behance.net",  groupId: "g-design", order: 2, createdAt: 1756020100000 },
    { id: "b-mobbin",   title: "Mobbin",          url: "https://mobbin.com",       groupId: "g-design", order: 3, createdAt: 1756020200000 },
    { id: "b-awwwards", title: "Awwwards",        url: "https://www.awwwards.com", groupId: "g-design", order: 4, createdAt: 1756020300000  },

    // ---- 资讯阅读 ----
    { id: "b-sspai",    title: "少数派",   url: "https://sspai.com",            groupId: "g-read", order: 1, createdAt: 1756030000000 },
    { id: "b-zhihu",    title: "知乎",     url: "https://www.zhihu.com",        groupId: "g-read", order: 2, createdAt: 1756030100000 },
    { id: "b-36kr",     title: "36氪",     url: "https://36kr.com",             groupId: "g-read", order: 3, createdAt: 1756030200000 },
    { id: "b-ruanyf",   title: "阮一峰的周刊", url: "https://www.ruanyifeng.com/blog/weekly/", groupId: "g-read", order: 4, createdAt: 1756030300000 },
    { id: "b-weibo",    title: "微博热搜", url: "https://s.weibo.com/top/summary", groupId: "g-read", order: 5, createdAt: 1756030400000 },

    // ---- 影音娱乐 ----
    { id: "b-bilibili", title: "哔哩哔哩", url: "https://www.bilibili.com",  groupId: "g-media", order: 1, createdAt: 1756040000000 },
    { id: "b-netease",  title: "网易云音乐", url: "https://music.163.com",   groupId: "g-media", order: 2, createdAt: 1756040100000   },
    { id: "b-douban",   title: "豆瓣",     url: "https://www.douban.com",    groupId: "g-media", order: 3, createdAt: 1756040200000 },
    { id: "b-youku",    title: "优酷",     url: "https://youku.com",         groupId: "g-media", order: 4, createdAt: 1756040300000 },

    // ---- 生活服务 ----
    { id: "b-taobao",   title: "淘宝",       url: "https://www.taobao.com",  groupId: "g-life", order: 1, createdAt: 1756050000000  },
    { id: "b-jd",       title: "京东",       url: "https://www.jd.com",      groupId: "g-life", order: 2, createdAt: 1756050100000 },
    { id: "b-meituan",  title: "美团",       url: "https://www.meituan.com", groupId: "g-life", order: 3, createdAt: 1756050200000  },
    { id: "b-amap",     title: "高德地图",   url: "https://www.amap.com",    groupId: "g-life", order: 4, createdAt: 1756050300000 },
    { id: "b-12306",    title: "铁路 12306", url: "https://www.12306.cn",    groupId: "g-life", order: 5, createdAt: 1756050400000 }
  ]
};

/* 生成隔离的内存数据副本，刷新后重置 */
function frogSeedData() {
  return JSON.parse(JSON.stringify(FROG_SEED));
}

function frogInitial(title) {
  const t = (title || "?").trim();
  return Array.from(t)[0].toUpperCase();
}

Object.assign(window, {
  FROG_SEED,
  frogSeedData,
  frogInitial
});
