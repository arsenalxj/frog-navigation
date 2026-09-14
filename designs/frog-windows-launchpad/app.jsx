/* 青蛙导航 Windows 启动台原型 — 核心应用
 * 交互依据 plans/PLAN_WINDOWS.md：
 * 无边框窗口铺满工作区、保留任务栏 / 顶部搜索 + 右侧设置与添加 /
 * 网格横向分页 / 单层文件夹面板 / 长按整理（抖动 + 删除角标）/
 * 拖拽排序、拖入文件夹、停留创建文件夹 / 右键菜单 /
 * Ctrl+Alt+Space 全局热键（可修改/冲突提示）/ 屏幕触角四角（默认关闭）/
 * 托盘菜单（展开/收起/设置/退出）/ 单实例与任务栏唤起 /
 * Esc 逐层退出 / Ctrl+N 添加 / Ctrl+, 设置 / Ctrl+F 或 / 搜索 /
 * 数据目录 %LOCALAPPDATA%\青蛙导航、备份恢复、登录启动（启动目录快捷方式）
 */

const { useState, useEffect, useRef, useCallback, useMemo } = React;

const LS_DATA = "frog-win-demo-v1";
const LS_PAGE = "frog-win-demo-page";
const LS_PREFS = "frog-win-demo-prefs";

const DEFAULT_HOTKEY = { enabled: true, ctrl: true, alt: true, shift: false, code: "Space", label: "Ctrl + Alt + Space" };
const DEFAULT_DIR = "%LOCALAPPDATA%\\青蛙导航\\Data";

/* ---------- 工具 ---------- */
function uid() {
  return "id-" + Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
}
function loadJSON(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch (e) { return fallback; }
}
function normalizeUrl(input) {
  let u = (input || "").trim();
  if (!u) return null;
  if (!/^https?:\/\//i.test(u)) {
    if (/^[\w-]+(\.[\w-]+)+(\/\S*)?$/.test(u)) u = "https://" + u;
    else return null;
  }
  try {
    const p = new URL(u);
    if (p.protocol !== "http:" && p.protocol !== "https:") return null;
    return p.href;
  } catch (e) { return null; }
}
function computeLayout(w, h) {
  const cols = Math.max(3, Math.min(8, Math.floor((w - 200) / 134)));
  const rows = Math.max(2, Math.min(4, Math.floor((h - 260) / 128)));
  return { cols, rows, cap: cols * rows };
}
function hotkeyLabel(h) {
  const parts = [];
  if (h.ctrl) parts.push("Ctrl");
  if (h.alt) parts.push("Alt");
  if (h.shift) parts.push("Shift");
  parts.push(h.label.split(" + ").pop());
  return parts.join(" + ");
}
/* 系统保留组合：演示冲突提示 */
function hotkeyConflict(h) {
  if (h.ctrl && !h.alt && !h.shift && h.code === "Space") return "与「输入法切换（Ctrl + Space）」冲突";
  if (!h.ctrl && h.alt && !h.shift && h.code === "Space") return "与「窗口系统菜单（Alt + Space）」冲突";
  if (h.ctrl && !h.alt && h.code === "Escape") return "与「开始菜单（Ctrl + Esc）」冲突";
  if (!h.ctrl && !h.alt && !h.shift) return "全局热键至少需要 Ctrl / Alt / Shift 之一";
  return null;
}

/* ---------- 小部件 ---------- */
function Toast({ toast }) {
  if (!toast) return null;
  return (
    <div className={"toast" + (toast.leaving ? " leaving" : "")} key={toast.key}>
      <IcCheck />
      <span>{toast.msg}{toast.url ? <span className="toast-url">　{toast.url}</span> : null}</span>
    </div>
  );
}

function IconTile({ bookmark, size }) {
  return (
    <div className="lp-icon" style={Object.assign({}, frogIconStyle(bookmark), size ? { width: size, height: size, fontSize: size * 0.4 } : {})}>
      {frogInitial(bookmark.title)}
    </div>
  );
}

/* ---------- 主应用 ---------- */
function App() {
  const prefs0 = loadJSON(LS_PREFS, {});
  const [appearance, setAppearance] = useState(prefs0.appearance || "dark");
  const [wallpaper, setWallpaper] = useState(prefs0.wallpaper || "bloom");
  const [launchAtLogin, setLaunchAtLogin] = useState(!!prefs0.launchAtLogin);
  const [dataDir, setDataDir] = useState(prefs0.dataDir || DEFAULT_DIR);
  const [hotkey, setHotkey] = useState(prefs0.hotkey || DEFAULT_HOTKEY);
  const [cornerOn, setCornerOn] = useState(!!prefs0.cornerOn);
  const [corners, setCorners] = useState(prefs0.corners || { tl: false, tr: false, bl: false, br: false });
  const [running, setRunning] = useState(false);      // 进程驻留（单实例）
  const [launched, setLaunched] = useState(false);    // 主界面展开
  const [data, setData] = useState(() => loadJSON(LS_DATA, null) || frogSeedData());
  const [page, setPage] = useState(() => parseInt(localStorage.getItem(LS_PAGE) || "0", 10) || 0);
  const [query, setQuery] = useState("");
  const [selIdx, setSelIdx] = useState(0);
  const [openFolder, setOpenFolder] = useState(null);
  const [folderPage, setFolderPage] = useState(0);
  const [editing, setEditing] = useState(false);
  const [modal, setModal] = useState(null); // {type:'add'|'edit'|'delete'|'deleteFolder'|'settings', ...}
  const [settingsTab, setSettingsTab] = useState("general");
  const [ctx, setCtx] = useState(null); // {x,y,kind:'bookmark'|'folder',id}
  const [trayMenu, setTrayMenu] = useState(false);
  const [toast, setToast] = useState(null);
  const [refreshing, setRefreshing] = useState({});
  const [renaming, setRenaming] = useState(null);
  const [renameVal, setRenameVal] = useState("");
  const [capturing, setCapturing] = useState(false);
  const [layout, setLayout] = useState(() => computeLayout(window.innerWidth, window.innerHeight));
  const [tweaksOpen, setTweaksOpen] = useState(false);
  const [clock, setClock] = useState(new Date());
  const [noWallpaper, setNoWallpaper] = useState(false);   // 模拟壁纸读取失败 → 回退系统主题背景
  const [zoom, setZoom] = useState(1);                      // 模拟 Windows 显示缩放
  const [reduceMotion, setReduceMotion] = useState(false);  // 模拟系统「减少动画」

  const dragRef = useRef(null);
  const [dropTarget, setDropTarget] = useState(null);
  const mergeTimer = useRef(null);
  const pressTimer = useRef(null);
  const pressPos = useRef(null);
  const searchRef = useRef(null);
  const edgeTimer = useRef(null);
  const cornerState = useRef({ zone: null, timer: null, consumed: false });

  /* ---------- 持久化 ---------- */
  useEffect(() => { localStorage.setItem(LS_DATA, JSON.stringify(data)); }, [data]);
  useEffect(() => { localStorage.setItem(LS_PAGE, String(page)); }, [page]);
  useEffect(() => {
    localStorage.setItem(LS_PREFS, JSON.stringify({ appearance, wallpaper, launchAtLogin, dataDir, hotkey, cornerOn, corners }));
    document.body.dataset.appearance = appearance;
  }, [appearance, wallpaper, launchAtLogin, dataDir, hotkey, cornerOn, corners]);
  useEffect(() => {
    document.body.classList.toggle("reduce-motion", reduceMotion);
  }, [reduceMotion]);

  useEffect(() => {
    const onResize = () => setLayout(computeLayout(window.innerWidth, window.innerHeight));
    window.addEventListener("resize", onResize);
    const t = setInterval(() => setClock(new Date()), 1000);
    return () => { window.removeEventListener("resize", onResize); clearInterval(t); };
  }, []);

  const showToast = useCallback((msg, url) => {
    const key = Date.now();
    setToast({ msg, url, key, leaving: false });
    setTimeout(() => setToast(t => (t && t.key === key ? Object.assign({}, t, { leaving: true }) : t)), 2400);
    setTimeout(() => setToast(t => (t && t.key === key ? null : t)), 2750);
  }, []);

  /* ---------- 派生数据 ---------- */
  const groups = data.groups;
  const bookmarks = data.bookmarks;
  const folderOf = useCallback((id) => groups.find(g => g.id === id), [groups]);
  const bookmarksIn = useCallback((gid) => bookmarks.filter(b => b.groupId === gid).sort((a, b) => a.order - b.order), [bookmarks]);

  const rootItems = useMemo(() => {
    const items = [];
    groups.forEach(g => items.push({ kind: "folder", order: g.order, group: g }));
    bookmarks.filter(b => b.groupId === null).forEach(b => items.push({ kind: "bookmark", order: b.order, bookmark: b }));
    return items.sort((a, b) => a.order - b.order);
  }, [groups, bookmarks]);

  const searching = query.trim().length > 0;
  const results = useMemo(() => {
    if (!searching) return [];
    const q = query.trim().toLowerCase();
    return rootItems.flatMap(it => it.kind === "bookmark" ? [it.bookmark] : bookmarksIn(it.group.id))
      .filter(b => b.title.toLowerCase().includes(q) || b.url.toLowerCase().includes(q))
      .map(b => ({ bookmark: b, folder: b.groupId ? (folderOf(b.groupId) || {}).name : null }));
  }, [searching, query, rootItems, bookmarksIn, folderOf]);

  const pages = useMemo(() => {
    const all = rootItems.concat([{ kind: "add" }]);
    const out = [];
    for (let i = 0; i < all.length; i += layout.cap) out.push(all.slice(i, i + layout.cap));
    return out.length ? out : [[{ kind: "add" }]];
  }, [rootItems, layout.cap]);

  const curPage = Math.min(page, pages.length - 1);

  const openFolderGroup = openFolder ? folderOf(openFolder) : null;
  const folderItems = useMemo(() => {
    if (!openFolderGroup) return [];
    return bookmarksIn(openFolderGroup.id).map(b => ({ kind: "bookmark", bookmark: b }))
      .concat([{ kind: "add" }]);
  }, [openFolderGroup, bookmarksIn]);
  const FOLDER_CAP = 8;
  const folderPages = useMemo(() => {
    const out = [];
    for (let i = 0; i < folderItems.length; i += FOLDER_CAP) out.push(folderItems.slice(i, i + FOLDER_CAP));
    return out.length ? out : [[]];
  }, [folderItems]);
  const curFolderPage = Math.min(folderPage, folderPages.length - 1);

  /* ---------- 窗口生命周期 ---------- */
  const openLaunchpad = useCallback(() => {
    setRunning(true);
    setLaunched(true);
    setTrayMenu(false);
    setTimeout(() => searchRef.current && searchRef.current.focus(), 120);
  }, []);
  const closeLaunchpad = useCallback(() => {
    setLaunched(false);
    setEditing(false); setOpenFolder(null); setQuery(""); setCtx(null); setModal(null); setRenaming(null);
  }, []);
  const toggleLaunchpad = useCallback(() => {
    if (launched) closeLaunchpad(); else openLaunchpad();
  }, [launched, closeLaunchpad, openLaunchpad]);
  /* 任务栏入口：恢复现有窗口；重复点击 → 收起 */
  const onTaskbarClick = () => {
    if (!running || !launched) openLaunchpad();
    else closeLaunchpad();
  };
  const quitApp = () => {
    setTrayMenu(false);
    closeLaunchpad();
    setRunning(false);
    showToast("青蛙导航 已退出（原型演示：点击任务栏图标重新运行）");
  };

  /* ---------- 屏幕触角：被动鼠标事件驱动，进入一次只展开一次 ---------- */
  useEffect(() => {
    if (!running || launched || !cornerOn || modal) return;
    const ZONE = 10, DWELL = 550;
    const st = cornerState.current;
    const zoneOf = (x, y) => {
      const w = window.innerWidth, h = window.innerHeight;
      if (x < ZONE && y < ZONE && corners.tl) return "tl";
      if (x > w - ZONE && y < ZONE && corners.tr) return "tr";
      if (x < ZONE && y > h - ZONE && corners.bl) return "bl";
      if (x > w - ZONE && y > h - ZONE && corners.br) return "br";
      return null;
    };
    const onMove = (e) => {
      const z = zoneOf(e.clientX, e.clientY);
      if (!z) {
        st.zone = null; st.consumed = false;
        if (st.timer) { clearTimeout(st.timer); st.timer = null; }
        return;
      }
      if (st.consumed) return;
      if (st.zone === z) return;
      st.zone = z;
      if (st.timer) clearTimeout(st.timer);
      st.timer = setTimeout(() => {
        st.timer = null; st.consumed = true;
        openLaunchpad();
        showToast("屏幕触角触发：进入一次只展开一次");
      }, DWELL);
    };
    window.addEventListener("mousemove", onMove);
    return () => {
      window.removeEventListener("mousemove", onMove);
      if (st.timer) { clearTimeout(st.timer); st.timer = null; }
      st.zone = null; st.consumed = false;
    };
  }, [running, launched, cornerOn, corners, modal, openLaunchpad, showToast]);

  /* ---------- 全局热键捕获（设置页「修改…」） ---------- */
  useEffect(() => {
    if (!capturing) return;
    const onKey = (e) => {
      e.preventDefault(); e.stopPropagation();
      if (e.key === "Escape") { setCapturing(false); return; }
      if (["Control", "Alt", "Shift", "Meta"].includes(e.key)) return;
      const keyName = e.code === "Space" ? "Space" : (e.key.length === 1 ? e.key.toUpperCase() : e.key);
      const cand = { enabled: true, ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, code: e.code, label: keyName };
      const conflict = hotkeyConflict(cand);
      if (conflict) {
        showToast("快捷键冲突：" + conflict + "，已保留原设置");
        setCapturing(false);
        return;
      }
      const next = Object.assign({}, cand, { label: hotkeyLabel(Object.assign({}, cand, { label: keyName })) });
      setHotkey(next);
      setCapturing(false);
      showToast("全局热键已更新为 " + next.label + "（RegisterHotKey）");
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [capturing, showToast]);

  /* ---------- 行为 ---------- */
  const openBookmark = (b) => {
    showToast("已交给默认浏览器打开", b.url);
    setTimeout(closeLaunchpad, 380);
  };

  const mutate = (fn) => setData(d => { const copy = JSON.parse(JSON.stringify(d)); fn(copy); return copy; });

  const saveBookmark = (fields, existing) => {
    mutate(d => {
      let gid = fields.groupId;
      if (fields.newFolderName) {
        const maxOrder = Math.max(0, ...d.groups.map(g => g.order), ...d.bookmarks.filter(b => b.groupId === null).map(b => b.order));
        const g = { id: uid(), name: fields.newFolderName, order: maxOrder + 1 };
        d.groups.push(g);
        gid = g.id;
      }
      if (existing) {
        const b = d.bookmarks.find(x => x.id === existing.id);
        b.title = fields.title; b.url = fields.url;
        if (b.groupId !== gid) {
          b.groupId = gid;
          b.order = gid ? (Math.max(0, ...d.bookmarks.filter(x => x.groupId === gid).map(x => x.order)) + 1)
                        : (Math.max(0, ...d.groups.map(g => g.order), ...d.bookmarks.filter(x => x.groupId === null).map(x => x.order)) + 1);
        }
      } else {
        const order = gid ? (Math.max(0, ...d.bookmarks.filter(x => x.groupId === gid).map(x => x.order)) + 1)
                          : (Math.max(0, ...d.groups.map(g => g.order), ...d.bookmarks.filter(x => x.groupId === null).map(x => x.order)) + 1);
        d.bookmarks.push({ id: uid(), title: fields.title, url: fields.url, groupId: gid, order, createdAt: Date.now(), hue: Math.floor(Math.random() * 360) });
      }
    });
  };

  const deleteBookmark = (id) => {
    mutate(d => { d.bookmarks = d.bookmarks.filter(b => b.id !== id); });
    setModal(null);
    showToast("书签已删除");
  };

  const moveBookmark = (id, gid) => {
    mutate(d => {
      const b = d.bookmarks.find(x => x.id === id);
      b.groupId = gid;
      b.order = gid ? (Math.max(0, ...d.bookmarks.filter(x => x.groupId === gid && x.id !== id).map(x => x.order)) + 1)
                    : (Math.max(0, ...d.groups.map(g => g.order), ...d.bookmarks.filter(x => x.groupId === null).map(x => x.order)) + 1);
    });
    showToast(gid ? "已移动到「" + (folderOf(gid) || {}).name + "」" : "已移动到根目录");
  };

  const refreshIcon = (b) => {
    setRefreshing(r => Object.assign({}, r, { [b.id]: true }));
    setTimeout(() => {
      setRefreshing(r => { const c = Object.assign({}, r); delete c[b.id]; return c; });
      mutate(d => { const x = d.bookmarks.find(v => v.id === b.id); if (x) x.hue = Math.floor(Math.random() * 360); });
      showToast("图标已刷新并写入本机缓存（%LOCALAPPDATA%\\青蛙导航\\IconCache）");
    }, 1100);
  };

  const copyLink = (b) => {
    const done = () => showToast("已复制网址", b.url);
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(b.url).then(done, done);
    else done();
  };

  const commitRename = () => {
    const name = renameVal.trim();
    if (renaming && name) mutate(d => { const g = d.groups.find(x => x.id === renaming); if (g) g.name = name.slice(0, 30); });
    setRenaming(null);
  };

  const tryDeleteFolder = (g) => {
    if (bookmarksIn(g.id).length > 0) {
      showToast("文件夹不为空，请先移出或删除其中的书签");
      return;
    }
    setModal({ type: "deleteFolder", group: g });
  };

  /* ---------- 拖拽 ---------- */
  const onDragStart = (e, item, from) => {
    if (item.kind !== "bookmark" && item.kind !== "folder") { e.preventDefault(); return; }
    dragRef.current = { id: item.kind === "bookmark" ? item.bookmark.id : item.group.id, kind: item.kind, from };
    e.dataTransfer.effectAllowed = "move";
    try { e.dataTransfer.setData("text/plain", dragRef.current.id); } catch (err) {}
    e.dataTransfer.setDragImage(new Image(), 0, 0);
  };
  const clearMergeTimer = () => { if (mergeTimer.current) { clearTimeout(mergeTimer.current); mergeTimer.current = null; } };
  const onDragOverTile = (e, item, scope) => {
    e.preventDefault(); e.stopPropagation();
    const drag = dragRef.current;
    if (!drag) return;
    if (item.kind === "add") { setDropTarget(null); return; }
    const targetId = item.kind === "bookmark" ? item.bookmark.id : item.group.id;
    if (targetId === drag.id) { setDropTarget(null); return; }
    if (item.kind === "folder" && drag.kind === "bookmark") {
      clearMergeTimer();
      setDropTarget({ id: targetId, kind: "folder" });
    } else if (item.kind === "bookmark" && drag.kind === "bookmark") {
      setDropTarget({ id: targetId, kind: "before" });
      clearMergeTimer();
      mergeTimer.current = setTimeout(() => {
        setDropTarget(t => (t && t.id === targetId ? { id: targetId, kind: "merge" } : t));
      }, 650);
    } else if (item.kind === "folder" && drag.kind === "folder") {
      setDropTarget({ id: targetId, kind: "before" });
    }
  };
  const finishDrag = () => {
    clearMergeTimer();
    dragRef.current = null;
    setDropTarget(null);
  };
  const onDropTile = (e, item, scope) => {
    e.preventDefault(); e.stopPropagation();
    const drag = dragRef.current;
    const target = dropTarget;
    finishDrag();
    if (!drag || !target) return;
    if (target.kind === "folder") { moveBookmark(drag.id, target.id); return; }
    if (target.kind === "merge" && drag.kind === "bookmark") {
      const a = drag.id, b = target.id;
      const bmB = bookmarks.find(x => x.id === b);
      const gid = uid();
      mutate(d => {
        const maxOrder = Math.max(0, ...d.groups.map(g => g.order), ...d.bookmarks.filter(x => x.groupId === null).map(x => x.order));
        d.groups.push({ id: gid, name: "新建文件夹", order: bmB.groupId === null ? bmB.order : maxOrder + 1 });
        d.bookmarks.forEach(x => {
          if (x.id === a || x.id === b) { x.groupId = gid; }
        });
        let i = 1;
        d.bookmarks.filter(x => x.groupId === gid)
          .sort((x, y) => ((x.id === b ? 0 : 1) - (y.id === b ? 0 : 1)))
          .forEach(x => { x.order = i++; });
      });
      setOpenFolder(gid);
      setFolderPage(0);
      setTimeout(() => { setRenaming(gid); setRenameVal("新建文件夹"); }, 250);
      return;
    }
    if (target.kind === "before") {
      mutate(d => {
        const seq = scope === "root"
          ? d.groups.map(g => ({ ref: g, isG: true })).concat(d.bookmarks.filter(b => b.groupId === null).map(b => ({ ref: b, isG: false }))).sort((x, y) => x.ref.order - y.ref.order)
          : d.bookmarks.filter(b => b.groupId === scope).map(b => ({ ref: b, isG: false })).sort((x, y) => x.ref.order - y.ref.order);
        const di = seq.findIndex(s => s.ref.id === drag.id);
        if (di < 0) return;
        const moved = seq.splice(di, 1)[0];
        const ti = seq.findIndex(s => s.ref.id === target.id);
        seq.splice(ti < 0 ? seq.length : ti, 0, moved);
        seq.forEach((s, i) => { s.ref.order = i + 1; });
      });
    }
  };
  const onBodyDragOver = (e) => {
    if (!dragRef.current) return;
    e.preventDefault();
    const w = window.innerWidth;
    const dir = e.clientX < 70 ? -1 : e.clientX > w - 70 ? 1 : 0;
    if (dir === 0) { if (edgeTimer.current) { clearTimeout(edgeTimer.current); edgeTimer.current = null; } return; }
    if (!edgeTimer.current) {
      edgeTimer.current = setTimeout(() => {
        edgeTimer.current = null;
        if (openFolderGroup) setFolderPage(p => Math.max(0, Math.min(folderPages.length - 1, p + dir)));
        else setPage(p => Math.max(0, Math.min(pages.length - 1, p + dir)));
      }, 550);
    }
  };
  const onDropBackdrop = (e) => {
    e.preventDefault();
    const drag = dragRef.current;
    finishDrag();
    if (drag && drag.kind === "bookmark" && openFolderGroup) moveBookmark(drag.id, null);
  };

  /* ---------- 键盘 ---------- */
  useEffect(() => {
    const onKey = (e) => {
      if (e.isComposing) return; // 输入法组合输入期间不抢占按键
      if (capturing) return;
      /* 全局唤起热键（RegisterHotKey，进程驻留时生效；再次按下收起） */
      if (running && hotkey.enabled && !modal &&
          e.ctrlKey === hotkey.ctrl && e.altKey === hotkey.alt && e.shiftKey === hotkey.shift &&
          e.code === hotkey.code) {
        e.preventDefault();
        toggleLaunchpad();
        return;
      }
      /* 应用内快捷键 */
      if (launched && !modal) {
        if (e.ctrlKey && e.key === ",") { e.preventDefault(); setSettingsTab("general"); setModal({ type: "settings" }); return; }
        if (e.ctrlKey && (e.key === "n" || e.key === "N")) {
          e.preventDefault();
          setModal({ type: "add", folderId: openFolder || null });
          return;
        }
        if ((e.ctrlKey && (e.key === "f" || e.key === "F")) || (e.key === "/" && document.activeElement !== searchRef.current)) {
          e.preventDefault();
          if (searchRef.current) searchRef.current.focus();
          return;
        }
      }
      if (e.key === "Escape") {
        /* 逐层退出：托盘/右键菜单 → 弹窗/设置 → 重命名 → 整理态 → 清空搜索 → 关文件夹 → 收起 */
        if (trayMenu) { setTrayMenu(false); return; }
        if (ctx) { setCtx(null); return; }
        if (modal) { setModal(null); return; }
        if (renaming) { setRenaming(null); return; }
        if (editing) { setEditing(false); return; }
        if (searching) { setQuery(""); return; }
        if (openFolder) { setOpenFolder(null); return; }
        if (launched) closeLaunchpad();
        return;
      }
      if (!launched || modal) return;
      if (e.key === "PageDown" || (e.key === "ArrowRight" && !searching && document.activeElement !== searchRef.current)) {
        e.preventDefault();
        if (openFolder) setFolderPage(p => Math.min(folderPages.length - 1, p + 1));
        else setPage(p => Math.min(pages.length - 1, p + 1));
      }
      if (e.key === "PageUp" || (e.key === "ArrowLeft" && !searching && document.activeElement !== searchRef.current)) {
        e.preventDefault();
        if (openFolder) setFolderPage(p => Math.max(0, p - 1));
        else setPage(p => Math.max(0, p - 1));
      }
      if (searching) {
        if (e.key === "ArrowDown" || (e.key === "ArrowRight" && document.activeElement === searchRef.current && searchRef.current.selectionStart === query.length)) {
          e.preventDefault(); setSelIdx(i => Math.min(results.length - 1, i + 1));
        }
        if (e.key === "ArrowUp" || (e.key === "ArrowLeft" && document.activeElement === searchRef.current && searchRef.current.selectionStart === 0)) {
          e.preventDefault(); setSelIdx(i => Math.max(0, i - 1));
        }
        if (e.key === "Enter") {
          e.preventDefault();
          if (results.length > 0) openBookmark(results[Math.max(0, Math.min(selIdx, results.length - 1))].bookmark);
          else {
            const q = query.trim();
            showToast("没有匹配书签，已交给默认浏览器搜索", "https://www.google.com/search?q=" + encodeURIComponent(q));
            setTimeout(closeLaunchpad, 380);
          }
        }
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  useEffect(() => { setSelIdx(0); }, [query]);

  /* ---------- 长按进入整理态 ---------- */
  const pressStart = (e, item) => {
    if (item.kind === "add") return;
    pressPos.current = { x: e.clientX, y: e.clientY };
    pressTimer.current = setTimeout(() => setEditing(true), 620);
  };
  const pressMove = (e) => {
    if (!pressPos.current) return;
    if (Math.abs(e.clientX - pressPos.current.x) > 7 || Math.abs(e.clientY - pressPos.current.y) > 7) {
      clearTimeout(pressTimer.current); pressPos.current = null;
    }
  };
  const pressEnd = () => { clearTimeout(pressTimer.current); pressPos.current = null; };

  /* ---------- 右键菜单 ---------- */
  const openCtx = (e, kind, id) => {
    e.preventDefault(); e.stopPropagation();
    const menuW = 230, menuH = kind === "bookmark" ? 250 : 130;
    const x = Math.min(e.clientX, window.innerWidth - menuW - 12);
    const y = Math.min(e.clientY, window.innerHeight - menuH - 12);
    setCtx({ x, y, kind, id });
  };
  useEffect(() => {
    const close = () => { setCtx(null); setTrayMenu(false); };
    window.addEventListener("click", close);
    return () => window.removeEventListener("click", close);
  }, []);

  /* ---------- 滚轮翻页（横向滚动与纵向滚轮均可） ---------- */
  const onWheel = (e) => {
    if (!launched || modal || searching) return;
    const delta = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY;
    if (Math.abs(delta) < 24) return;
    if (openFolder) setFolderPage(p => Math.max(0, Math.min(folderPages.length - 1, p + (delta > 0 ? 1 : -1))));
    else setPage(p => Math.max(0, Math.min(pages.length - 1, p + (delta > 0 ? 1 : -1))));
  };

  /* ---------- 渲染单个图标块 ---------- */
  const renderTile = (item, scope, idx) => {
    if (item.kind === "add") {
      return (
        <div key="__add__" className="lp-tile lp-add" style={{ animationDelay: (idx * 16) + "ms" }}
          onClick={(e) => { e.stopPropagation(); setModal({ type: "add", folderId: scope === "root" ? null : scope }); }}>
          <div className="lp-icon"><IcPlus /></div>
          <div className="lp-tile-name">添加书签</div>
        </div>
      );
    }
    if (item.kind === "folder") {
      const g = item.group;
      const inner = bookmarksIn(g.id);
      const minis = inner.length > 4 ? inner.slice(0, 3) : inner.slice(0, 4);
      const isRenaming = renaming === g.id;
      return (
        <div key={g.id}
          className={"lp-tile lp-folder" + (editing ? " jiggle" : "") + (dropTarget && dropTarget.id === g.id && dropTarget.kind === "folder" ? " drop-target" : "") + (dragRef.current && dragRef.current.id === g.id ? " dragging" : "")}
          style={{ animationDelay: (idx * 16) + "ms" }}
          draggable={editing}
          onDragStart={(e) => onDragStart(e, item, scope)}
          onDragOver={(e) => onDragOverTile(e, item, scope)}
          onDrop={(e) => onDropTile(e, item, scope)}
          onDragEnd={finishDrag}
          onPointerDown={(e) => pressStart(e, item)} onPointerMove={pressMove} onPointerUp={pressEnd} onPointerLeave={pressEnd}
          onContextMenu={(e) => openCtx(e, "folder", g.id)}
          onClick={(e) => { e.stopPropagation(); if (editing) return; setOpenFolder(g.id); setFolderPage(0); }}>
          <div className="lp-icon">
            <div className="lp-folder-minis">
              {minis.map(b => <div key={b.id} className="lp-mini" style={frogIconStyle(b)}>{frogInitial(b.title)}</div>)}
              {inner.length === 0 && <div className="lp-mini lp-folder-more" style={{ gridColumn: "1 / -1" }}>空</div>}
              {inner.length > 4 && <div className="lp-mini lp-folder-more" style={{ background: "rgba(120,120,130,0.4)" }}>+{inner.length - 3}</div>}
            </div>
          </div>
          {isRenaming
            ? <input className="lp-name-input" autoFocus value={renameVal}
                onChange={(e) => setRenameVal(e.target.value)}
                onBlur={commitRename}
                onKeyDown={(e) => { if (e.isComposing) return; if (e.key === "Enter") commitRename(); if (e.key === "Escape") setRenaming(null); e.stopPropagation(); }}
                onClick={(e) => e.stopPropagation()} />
            : <div className="lp-tile-name">{g.name}</div>}
        </div>
      );
    }
    const b = item.bookmark;
    const isDrop = dropTarget && dropTarget.id === b.id;
    const folder = b.groupId ? folderOf(b.groupId) : null;
    return (
      <div key={b.id}
        className={"lp-tile" + (editing ? " jiggle" : "")
          + (isDrop && dropTarget.kind === "before" ? " drop-target" : "")
          + (isDrop && dropTarget.kind === "merge" ? " merge-preview" : "")
          + (dragRef.current && dragRef.current.id === b.id ? " dragging" : "")
          + (searching && results[selIdx] && results[selIdx].bookmark.id === b.id ? " drop-target" : "")}
        style={{ animationDelay: searching ? "0ms" : (idx * 16) + "ms" }}
        draggable={editing && !searching}
        onDragStart={(e) => onDragStart(e, item, scope)}
        onDragOver={(e) => onDragOverTile(e, item, scope)}
        onDrop={(e) => onDropTile(e, item, scope)}
        onDragEnd={finishDrag}
        onPointerDown={(e) => pressStart(e, item)} onPointerMove={pressMove} onPointerUp={pressEnd} onPointerLeave={pressEnd}
        onContextMenu={(e) => openCtx(e, "bookmark", b.id)}
        onClick={(e) => { e.stopPropagation(); if (editing) return; openBookmark(b); }}>
        {editing && !searching && (
          <button className="lp-del" onClick={(e) => { e.stopPropagation(); setModal({ type: "delete", bookmark: b }); }}>
            <IcClose />
          </button>
        )}
        <div style={{ position: "relative" }}>
          <IconTile bookmark={b} />
          {refreshing[b.id] && <div className="lp-spinner"></div>}
        </div>
        <div className="lp-tile-name">{b.title}</div>
        {searching && folder && <div className="lp-tile-badge">{folder.name}</div>}
      </div>
    );
  };

  /* ---------- 渲染 ---------- */
  const hh = String(clock.getHours()).padStart(2, "0") + ":" + String(clock.getMinutes()).padStart(2, "0");
  const dateStr = clock.getFullYear() + "/" + (clock.getMonth() + 1) + "/" + clock.getDate();
  const cornerDefs = [
    { key: "tl", name: "左上角" }, { key: "tr", name: "右上角" },
    { key: "bl", name: "左下角" }, { key: "br", name: "右下角" }
  ];

  return (
    <React.Fragment>
      {/* ===== Windows 11 桌面 ===== */}
      <div className="desktop" data-screen-label="Windows 11 桌面">
        <div className={"wallpaper wp-" + wallpaper}></div>
        {!launched && (
          <div className="desktop-hint">
            <h1>青蛙导航 书签启动台 · Windows 版</h1>
            <p>点击任务栏中的 青蛙导航 图标，或按 <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>Space</kbd> 展开全屏启动台{cornerOn && "；或将鼠标移入已启用的屏幕角落"}</p>
          </div>
        )}
      </div>

      {/* ===== 启动台（铺满工作区，保留任务栏） ===== */}
      <div className={"launchpad" + (launched ? " open" : "") + (noWallpaper ? " no-wallpaper" : "")} data-screen-label="启动台"
        onWheel={onWheel}
        onClick={() => { if (!launched) return; if (editing) setEditing(false); else closeLaunchpad(); }}
        onDragOver={onBodyDragOver}
        onDrop={onDropBackdrop}>
        <div className="lp-scale" style={{ flex: 1, display: "flex", flexDirection: "column", minHeight: 0, transform: "scale(" + zoom + ")", transformOrigin: "50% 42%" }}>
          <div className="lp-top" onClick={(e) => e.stopPropagation()}>
            <div className={"lp-search" + (launched ? " focused" : "")}>
              <IcSearch />
              <input ref={searchRef} placeholder="搜索书签，或输入网址" value={query}
                onChange={(e) => { setQuery(e.target.value); if (editing) setEditing(false); }} />
              {query && (
                <button className="lp-search-clear" onClick={() => { setQuery(""); searchRef.current.focus(); }}>
                  <IcClose size={9} />
                </button>
              )}
            </div>
            <div className="lp-top-actions">
              <button className="lp-top-btn" title="设置（Ctrl + ,）" onClick={() => { setSettingsTab("general"); setModal({ type: "settings" }); }}>
                <IcGear />
              </button>
              <button className="lp-top-btn" title="添加书签（Ctrl + N）" onClick={() => setModal({ type: "add", folderId: null })}>
                <IcPlus size={17} />
              </button>
            </div>
          </div>

          <div className="lp-body" onClick={(e) => e.stopPropagation()}>
            {searching ? (
              <div className="lp-page" style={{ position: "absolute", inset: 0 }} onClick={() => { if (editing) setEditing(false); }}>
                {results.length > 0 ? (
                  <div className="lp-grid" style={{ gridTemplateColumns: "repeat(" + layout.cols + ", 104px)" }}>
                    {results.map((r, i) => renderTile({ kind: "bookmark", bookmark: r.bookmark }, "search", i))}
                  </div>
                ) : (
                  <div style={{ textAlign: "center", color: "var(--label-2)" }}>
                    <div style={{ fontSize: 17, fontWeight: 600, color: "var(--label)", marginBottom: 8 }}>没有匹配的书签</div>
                    <div style={{ fontSize: 13 }}>按 Enter 打开输入的网址，或使用 Google 搜索「{query.trim()}」</div>
                  </div>
                )}
              </div>
            ) : (
              <div className="lp-pages" style={{ transform: "translateX(-" + (curPage * 100) + "%)" }}
                onClick={() => { if (editing) setEditing(false); else closeLaunchpad(); }}>
                {pages.map((pg, pi) => (
                  <div className="lp-page" key={pi} onClick={(e) => e.stopPropagation()}
                    style={{ alignItems: "flex-start", paddingTop: "3vh" }}>
                    <div className="lp-grid" style={{ gridTemplateColumns: "repeat(" + layout.cols + ", 104px)" }}
                      onClick={() => { if (editing) setEditing(false); else closeLaunchpad(); }}>
                      {pg.map((item, ii) => (
                        <div key={item.kind === "add" ? "__add__" : item.kind === "folder" ? item.group.id : item.bookmark.id}
                          onClick={(e) => e.stopPropagation()} style={{ display: "contents" }}>
                          {renderTile(item, "root", pi * layout.cap + ii)}
                        </div>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>

          {!searching && pages.length > 1 && (
            <div className="lp-dots" onClick={(e) => e.stopPropagation()}>
              {pages.map((_, i) => (
                <button key={i} className={"lp-dot" + (i === curPage ? " active" : "")} onClick={() => setPage(i)} title={"第 " + (i + 1) + " 页"}></button>
              ))}
            </div>
          )}
          {!searching && pages.length <= 1 && <div style={{ height: 40, flex: "none" }}></div>}
        </div>
      </div>

      {/* ===== 文件夹面板 ===== */}
      {launched && openFolderGroup && (
        <div className={"folder-overlay" + (noWallpaper ? " no-wallpaper" : "")} data-screen-label={"文件夹：" + openFolderGroup.name}
          onClick={() => { if (renaming) return; setOpenFolder(null); }}
          onDragOver={onBodyDragOver}
          onDrop={onDropBackdrop}
          onWheel={onWheel}>
          <div className="folder-panel" onClick={(e) => e.stopPropagation()} onDrop={(e) => e.stopPropagation()}>
            {renaming === openFolderGroup.id ? (
              <input className="folder-name-input" autoFocus value={renameVal}
                onChange={(e) => setRenameVal(e.target.value)}
                onBlur={commitRename}
                onKeyDown={(e) => { if (e.isComposing) return; if (e.key === "Enter") commitRename(); if (e.key === "Escape") setRenaming(null); }} />
            ) : (
              <div className="folder-name" onClick={() => { setRenaming(openFolderGroup.id); setRenameVal(openFolderGroup.name); }}
                title="点击重命名">{openFolderGroup.name}</div>
            )}
            <div className="folder-grid" onClick={() => { if (editing) setEditing(false); }}>
              {folderPages[curFolderPage].map((item, ii) => (
                <div key={item.kind === "add" ? "__fadd__" : item.bookmark.id} onClick={(e) => e.stopPropagation()} style={{ display: "contents" }}>
                  {renderTile(item, openFolderGroup.id, ii)}
                </div>
              ))}
              {folderItems.length === 1 && <div className="folder-empty-hint">空文件夹 — 点击「添加书签」开始收集</div>}
            </div>
            {folderPages.length > 1 && (
              <div className="lp-dots">
                {folderPages.map((_, i) => (
                  <button key={i} className={"lp-dot" + (i === curFolderPage ? " active" : "")} onClick={() => setFolderPage(i)}></button>
                ))}
              </div>
            )}
          </div>
        </div>
      )}

      {/* ===== 任务栏（始终保留） ===== */}
      <div className="taskbar" data-screen-label="任务栏" onClick={(e) => e.stopPropagation()}>
        <div className="tb-icons">
          <button className="tb-icon tb-start" onClick={() => showToast("开始菜单（系统组件，原型不演示）")}>
            <IcWindows /><span className="tb-tip">开始</span>
          </button>
          <button className="tb-icon" onClick={() => showToast("Windows 搜索（系统组件，原型不演示）")}>
            <IcSearch size={18} /><span className="tb-tip">搜索</span>
          </button>
          <button className="tb-icon" onClick={() => showToast("任务视图（系统组件，原型不演示）")}>
            <IcTaskView /><span className="tb-tip">任务视图</span>
          </button>
          <button className="tb-icon tb-edge" onClick={() => showToast("Microsoft Edge（系统组件，原型不演示）")}>
            <IcEdge /><span className="tb-tip">Microsoft Edge</span>
          </button>
          <button className="tb-icon tb-explorer" onClick={() => showToast("文件资源管理器（系统组件，原型不演示）")}>
            <IcExplorer /><span className="tb-tip">文件资源管理器</span>
          </button>
          <button className="tb-icon tb-frog" onClick={onTaskbarClick}>
            <IcFrogMark size={24} /><span className="tb-tip">青蛙导航{running ? (launched ? " — 点击收起" : " — 点击展开") : " — 点击启动"}</span>
            {running && <span className={"tb-running" + (launched ? " active" : "")}></span>}
          </button>
        </div>
        <div className="tb-tray">
          <button className="tb-tray-btn" onClick={() => showToast("隐藏的图标（系统组件，原型不演示）")}>
            <IcChevronUp size={11} />
          </button>
          {running && (
            <button className="tb-tray-btn" title="青蛙导航 托盘" onClick={(e) => { e.stopPropagation(); setTrayMenu(v => !v); setCtx(null); }}>
              <IcFrogMark size={16} />
            </button>
          )}
          <button className="tb-tray-btn" onClick={() => showToast("快速设置（系统组件，原型不演示）")}>
            <IcWifi /><IcVolume /><IcBattery size={17} />
          </button>
          <button className="tb-tray-btn tb-clock" onClick={() => showToast("日历与通知（系统组件，原型不演示）")}>
            <span>{hh}</span><span>{dateStr}</span>
          </button>
          <button className="tb-tray-btn" onClick={() => showToast("通知中心（系统组件，原型不演示）")}>
            <IcBell size={14} />
          </button>
          <button className="tb-tray-btn tb-showdesk" title="显示桌面" onClick={() => { if (launched) closeLaunchpad(); }}></button>
        </div>
      </div>

      {/* ===== 托盘菜单 ===== */}
      {trayMenu && running && (
        <div className="ctx-menu" style={{ right: 8, bottom: "calc(var(--taskbar-h) + 8px)", minWidth: 200, left: "auto", top: "auto" }}
          data-screen-label="托盘菜单" onClick={(e) => e.stopPropagation()}>
          <button className="ctx-item" onClick={() => { setTrayMenu(false); toggleLaunchpad(); }}>
            <IcExternal />{launched ? "收起" : "展开"}
          </button>
          <button className="ctx-item" onClick={() => { setTrayMenu(false); setSettingsTab("general"); setModal({ type: "settings" }); }}>
            <IcGear size={14} />设置<span className="ctx-sub">Ctrl + ,</span>
          </button>
          <div className="ctx-sep"></div>
          <button className="ctx-item danger" onClick={quitApp}><IcPower size={14} />退出</button>
        </div>
      )}

      {/* ===== 右键菜单 ===== */}
      {ctx && (
        <ContextMenu ctx={ctx} setCtx={setCtx}
          bookmarks={bookmarks} groups={groups} folderOf={folderOf} bookmarksIn={bookmarksIn}
          onOpen={(b) => openBookmark(b)}
          onCopy={(b) => copyLink(b)}
          onEdit={(b) => setModal({ type: "edit", bookmark: b })}
          onRefresh={(b) => refreshIcon(b)}
          onMove={(b, gid) => moveBookmark(b.id, gid)}
          onDelete={(b) => setModal({ type: "delete", bookmark: b })}
          onOpenFolder={(g) => { setOpenFolder(g.id); setFolderPage(0); }}
          onRenameFolder={(g) => { setRenaming(g.id); setRenameVal(g.name); }}
          onDeleteFolder={(g) => tryDeleteFolder(g)} />
      )}

      {/* ===== 弹窗 ===== */}
      {modal && (modal.type === "add" || modal.type === "edit") && (
        <BookmarkForm modal={modal} groups={groups}
          onCancel={() => setModal(null)}
          onSave={(fields, existing) => {
            saveBookmark(fields, existing);
            setModal(null);
            showToast(existing ? "书签已更新" : "书签已保存，图标将异步获取");
          }} />
      )}
      {modal && modal.type === "delete" && (
        <div className="modal-overlay" onClick={() => setModal(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()} style={{ width: 380 }}>
            <h2>删除书签</h2>
            <p className="modal-warn">确定删除「<strong>{modal.bookmark.title}</strong>」吗？此操作不可撤销。</p>
            <div className="modal-actions">
              <button className="btn btn-ghost" onClick={() => setModal(null)}>取消</button>
              <button className="btn btn-danger" onClick={() => deleteBookmark(modal.bookmark.id)}>删除</button>
            </div>
          </div>
        </div>
      )}
      {modal && modal.type === "deleteFolder" && (
        <div className="modal-overlay" onClick={() => setModal(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()} style={{ width: 380 }}>
            <h2>删除文件夹</h2>
            <p className="modal-warn">确定删除空文件夹「<strong>{modal.group.name}</strong>」吗？</p>
            <div className="modal-actions">
              <button className="btn btn-ghost" onClick={() => setModal(null)}>取消</button>
              <button className="btn btn-danger" onClick={() => {
                mutate(d => { d.groups = d.groups.filter(g => g.id !== modal.group.id); });
                if (openFolder === modal.group.id) setOpenFolder(null);
                setModal(null); showToast("文件夹已删除");
              }}>删除</button>
            </div>
          </div>
        </div>
      )}
      {modal && modal.type === "settings" && (
        <div className="modal-overlay" onClick={() => setModal(null)}>
          <div className="settings" data-screen-label="设置" onClick={(e) => e.stopPropagation()}>
            <div className="settings-side">
              <div className="settings-side-title">青蛙导航 设置</div>
              <button className={"settings-side-item" + (settingsTab === "general" ? " active" : "")} onClick={() => setSettingsTab("general")}>
                <IcPower />通用
              </button>
              <button className={"settings-side-item" + (settingsTab === "hotkey" ? " active" : "")} onClick={() => setSettingsTab("hotkey")}>
                <IcKeyboard />快捷键
              </button>
              <button className={"settings-side-item" + (settingsTab === "corner" ? " active" : "")} onClick={() => setSettingsTab("corner")}>
                <IcCorner />屏幕触角
              </button>
              <button className={"settings-side-item" + (settingsTab === "data" ? " active" : "")} onClick={() => setSettingsTab("data")}>
                <IcSave />数据与备份
              </button>
              <button className={"settings-side-item" + (settingsTab === "about" ? " active" : "")} onClick={() => setSettingsTab("about")}>
                <IcInfo />关于
              </button>
            </div>
            <div className="settings-main">
              {settingsTab === "general" && (
                <React.Fragment>
                  <h2>通用</h2>
                  <div className="set-group">
                    <div className="set-row">
                      <span className="set-label">登录时启动</span>
                      <button className={"switch" + (launchAtLogin ? " on" : "")} onClick={() => {
                        setLaunchAtLogin(v => !v);
                        showToast(!launchAtLogin ? "已在启动目录创建快捷方式（--background）" : "已移除启动目录快捷方式");
                      }}></button>
                    </div>
                    <div className="set-row">
                      <span className="set-note">通过当前用户「启动」目录的快捷方式运行 <strong>--background</strong>，静默驻留并延迟创建主界面。若被系统禁用，请前往 Windows「启动应用」设置开启。</span>
                    </div>
                    <div className="set-row">
                      <span className="set-label">系统启动应用设置</span>
                      <span className="set-btns">
                        <button className="set-btn" onClick={() => showToast("已打开 ms-settings:startupapps（原型演示）")}>打开「启动应用」…</button>
                      </span>
                    </div>
                  </div>
                  <div className="set-group">
                    <div className="set-row">
                      <span className="set-label">窗口行为</span>
                      <span className="set-note">成功打开网址、切换到其他应用或点击根目录空白时自动收起；<strong>Alt + F4</strong> 收起；完全退出请使用托盘菜单。</span>
                    </div>
                  </div>
                </React.Fragment>
              )}
              {settingsTab === "hotkey" && (
                <React.Fragment>
                  <h2>快捷键</h2>
                  <div className="set-group">
                    <div className="set-row">
                      <span className="set-label">全局唤起热键</span>
                      <span className="set-btns">
                        {capturing ? (
                          <span className="hotkey-box recording">按下新快捷键…（Esc 取消）</span>
                        ) : (
                          <span className="hotkey-box"><kbd>{hotkey.label}</kbd></span>
                        )}
                        <button className="set-btn" onClick={() => setCapturing(true)}>修改…</button>
                        <button className="set-btn" onClick={() => { setHotkey(DEFAULT_HOTKEY); showToast("已恢复默认热键 Ctrl + Alt + Space"); }}>恢复默认</button>
                      </span>
                      <button className={"switch" + (hotkey.enabled ? " on" : "")} title={hotkey.enabled ? "关闭热键" : "开启热键"}
                        onClick={() => { setHotkey(h => Object.assign({}, h, { enabled: !h.enabled })); showToast(hotkey.enabled ? "已注销全局热键" : "已注册全局热键"); }}></button>
                    </div>
                    <div className="set-row">
                      <span className="set-note">使用 <strong>RegisterHotKey</strong> 注册；再次按下收起，长按不连续触发。与系统组合冲突时会提示并保留原设置（可试试改为 Ctrl + Space）。</span>
                    </div>
                  </div>
                  <div className="set-group">
                    <div className="set-row">
                      <span className="set-label">应用内快捷键</span>
                      <span className="set-note">
                        <strong>Ctrl + N</strong> 添加书签 · <strong>Ctrl + ,</strong> 设置 · <strong>Ctrl + F</strong> 或 <strong>/</strong> 搜索<br />
                        <strong>PageUp / PageDown</strong> 翻页 · <strong>Esc</strong> 逐层退出 · <strong>Alt + F4</strong> 收起（浏览器内无法演示）
                      </span>
                    </div>
                  </div>
                </React.Fragment>
              )}
              {settingsTab === "corner" && (
                <React.Fragment>
                  <h2>屏幕触角</h2>
                  <div className="set-group">
                    <div className="set-row">
                      <span className="set-label">启用屏幕触角</span>
                      <button className={"switch" + (cornerOn ? " on" : "")} onClick={() => {
                        setCornerOn(v => !v);
                        showToast(!cornerOn ? "屏幕触角已启用：将鼠标移入所选角落试试" : "屏幕触角已关闭");
                      }}></button>
                    </div>
                    <div className="set-row">
                      <span className="set-label">触发角落</span>
                      <span className="corner-grid">
                        {cornerDefs.map(c => (
                          <button key={c.key} className={"corner-opt" + (corners[c.key] ? " active" : "")}
                            onClick={() => setCorners(cs => Object.assign({}, cs, { [c.key]: !cs[c.key] }))}>
                            <span className="corner-dot"></span>{c.name}
                          </button>
                        ))}
                      </span>
                    </div>
                    <div className="set-row">
                      <span className="set-note">默认关闭。通过被动鼠标事件驱动，进入一次只展开一次；拖动、文件选择器及切换动画期间抑制触发，静止时不轮询。Windows 版四角均可选择。</span>
                    </div>
                  </div>
                </React.Fragment>
              )}
              {settingsTab === "data" && (
                <React.Fragment>
                  <h2>数据与备份</h2>
                  <div className="set-group">
                    <div className="set-row">
                      <span className="set-label">数据目录</span>
                      <span className="set-value">{dataDir}\bookmarks.json</span>
                    </div>
                    <div className="set-row">
                      <span className="set-note">自选目录只承载书签文件，可由坚果云等同步工具管理；偏好与图标缓存独立保存在本机。保存经串行存储模块 + 临时文件原子替换，并通过 <strong>ReadDirectoryChangesW</strong> 监听外部更新。</span>
                      <span className="set-btns">
                        <button className="set-btn" onClick={() => showToast("已在文件资源管理器中打开（原型演示）")}>打开所在文件夹</button>
                        <button className="set-btn" onClick={() => {
                          setDataDir("D:\\坚果云\\青蛙导航");
                          showToast("已切换数据目录，网格已刷新");
                        }}>选择目录…</button>
                      </span>
                    </div>
                  </div>
                  <div className="set-group">
                    <div className="set-row">
                      <span className="set-label">另存备份</span>
                      <span className="set-btns">
                        <button className="set-btn" onClick={() => showToast("已导出 青蛙导航-Bookmarks-" + clock.getFullYear() + String(clock.getMonth() + 1).padStart(2, "0") + String(clock.getDate()).padStart(2, "0") + ".json")}>导出 JSON…</button>
                      </span>
                    </div>
                    <div className="set-row">
                      <span className="set-label">恢复备份</span>
                      <span className="set-btns">
                        <button className="set-btn" onClick={() => showToast("校验通过，已整体替换当前数据（原型演示）")}>选择备份…</button>
                      </span>
                    </div>
                    <div className="set-row">
                      <span className="set-note">恢复校验通过后<strong>整体替换</strong>当前全部书签和分组，不合并、不去重；格式错误、目录不可用或写入失败时保留原数据。备份格式与 macOS 版相同，两端可互相读取。</span>
                    </div>
                  </div>
                </React.Fragment>
              )}
              {settingsTab === "about" && (
                <React.Fragment>
                  <h2>关于</h2>
                  <div className="about-icon"><IcFrogMark size={30} /></div>
                  <div className="about-name">青蛙导航</div>
                  <div className="about-ver">版本 0.1.0（原型演示）· Windows 11 x64</div>
                  <p className="about-desc">
                    本地书签启动台，C++20 / Win32 / Direct2D·DirectWrite 原生绘制。
                    数据格式 frog-bookmarks（schemaVersion 1），与 macOS 版备份互相读取；
                    图标缓存于 %LOCALAPPDATA%\青蛙导航\IconCache，核心操作完全离线可用。
                  </p>
                </React.Fragment>
              )}
            </div>
          </div>
        </div>
      )}

      <Toast toast={toast} />

      {/* ===== 原型控制面板 ===== */}
      {tweaksOpen && (
        <div className="proto-panel">
          <h3>原型控制</h3>
          <div className="proto-row">
            <span className="pr-label">外观</span>
            <div className="seg">
              <button className={appearance === "dark" ? "active" : ""} onClick={() => setAppearance("dark")}>深色</button>
              <button className={appearance === "light" ? "active" : ""} onClick={() => setAppearance("light")}>浅色</button>
            </div>
          </div>
          <div className="proto-row">
            <span className="pr-label">壁纸</span>
            <div className="wp-swatches">
              <button className={"wp-swatch wp-bloom" + (wallpaper === "bloom" ? " active" : "")} onClick={() => setWallpaper("bloom")} title="Bloom 深色"></button>
              <button className={"wp-swatch wp-bloom-light" + (wallpaper === "bloom-light" ? " active" : "")} onClick={() => setWallpaper("bloom-light")} title="Bloom 浅色"></button>
              <button className={"wp-swatch wp-graphite" + (wallpaper === "graphite" ? " active" : "")} onClick={() => setWallpaper("graphite")} title="石墨"></button>
            </div>
          </div>
          <div className="proto-row">
            <span className="pr-label">显示缩放</span>
            <div className="seg">
              <button className={zoom === 1 ? "active" : ""} onClick={() => setZoom(1)}>100%</button>
              <button className={zoom === 1.25 ? "active" : ""} onClick={() => setZoom(1.25)}>125%</button>
              <button className={zoom === 1.5 ? "active" : ""} onClick={() => setZoom(1.5)}>150%</button>
            </div>
          </div>
          <div className="proto-row">
            <label className="pr-check"><input type="checkbox" checked={noWallpaper} onChange={(e) => setNoWallpaper(e.target.checked)} />模拟壁纸读取失败（回退主题背景）</label>
          </div>
          <div className="proto-row">
            <label className="pr-check"><input type="checkbox" checked={reduceMotion} onChange={(e) => setReduceMotion(e.target.checked)} />模拟系统「减少动画」</label>
          </div>
          <div className="proto-kbd-hints">
            <div><kbd>Ctrl+Alt+Space</kbd> 唤起/收起 · <kbd>Ctrl+N</kbd> 添加 · <kbd>Ctrl+,</kbd> 设置</div>
            <div><kbd>/</kbd> 或 <kbd>Ctrl+F</kbd> 搜索 · <kbd>PgUp/PgDn</kbd> 翻页 · <kbd>Esc</kbd> 逐层退出</div>
            <div><kbd>长按图标</kbd> 整理 · <kbd>右键</kbd> 菜单 · <kbd>滚轮</kbd> 翻页 · 拖到边缘跨页</div>
            <div>拖到另一图标上停留 → 创建文件夹</div>
          </div>
          <div className="proto-row" style={{ marginTop: 10 }}>
            <button className="proto-reset" onClick={() => {
              localStorage.removeItem(LS_DATA); localStorage.removeItem(LS_PAGE);
              setData(frogSeedData()); setPage(0); setOpenFolder(null); setEditing(false);
              showToast("已重置为演示数据");
            }}>重置演示数据</button>
          </div>
        </div>
      )}
      <button className="proto-toggle" onClick={() => setTweaksOpen(v => !v)}>{tweaksOpen ? "隐藏面板" : "原型面板"}</button>
    </React.Fragment>
  );
}

/* ---------- 右键菜单组件 ---------- */
function ContextMenu(props) {
  const { ctx, setCtx } = props;
  const [subOpen, setSubOpen] = useState(false);
  const close = () => setCtx(null);

  if (ctx.kind === "folder") {
    const g = props.groups.find(x => x.id === ctx.id);
    if (!g) return null;
    const count = props.bookmarksIn(g.id).length;
    return (
      <div className="ctx-menu" style={{ left: ctx.x, top: ctx.y }} onClick={(e) => e.stopPropagation()}>
        <button className="ctx-item" onClick={() => { close(); props.onOpenFolder(g); }}><IcExternal />打开</button>
        <button className="ctx-item" onClick={() => { close(); props.onRenameFolder(g); }}><IcPencil />重命名</button>
        <div className="ctx-sep"></div>
        <button className="ctx-item danger" onClick={() => { close(); props.onDeleteFolder(g); }}>
          <IcTrash />删除文件夹<span className="ctx-sub">{count > 0 ? count + " 项" : "空"}</span>
        </button>
      </div>
    );
  }
  const b = props.bookmarks.find(x => x.id === ctx.id);
  if (!b) return null;
  return (
    <div className="ctx-menu" style={{ left: ctx.x, top: ctx.y }} onClick={(e) => e.stopPropagation()}>
      <button className="ctx-item" onClick={() => { close(); props.onOpen(b); }}><IcExternal />打开</button>
      <button className="ctx-item" onClick={() => { close(); props.onCopy(b); }}><IcLink />复制网址</button>
      <button className="ctx-item" onClick={() => { close(); props.onEdit(b); }}><IcPencil />编辑</button>
      <button className="ctx-item" onClick={() => { close(); props.onRefresh(b); }}><IcRefresh />刷新图标</button>
      <div className="ctx-sep"></div>
      <div style={{ position: "relative" }}>
        <button className="ctx-item" onMouseEnter={() => setSubOpen(true)}>
          <IcFolderMove />移动位置…<span className="ctx-sub"><IcChevronRight /></span>
        </button>
        {subOpen && (
          <div className="ctx-menu" style={{ left: ctx.x + 216, top: ctx.y + 156, minWidth: 180 }} onMouseLeave={() => setSubOpen(false)}>
            {b.groupId !== null && (
              <button className="ctx-item" onClick={() => { close(); props.onMove(b, null); }}><IcFolder />根目录</button>
            )}
            {props.groups.filter(g => g.id !== b.groupId).map(g => (
              <button key={g.id} className="ctx-item" onClick={() => { close(); props.onMove(b, g.id); }}>
                <IcFolder />{g.name}
              </button>
            ))}
            {props.groups.filter(g => g.id !== b.groupId).length === 0 && b.groupId === null && (
              <button className="ctx-item" style={{ opacity: 0.5, cursor: "default" }}>无其他文件夹</button>
            )}
          </div>
        )}
      </div>
      <div className="ctx-sep"></div>
      <button className="ctx-item danger" onClick={() => { close(); props.onDelete(b); }}><IcTrash />删除</button>
    </div>
  );
}

/* ---------- 新增 / 编辑书签表单 ---------- */
function BookmarkForm({ modal, groups, onCancel, onSave }) {
  const existing = modal.type === "edit" ? modal.bookmark : null;
  const [url, setUrl] = useState(existing ? existing.url : "");
  const [title, setTitle] = useState(existing ? existing.title : "");
  const [loc, setLoc] = useState(existing ? (existing.groupId || "root") : (modal.folderId || "root"));
  const [newFolderName, setNewFolderName] = useState("");
  const [errors, setErrors] = useState({});
  const urlRef = useRef(null);
  useEffect(() => { if (urlRef.current) urlRef.current.focus(); }, []);

  const submit = () => {
    const errs = {};
    const t = title.trim();
    const u = normalizeUrl(url);
    if (!u) errs.url = "请输入有效的 http/https 网址（输入域名会自动补全 https）";
    if (!t) errs.title = "标题不能为空";
    else if (t.length > 120) errs.title = "标题不能超过 120 个字符（当前 " + t.length + "）";
    if (loc === "__new__" && !newFolderName.trim()) errs.loc = "请输入新文件夹名称";
    setErrors(errs);
    if (Object.keys(errs).length > 0) return;
    onSave({
      url: u, title: t,
      groupId: loc === "root" || loc === "__new__" ? null : loc,
      newFolderName: loc === "__new__" ? newFolderName.trim() : null
    }, existing);
  };

  return (
    <div className="modal-overlay" onClick={onCancel}>
      <div className="modal" data-screen-label={existing ? "编辑书签" : "添加书签"} onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => { if (!e.isComposing && e.key === "Enter" && e.target.tagName === "INPUT") submit(); }}>
        <h2>{existing ? "编辑书签" : "添加书签"}</h2>
        <div className="modal-field">
          <label>网址</label>
          <input ref={urlRef} className={errors.url ? "error" : ""} placeholder="example.com 或 https://example.com"
            value={url} onChange={(e) => setUrl(e.target.value)} />
          {errors.url && <div className="field-error">{errors.url}</div>}
        </div>
        <div className="modal-field">
          <label>标题</label>
          <input className={errors.title ? "error" : ""} placeholder="书签名称（≤ 120 字）"
            value={title} onChange={(e) => setTitle(e.target.value)} />
          {errors.title && <div className="field-error">{errors.title}</div>}
        </div>
        <div className="modal-field">
          <label>位置</label>
          <select value={loc} onChange={(e) => setLoc(e.target.value)}>
            <option value="root">根目录</option>
            {groups.map(g => <option key={g.id} value={g.id}>{g.name}</option>)}
            <option value="__new__">新建文件夹…</option>
          </select>
        </div>
        {loc === "__new__" && (
          <div className="modal-field">
            <label>新文件夹名称</label>
            <input className={errors.loc ? "error" : ""} placeholder="例如：工作"
              value={newFolderName} onChange={(e) => setNewFolderName(e.target.value)} />
            {errors.loc && <div className="field-error">{errors.loc}</div>}
          </div>
        )}
        <div className="modal-actions">
          <button className="btn btn-ghost" onClick={onCancel}>取消</button>
          <button className="btn btn-primary" onClick={submit}>{existing ? "保存" : "添加"}</button>
        </div>
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
