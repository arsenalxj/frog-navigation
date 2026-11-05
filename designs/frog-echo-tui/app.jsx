/* 青蛙导航 · 回声终端 — 命令行为核心的状态机
 * 无弹窗：增删改、设置、备份恢复、目录切换全部通过 `:` 提示流与缓冲区完成。
 */

const { useState, useEffect, useRef, useCallback, useMemo } = React;

/* ---------------- 场景（界面地图） ---------------- */
const FROG_SCENES = [
  { group: "主流程", items: [
    ["main-root", "根目录 · 浏览"],
    ["main-folder", "文件夹展开"],
    ["search", "搜索结果"],
    ["search-focus", "搜索输入中"],
    ["search-empty", "搜索无结果"],
    ["empty-root", "空书签库"],
    ["empty-folder", "空文件夹"],
    ["loading", "载入中"],
    ["corrupt", "数据文件损坏"],
    ["dir-unavailable", "数据目录不可用"],
    ["conflict", "外部修改冲突"],
  ]},
  { group: "整理与拖拽", items: [
    ["organize", "整理模式"],
    ["drag-reorder", "拖动排序"],
    ["drag-into-folder", "拖入文件夹"],
    ["drag-create-folder", "拖拽创建文件夹"],
  ]},
  { group: "命令行", items: [
    ["prompt-add-url", "add · 网址"],
    ["prompt-add-title", "add · 标题"],
    ["prompt-add-location", "add · 位置补全"],
    ["prompt-add-folder", "add · 新文件夹"],
    ["prompt-edit-title", "edit · 标题"],
    ["prompt-edit-url", "edit · 网址"],
    ["prompt-delete", "delete · 确认"],
    ["prompt-rename", "rename · 文件夹"],
    ["prompt-mkdir", "mkdir · 新建文件夹"],
    ["prompt-move", "move · 目标补全"],
    ["prompt-move-folder", "move · 新文件夹名称"],
    ["prompt-backup", "backup · 路径"],
    ["prompt-restore", "restore · 备份选择"],
    ["prompt-cd", "cd · 目录补全"],
    ["prompt-hotkey", "hotkey · 录入"],
  ]},
  { group: "缓冲区", items: [
    ["buffer-settings", "设置缓冲区"],
    ["buffer-settings-login-approval", "登录项待批准"],
    ["buffer-settings-login-error", "登录项设置失败"],
    ["buffer-settings-hotkey-conflict", "快捷键冲突"],
    ["buffer-settings-corner-error", "触角监听失败"],
    ["buffer-settings-finder-missing", "快跳权限缺失"],
    ["buffer-settings-finder-error", "Finder 读取失败"],
    ["buffer-help", "帮助 · man page"],
    ["buffer-atlas", "界面地图"],
    ["buffer-calc", "计算器"],
    ["buffer-log", "完整日志"],
  ]},
  { group: "任务输出", items: [
    ["job-backup-ok", "备份成功"],
    ["job-backup-error", "备份失败"],
    ["job-restore-invalid", "恢复校验失败"],
    ["job-restore-ok", "恢复成功"],
    ["job-cd-error", "目录权限失败"],
  ]},
  { group: "系统", items: [
    ["filepanel", "Finder 目录浮条"],
    ["filepanel-hidden", "无目录时隐藏"],
  ]},
];
window.FROG_SCENES = FROG_SCENES;

/* ---------------- 基础状态 ---------------- */
const BASE_SETTINGS = {
  dataPath: "~/Library/Application Support/Frog",
  login: false, loginApproval: false, loginError: null,
  hotkey: true, hotkeyText: "Opt+Space", recording: false, hotkeyError: null, hotkeyConflict: false,
  corner: true, cornerText: "left-down", cornerError: null,
  finderJump: false, finderMissing: false, finderConflict: false, finderError: null,
  busy: false,
};

function baseState() {
  return {
    screen: "main",
    buffer: null,
    folderId: null,
    scroll: 0,
    cursor: 0,
    query: "",
    input: null,
    prompt: null,
    history: [],
    histIndex: -1,
    mode: "normal",
    moveSource: null,
    moveTarget: null,
    moveReorder: false,
    doc: frogSeedData(),
    flags: { loading: false, corrupt: false, dirUnavailable: false, conflict: false },
    settings: { ...BASE_SETTINGS },
    flash: null,
    log: [],
    job: null,
    calc: { expr: "", caret: 0, selectionEnd: 0, history: [], histIndex: -1,
      offset: 0, error: null, copied: null },
    atlasCursor: 0,
    filepanel: { hidden: false },
    sceneId: null,
  };
}

/* ---------------- 视图 ---------------- */
function sortedGroups(doc) { return [...doc.groups].sort((a, b) => a.order - b.order); }

function rootItems(doc) {
  const roots = doc.bookmarks.filter((b) => b.groupId == null)
    .map((b) => ({ kind: "bookmark", bm: b, order: b.order }));
  const folders = sortedGroups(doc).map((g) => ({
    kind: "folder", group: g, order: g.order,
    count: doc.bookmarks.filter((b) => b.groupId === g.id).length,
  }));
  return [...folders, ...roots.sort((a, b) => a.order - b.order)];
}

function browseItems(doc, folderId) {
  if (folderId) {
    const list = doc.bookmarks.filter((b) => b.groupId === folderId)
      .sort((a, b) => a.order - b.order)
      .map((b) => ({ kind: "bookmark", bm: b }));
    return [{ kind: "add" }, ...list];
  }
  return rootItems(doc);
}

function searchItems(doc, query) {
  const q = query.trim().toLowerCase();
  if (!q) return [];
  return doc.bookmarks
    .filter((b) => b.title.toLowerCase().includes(q) || b.url.toLowerCase().includes(q))
    .map((b) => ({
      kind: "bookmark", bm: b,
      groupName: b.groupId == null ? "根目录" : (doc.groups.find((g) => g.id === b.groupId) || {}).name,
    }));
}

function buildView(s) {
  let all;
  if (s.query.trim()) all = searchItems(s.doc, s.query);
  else if (s.flags.corrupt) all = [];
  else all = browseItems(s.doc, s.folderId);
  const { visible } = frogListGeom(frogShowsCrumb(s));
  const maxScroll = Math.max(0, all.length - visible);
  let scroll = Math.min(Math.max(0, s.scroll || 0), maxScroll);
  const cursor = Math.min(Math.max(0, s.cursor), Math.max(0, all.length - 1));
  if (cursor < scroll) scroll = cursor;
  else if (cursor >= scroll + visible) scroll = cursor - visible + 1;
  scroll = Math.min(Math.max(0, scroll), maxScroll);
  return { all, items: all, visible, scroll, maxScroll };
}


function groupOptions(doc) {
  return [{ id: "__root__", label: "根目录" }]
    .concat(sortedGroups(doc).map((g) => ({ id: g.id, label: g.name, hint: "分组" })))
    .concat([{ id: "__new__", label: "新建文件夹…", hint: "new" }]);
}

function dirOptions() {
  return [
    { id: "~/Library/Application Support/Frog", label: "~/Library/Application Support/Frog", hint: "当前" },
    { id: "~/Documents/同步/青蛙导航", label: "~/Documents/同步/青蛙导航", hint: "同步" },
    { id: "~/Desktop/无权限目录", label: "~/Desktop/无权限目录", hint: "无权限" },
  ];
}

function backupFiles() {
  return [
    { id: "青蛙导航-Bookmarks-20261101-210500.json", label: "青蛙导航-Bookmarks-20261101-210500.json", hint: "37 条 · 5 组" },
    { id: "青蛙导航-Bookmarks-20261028-090000.json", label: "青蛙导航-Bookmarks-20261028-090000.json", hint: "34 条 · 5 组" },
    { id: "旧备份-损坏.json", label: "旧备份-损坏.json", hint: "损坏" },
  ];
}

function nowTime() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

/* ---------------- 键盘提示 ---------------- */
const SHORTCUTS = [
  [":", "命令模式"], ["/", "搜索"], ["a", "添加书签"], ["n", "新建文件夹"], ["e", "编辑标题 / 网址"],
  ["r", "重命名文件夹"], ["m", "移动"], ["D", "删除"], ["o", "整理"],
  ["C", "复制链接"], ["j/k", "上下选择"],
  ["Shift+↑/↓", "整理时调整顺序"],
  ["Enter", "打开选中项"], ["PgUp/PgDn", "上/下一屏"],
  ["F1", "界面地图"], ["?", "帮助"], ["Esc", "返回上一层"],
];

function App() {
  const [s, setS] = useState(baseState);
  const imeRef = useRef(null);
  const composingRef = useRef(false);
  const calcCaretRef = useRef(null);
  const logSeq = useRef(0);
  const calcSeq = useRef(0);
  const calcCopySeq = useRef(0);
  const histRef = useRef([]);
  const booted = useRef(false);

  const view = useMemo(() => buildView(s), [s]);
  const folderName = s.folderId ? (s.doc.groups.find((g) => g.id === s.folderId) || {}).name || "根目录" : "根目录";
  const groupName = (gid) => gid == null ? "根目录" : (s.doc.groups.find((g) => g.id === gid) || {}).name || "未知分组";

  const pushLog = useCallback((text, kind = "info") => {
    const entry = { seq: ++logSeq.current, time: nowTime(), text, kind };
    setS((p) => ({ ...p, log: [...p.log, entry].slice(-200) }));
  }, []);

  /* 启动日志只写一次 */
  useEffect(() => {
    if (booted.current) return;
    booted.current = true;
    pushLog("frog-nav 1.0.0 · 37 bookmarks · 5 groups · UTF-8", "ok");
    pushLog("输入 : 打开命令 · / 搜索 · ? 帮助", "info");
  }, [pushLog]);

  /* ---------------- 当前输入域 ---------------- */
  const activeText = useMemo(() => {
    if (s.prompt && s.prompt.cmd !== "hotkey" && s.prompt.cmd !== "delete") {
      return { kind: "prompt", key: `${s.prompt.cmd}:${s.prompt.step}`, value: s.prompt.value };
    }
    if (s.input) return { kind: "input", key: "input:" + s.input.kind, value: s.input.value };
    if (s.buffer === "calc") return {
      kind: "calc", key: "calc:expr", value: s.calc.expr,
      caret: s.calc.caret, selectionEnd: s.calc.selectionEnd,
    };
    return null;
  }, [s]);

  const setActiveText = useCallback((value, selection = null, composing = false) => {
    const start = selection ? selection.start : null;
    const end = selection ? selection.end : null;
    setS((p) => {
      if (p.prompt && p.prompt.cmd !== "hotkey" && p.prompt.cmd !== "delete") {
        const candidates = p.prompt.candidates ?? p.prompt.options ?? [];
        const options = candidates.filter((o) => !value || o.label.toLowerCase().includes(value.toLowerCase()) || !p.prompt.filterable);
        return {
          ...p,
          prompt: { ...p.prompt, value, error: null, optIndex: 0, candidates,
            options: p.prompt.filterable ? options : p.prompt.options },
        };
      }
      if (p.input) {
        return {
          ...p,
          input: { ...p.input, value },
          query: p.input.kind === "search" ? value : p.query,
          cursor: p.input.kind === "search" ? 0 : p.cursor,
          scroll: p.input.kind === "search" ? 0 : p.scroll,
        };
      }
      if (p.buffer === "calc") {
        // 输入法组合期间保留原文，提交后再转换，避免打断组合。
        const expr = composing ? value.slice(0, frogCalcMaxLength) : frogCalcFilter(value);
        let caret = Math.min(start == null ? p.calc.caret : start, expr.length);
        let selectionEnd = Math.min(end == null ? p.calc.selectionEnd : end, expr.length);
        if (selectionEnd < caret) selectionEnd = caret;
        // 归一化会改写原生输入框内容，恢复后把光标放回同一位置。
        if (expr !== value) calcCaretRef.current = caret;
        return { ...p, calc: { ...p.calc, expr, caret, selectionEnd, histIndex: -1, error: null, copied: null } };
      }
      return p;
    });
  }, []);

  /* 计算器：把原生输入框的光标/选区同步到状态，SVG 才能画在正确位置。 */
  const syncActiveSelection = useCallback(() => {
    if (composingRef.current || calcCaretRef.current != null) return;
    const el = imeRef.current;
    if (!el) return;
    const start = el.selectionStart ?? 0;
    const end = el.selectionEnd ?? start;
    setS((p) => {
      if (p.buffer !== "calc" || p.input || p.prompt) return p;
      const caret = Math.min(start, p.calc.expr.length);
      const selectionEnd = Math.min(Math.max(caret, end), p.calc.expr.length);
      if (p.calc.caret === caret && p.calc.selectionEnd === selectionEnd) return p;
      return { ...p, calc: { ...p.calc, caret, selectionEnd } };
    });
  }, []);

  const prevActive = useRef(null);
  useEffect(() => {
    const el = imeRef.current;
    if (!el) return;
    if (activeText) {
      const entering = prevActive.current !== activeText.key;
      if (el.value !== activeText.value) el.value = activeText.value;
      if (document.activeElement !== el) el.focus({ preventScroll: true });
      // SVG 没有显示全选状态，进入字段时将光标放到末尾，避免退格清空整段。
      if (calcCaretRef.current != null) {
        const pos = Math.min(calcCaretRef.current, el.value.length);
        el.setSelectionRange(pos, pos);
        calcCaretRef.current = null;
      } else if (entering) {
        const start = activeText.kind === "calc"
          ? Math.min(activeText.caret ?? el.value.length, el.value.length)
          : el.value.length;
        const end = activeText.kind === "calc"
          ? Math.min(Math.max(start, activeText.selectionEnd ?? start), el.value.length)
          : el.value.length;
        el.setSelectionRange(start, end);
      }
    } else if (document.activeElement === el) {
      el.blur();
    }
    prevActive.current = activeText ? activeText.key : null;
  }, [activeText]);

  /* ---------------- 通用动作 ---------------- */
  const openBuffer = (kind) => setS((p) => ({
    ...p, buffer: kind, input: null, prompt: null, screen: "main",
    atlasCursor: kind === "atlas" ? 0 : p.atlasCursor,
  }));
  const closeBuffer = () => setS((p) => ({ ...p, buffer: null }));

  const startCommand = () => setS((p) => ({ ...p, input: { kind: "command", value: "" }, prompt: null, histIndex: -1 }));
  const startSearch = () => setS((p) => ({
    ...p, input: { kind: "search", value: p.query || "" }, query: p.query || "",
    prompt: null, scroll: 0, cursor: 0,
  }));

  const cancelAll = () => setS((p) => {
    if (p.prompt) return { ...p, prompt: null };
    if (p.input) {
      return p.input.kind === "search"
        ? { ...p, input: null, query: "", scroll: 0, cursor: 0 }
        : { ...p, input: null, histIndex: -1 };
    }
    if (p.buffer) return { ...p, buffer: null };
    if (p.screen === "filepanel") return { ...p, screen: "main" };
    if (p.mode !== "normal") return { ...p, mode: "normal", moveSource: null, moveTarget: null, moveReorder: false };
    if (p.query) return { ...p, query: "", scroll: 0, cursor: 0 };
    if (p.folderId) return { ...p, folderId: null, scroll: 0, cursor: 0 };
    return p;
  });

  const focusInput = () => setTimeout(() => {
    const el = imeRef.current;
    if (!el) return;
    el.focus({ preventScroll: true });
    if (s.buffer === "calc" && !s.input && !s.prompt) {
      const start = Math.min(s.calc.caret ?? el.value.length, el.value.length);
      const end = Math.min(Math.max(start, s.calc.selectionEnd ?? start), el.value.length);
      el.setSelectionRange(start, end);
    }
  }, 0);
  const focusInputEnd = () => setTimeout(() => {
    const el = imeRef.current;
    if (!el) return;
    el.focus({ preventScroll: true });
    el.setSelectionRange(el.value.length, el.value.length);
  }, 0);

  /* ---------------- 计算器 ---------------- */
  const evalCalc = () => {
    const expr = s.calc.expr.trim();
    if (!expr) {
      setS((p) => ({ ...p, calc: { ...p.calc, error: { expr: "", message: "请输入算式" } } }));
      return;
    }
    const out = frogCalcTry(expr);
    if (!out.ok) {
      setS((p) => ({ ...p, calc: { ...p.calc, error: { expr, message: out.message } } }));
      return;
    }
    const entry = { id: ++calcSeq.current, time: nowTime(), expr, value: frogCalcFormat(out.value) };
    calcCaretRef.current = expr.length;
    setS((p) => {
      const history = [entry, ...p.calc.history.filter((h) => h.expr !== expr)].slice(0, 50);
      return { ...p, calc: { ...p.calc, expr, caret: expr.length, selectionEnd: expr.length,
        history, histIndex: -1, offset: 0, error: null, copied: null } };
    });
  };

  const browseCalcHistory = (older) => setS((p) => {
    const { history, histIndex } = p.calc;
    if (!history.length) return p;
    const next = histIndex < 0
      ? 0
      : Math.min(history.length - 1, Math.max(0, histIndex + (older ? -1 : 1)));
    if (next === histIndex) return p;
    const expr = history[next].expr;
    let offset = p.calc.offset || 0;
    if (next < offset) offset = next;
    else if (next >= offset + CALC_VISIBLE_ROWS) offset = next - CALC_VISIBLE_ROWS + 1;
    offset = Math.min(Math.max(0, offset), Math.max(0, history.length - CALC_VISIBLE_ROWS));
    calcCaretRef.current = expr.length;
    return { ...p, calc: { ...p.calc, histIndex: next, expr, offset,
      caret: expr.length, selectionEnd: expr.length, error: null } };
  });

  const useCalcEntry = (id) => {
    setS((p) => {
      const index = p.calc.history.findIndex((h) => h.id === id);
      if (index < 0) return p;
      const entry = p.calc.history[index];
      let offset = p.calc.offset || 0;
      if (index < offset) offset = index;
      else if (index >= offset + CALC_VISIBLE_ROWS) offset = index - CALC_VISIBLE_ROWS + 1;
      offset = Math.min(Math.max(0, offset), Math.max(0, p.calc.history.length - CALC_VISIBLE_ROWS));
      return { ...p, calc: { ...p.calc, expr: entry.expr, caret: entry.expr.length,
        selectionEnd: entry.expr.length, histIndex: index, offset, error: null } };
    });
    focusInputEnd();
  };

  const resetCalc = () => {
    calcCaretRef.current = 0;
    setS((p) => ({
      ...p, calc: { expr: "", caret: 0, selectionEnd: 0, history: [], histIndex: -1,
        offset: 0, error: null, copied: null },
    }));
  };

  const flashCalcCopy = (text) => {
    const seq = ++calcCopySeq.current;
    setS((p) => ({ ...p, calc: { ...p.calc, copied: text } }));
    setTimeout(() => {
      if (calcCopySeq.current === seq) setS((p) => ({ ...p, calc: { ...p.calc, copied: null } }));
    }, 1400);
  };

  const copyCalcResult = () => {
    const selected = s.calc.histIndex >= 0 ? s.calc.history[s.calc.histIndex] : null;
    let text = selected ? selected.value : null;
    if (text == null) {
      const expr = s.calc.expr.trim();
      const out = expr ? frogCalcTry(expr) : null;
      if (out && out.ok) text = frogCalcFormat(out.value);
    }
    if (text == null) { flashCalcCopy("✗ 没有可复制的结果"); return; }
    if (!navigator.clipboard) { flashCalcCopy("✗ 复制失败"); return; }
    navigator.clipboard.writeText(text)
      .then(() => flashCalcCopy(`✓ 已复制 ${text}`))
      .catch(() => flashCalcCopy("✗ 复制失败"));
  };

  /* ---------------- 提示流 ---------------- */
  const beginPrompt = (prompt) => setS((p) => ({
    ...p, prompt: { ...prompt, candidates: prompt.options }, input: null,
  }));

  const startAdd = () => {
    beginPrompt({
      cmd: "add", step: 0, label: "url", value: "",
      payload: { url: "" },
      options: [], optIndex: 0, filterable: false,
      hint: "Enter 下一步 · Esc 取消",
    });
  };

  const startEdit = (field = "title") => {
    const it = view.items[s.cursor];
    if (!it || it.kind !== "bookmark") { pushLog("✗ 当前行不是书签", "error"); return; }
    const bm = it.bm;
    beginPrompt({
      cmd: "edit", step: field === "url" ? 1 : 0, label: field, value: bm[field],
      payload: { id: bm.id, field, title: bm.title, url: bm.url },
      options: [], optIndex: 0, filterable: false,
      hint: "Tab/Shift+Tab 切换标题/网址 · Enter 保存全部 · Esc 取消",
    });
  };

  const switchEditField = () => setS((p) => {
    if (p.prompt?.cmd !== "edit") return p;
    const draft = { ...p.prompt.payload, [p.prompt.label]: p.prompt.value };
    const field = p.prompt.label === "title" ? "url" : "title";
    return { ...p, prompt: { ...p.prompt, payload: { ...draft, field },
      label: field, step: field === "url" ? 1 : 0, value: draft[field], error: null } };
  });

  const startRename = () => {
    const it = view.items[s.cursor];
    if (!it || it.kind !== "folder") { pushLog("✗ 请选择文件夹", "error"); return; }
    beginPrompt({
      cmd: "rename", step: 0, label: "name", value: it.group.name,
      payload: { id: it.group.id },
      options: [], optIndex: 0, filterable: false,
      hint: "Enter 保存 · Esc 取消",
    });
  };

  const folderNameError = (name, groups) => {
    if (!name) return "请输入文件夹名称";
    if ([...name].length > 60) return "名称不能超过 60 字";
    if (groups.some((g) => g.name === name)) return `已存在同名文件夹 “${name}”`;
    return null;
  };

  const makeGroup = (groups, name) => ({
    id: "g-" + Math.random().toString(36).slice(2, 8),
    name,
    order: groups.reduce((m, g) => Math.max(m, g.order), 0) + 3,
  });

  const createFolder = (rawName) => {
    const name = (rawName || "").trim();
    const error = folderNameError(name, s.doc.groups);
    if (error) return error;
    const group = makeGroup(s.doc.groups, name);
    setS((p) => {
      const doc = { ...p.doc, groups: [...p.doc.groups, group] };
      const inRoot = !p.query.trim() && !p.folderId;
      return {
        ...p, doc,
        cursor: inRoot ? doc.groups.length - 1 : p.cursor,
        log: [...p.log, { seq: ++logSeq.current, time: nowTime(), text: `✓ 已创建文件夹 “${name}”`, kind: "ok" }],
      };
    });
    return null;
  };

  const beginMkdir = () => beginPrompt({
    cmd: "mkdir", step: 0, label: "name", value: "",
    payload: {}, options: [], optIndex: 0, filterable: false,
    hint: "Enter 创建 · Esc 取消",
  });

  const beginDelete = (it = view.items[s.cursor]) => {
    if (!it || (it.kind !== "bookmark" && it.kind !== "folder")) { pushLog("✗ 当前行不可删除", "error"); return; }
    setCursor(view.items.indexOf(it));
    beginPrompt({
      cmd: "delete", step: 0, label: "confirm", value: "",
      payload: { kind: it.kind, id: it.kind === "bookmark" ? it.bm.id : it.group.id,
        title: it.kind === "bookmark" ? it.bm.title : it.group.name },
      options: [], optIndex: 0, filterable: false,
      hint: `删除“${it.kind === "bookmark" ? it.bm.title : it.group.name}”？ y 删除 · n 取消`,
    });
  };

  const beginMove = () => {
    const it = view.items[s.cursor];
    if (!it || it.kind !== "bookmark") { pushLog("✗ 请选择书签", "error"); return; }
    const options = groupOptions(s.doc).filter((o) => o.id !== it.bm.groupId);
    beginPrompt({
      cmd: "move", step: 0, label: "to", value: options[0]?.label || "",
      payload: { id: it.bm.id }, options, optIndex: 0, filterable: true,
      hint: "Tab 补全 · Enter 移动 · Esc 取消",
    });
  };

  const beginBackup = () => {
    const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 15);
    beginPrompt({
      cmd: "backup", step: 0, label: "path",
      value: `~/Documents/青蛙导航-Bookmarks-${stamp}.json`,
      payload: {}, options: dirOptions(), optIndex: 0, filterable: false,
      hint: "Enter 导出 · Tab 选择目录 · Esc 取消",
    });
  };

  const beginRestore = () => {
    beginPrompt({
      cmd: "restore", step: 0, label: "file", value: backupFiles()[0].label,
      payload: {}, options: backupFiles(), optIndex: 0, filterable: true,
      hint: "Tab 选择备份 · Enter 恢复 · Esc 取消",
    });
  };

  const beginCd = () => {
    beginPrompt({
      cmd: "cd", step: 0, label: "path", value: dirOptions()[0].label,
      payload: {}, options: dirOptions(), optIndex: 0, filterable: true,
      hint: "Tab 补全 · Enter 切换 · Esc 取消",
    });
  };

  const beginHotkey = () => {
    beginPrompt({
      cmd: "hotkey", step: 0, label: "press keys", value: "",
      payload: {}, options: [], optIndex: 0, filterable: false,
      hint: "按下组合键 · Esc 取消",
    });
  };

  const closePrompt = () => setS((p) => ({ ...p, prompt: null }));

  /* ---------------- 提交提示 ---------------- */
  const commitAdd = (payload) => {
    setS((p) => {
      const doc = { groups: [...p.doc.groups], bookmarks: [...p.doc.bookmarks] };
      let gid = payload.location;
      if (gid === "__root__") gid = null;
      if (payload.newFolder) {
        const id = "g-" + Math.random().toString(36).slice(2, 8);
        const order = doc.groups.reduce((m, g) => Math.max(m, g.order), 0) + 3;
        doc.groups.push({ id, name: payload.newFolder, order });
        gid = id;
      }
      const order = doc.bookmarks.filter((b) => b.groupId === gid).reduce((m, b) => Math.max(m, b.order), 0) + 1;
      doc.bookmarks.push({
        id: "b-" + Math.random().toString(36).slice(2, 9),
        title: payload.title, url: payload.url, groupId: gid, order,
        createdAt: Date.now(),
      });
      return {
        ...p, doc, prompt: null,
        log: [...p.log, { seq: ++logSeq.current, time: nowTime(),
          text: `✓ 已添加 “${payload.title}” → ${gid ? groupName(gid) : "根目录"}`, kind: "ok" }],
      };
    });
  };

  const previousPrompt = () => {
    setS((p) => {
      const pr = p.prompt;
      if (!pr) return p;
      if (pr.cmd === "move" && pr.step === 1) {
        const bm = p.doc.bookmarks.find((b) => b.id === pr.payload.id) || null;
        const options = groupOptions(p.doc).filter((o) => o.id !== (bm ? bm.groupId : null));
        const idx = Math.max(0, options.findIndex((o) => o.id === "__new__"));
        return { ...p, prompt: { ...pr, step: 0, label: "to", value: options[idx].label,
          options, candidates: options, optIndex: idx, filterable: true, error: null,
          hint: "Tab 补全 · Enter 移动 · Esc 取消" } };
      }
      if (pr.cmd !== "add" || pr.step === 0) return p;
      if (pr.step === 1) {
        return { ...p, prompt: { ...pr, step: 0, label: "url", value: pr.payload.url || "",
          payload: { ...pr.payload, title: pr.value },
          options: [], candidates: [], optIndex: 0, filterable: false, error: null,
          hint: "Enter 下一步 · Esc 取消" } };
      }
      if (pr.step === 2) {
        return { ...p, prompt: { ...pr, step: 1, label: "title", value: pr.payload.title ?? "",
          payload: { ...pr.payload, locationId: pr.options[pr.optIndex]?.id ?? pr.payload.locationId },
          options: [], candidates: [], optIndex: 0, filterable: false, error: null,
          hint: "Enter 下一步 · Shift+Tab 返回 · Esc 取消" } };
      }
      if (pr.step === 3) {
        const options = groupOptions(p.doc);
        const idx = Math.max(0, options.findIndex((o) => o.id === "__new__"));
        return { ...p, prompt: { ...pr, step: 2, label: "location", value: options[idx].label,
          payload: { ...pr.payload, folderName: pr.value },
          options, candidates: options, optIndex: idx, filterable: true, error: null,
          hint: "Tab 补全 · Shift+Tab 返回 · Enter 选择" } };
      }
      return p;
    });
  };

  const submitPrompt = () => {
    const p = s.prompt;
    if (!p) return;
    const value = p.value.trim();

    if (p.cmd === "add") {
      if (p.step === 0) {
        if (!value) { setS((x) => ({ ...x, prompt: { ...x.prompt, error: "请输入网址" } })); return; }
        const url = /^https?:\/\//i.test(value) ? value : "https://" + value;
        try { new URL(url); } catch (e) {
          setS((x) => ({ ...x, prompt: { ...x.prompt, error: "网址无效，仅支持 http / https" } })); return;
        }
        const title = p.payload.title ?? hostOf(url);
        setS((x) => ({
          ...x,
          prompt: { ...x.prompt, step: 1, label: "title", value: title, error: null,
            payload: { ...x.prompt.payload, url } },
        }));
      } else if (p.step === 1) {
        if (!value) { setS((x) => ({ ...x, prompt: { ...x.prompt, error: "标题不能为空" } })); return; }
        if ([...value].length > 120) { setS((x) => ({ ...x, prompt: { ...x.prompt, error: "标题不能超过 120 字" } })); return; }
        const options = groupOptions(s.doc);
        const optIndex = Math.max(0, options.findIndex((o) => o.id === p.payload.locationId));
        setS((x) => ({
          ...x,
          prompt: { ...x.prompt, step: 2, label: "location", value: options[optIndex].label,
            payload: { ...x.prompt.payload, title: value }, options, candidates: options, optIndex, filterable: true, error: null },
        }));
      } else if (p.step === 2) {
        const opt = p.options[p.optIndex] || p.options.find((o) => o.label === value);
        if (!opt) { setS((x) => ({ ...x, prompt: { ...x.prompt, error: "请选择位置" } })); return; }
        if (opt.id === "__new__") {
          setS((x) => ({ ...x, prompt: { ...x.prompt, step: 3, label: "folder", value: x.prompt.payload.folderName ?? "",
            payload: { ...x.prompt.payload, locationId: "__new__" },
            options: [], candidates: [], filterable: false, error: null } }));
          return;
        }
        commitAdd({ ...p.payload, location: opt.id });
      } else {
        if (!value) { setS((x) => ({ ...x, prompt: { ...x.prompt, error: "请输入文件夹名称" } })); return; }
        commitAdd({ ...p.payload, location: "__root__", newFolder: value });
      }
      return;
    }

    if (p.cmd === "edit") {
      const draft = { ...p.payload, [p.label]: p.value };
      const title = draft.title.trim();
      const rawURL = draft.url.trim();
      let url = rawURL;
      let errorField = "title";
      let error = !title ? "标题不能为空" : [...title].length > 120 ? "标题不能超过 120 字" : null;
      if (!error) {
        errorField = "url";
        if (!rawURL) error = "请输入网址";
        else {
          url = /^[a-z][a-z\d+.-]*:/i.test(rawURL) ? rawURL : "https://" + rawURL;
          try {
            const parsed = new URL(url);
            if (parsed.protocol !== "http:" && parsed.protocol !== "https:") error = "网址仅支持 http / https";
          } catch {
            error = "网址无效，请输入有效域名或 http/https 网址";
          }
        }
      }
      if (error) {
        setS((x) => ({ ...x, prompt: { ...x.prompt, payload: { ...draft, field: errorField },
          label: errorField, step: errorField === "url" ? 1 : 0, value: draft[errorField], error } }));
        return;
      }
      setS((x) => ({
        ...x,
        doc: { ...x.doc, bookmarks: x.doc.bookmarks.map((b) => b.id === draft.id ? { ...b, title, url } : b) },
        prompt: null,
        log: [...x.log, { seq: ++logSeq.current, time: nowTime(), text: `✓ 已保存 “${title}” · ${url}`, kind: "ok" }],
      }));
      return;
    }

    if (p.cmd === "rename") {
      if (!value) { setS((x) => ({ ...x, prompt: { ...x.prompt, error: "名称不能为空" } })); return; }
      if ([...value].length > 60) { setS((x) => ({ ...x, prompt: { ...x.prompt, error: "名称不能超过 60 字" } })); return; }
      setS((x) => {
        const doc = { ...x.doc, groups: x.doc.groups.map((g) => g.id === p.payload.id ? { ...g, name: value } : g) };
        return {
          ...x, doc, prompt: null,
          log: [...x.log, { seq: ++logSeq.current, time: nowTime(), text: `✓ 已重命名为 “${value}”`, kind: "ok" }],
        };
      });
      return;
    }

    if (p.cmd === "mkdir") {
      const error = createFolder(value);
      if (error) { setS((x) => ({ ...x, prompt: { ...x.prompt, error } })); return; }
      setS((x) => ({ ...x, prompt: null }));
      return;
    }

    if (p.cmd === "move") {
      if (p.step === 1) {
        const error = folderNameError(value, s.doc.groups);
        if (error) { setS((x) => ({ ...x, prompt: { ...x.prompt, error } })); return; }
        setS((x) => {
          const group = makeGroup(x.doc.groups, value);
          const doc = {
            ...x.doc,
            groups: [...x.doc.groups, group],
            bookmarks: x.doc.bookmarks.map((b) => b.id === p.payload.id ? { ...b, groupId: group.id } : b),
          };
          return {
            ...x, doc, prompt: null,
            log: [...x.log, { seq: ++logSeq.current, time: nowTime(),
              text: `✓ 已移动到 “${value}”（新建文件夹）`, kind: "ok" }],
          };
        });
        return;
      }
      const opt = p.options[p.optIndex] || p.options.find((o) => o.label === value);
      if (!opt) { setS((x) => ({ ...x, prompt: { ...x.prompt, error: "请选择目标" } })); return; }
      if (opt.id === "__new__") {
        setS((x) => ({ ...x, prompt: { ...x.prompt, step: 1, label: "name", value: "",
          options: [], candidates: [], filterable: false, error: null,
          hint: "Enter 创建并移动 · Shift+Tab 返回 · Esc 取消" } }));
        return;
      }
      setS((x) => {
        const gid = opt.id === "__root__" ? null : opt.id;
        const doc = { ...x.doc, bookmarks: x.doc.bookmarks.map((b) => b.id === p.payload.id ? { ...b, groupId: gid } : b) };
        return {
          ...x, doc, prompt: null,
          log: [...x.log, { seq: ++logSeq.current, time: nowTime(),
            text: `✓ 已移动到 “${gid ? (doc.groups.find((g) => g.id === gid) || {}).name : "根目录"}”`, kind: "ok" }],
        };
      });
      return;
    }

    if (p.cmd === "backup") runBackup(value);
    if (p.cmd === "restore") runRestore(value);
    if (p.cmd === "cd") runCd(value);
  };

  /* ---------------- 任务输出 ---------------- */
  const runJob = (title, lines, status, extra) => {
    setS((p) => ({ ...p, buffer: "job", prompt: null, input: null,
      job: { title, status, lines, ...extra } }));
  };

  const runBackup = (path) => {
    if (!path) { pushLog("✗ 备份路径为空", "error"); return; }
    setS((p) => ({ ...p, prompt: null, buffer: "job",
      job: { title: "backup", status: "running",
        lines: [
          { text: `$ frog backup --out "${path}"`, kind: "cmd" },
          { text: "写出 bookmarks.json 快照…", kind: "info" },
        ] },
    }));
    setTimeout(() => {
      setS((p) => {
        if (!p.job) return p;
        if (/无权限|fail/i.test(path)) {
          return { ...p, job: { ...p.job, status: "error", lines: [
            ...p.job.lines,
            { text: "✗ 无法写入备份：目标目录没有写权限。", kind: "error" },
            { text: `当前数据未被修改。可重试 :backup ~/Documents/…`, kind: "muted" },
          ] } };
        }
        return { ...p, job: { ...p.job, status: "ok", lines: [
          ...p.job.lines,
          { text: `✓ 已写入 ${path}`, kind: "ok" },
          { text: `包含 ${p.doc.bookmarks.length} 条书签 · ${p.doc.groups.length} 个分组 · 不含本机偏好`, kind: "muted" },
        ] } };
      });
    }, 650);
  };

  const runRestore = (file) => {
    setS((p) => ({ ...p, prompt: null, buffer: "job",
      job: { title: "restore", status: "running", lines: [
        { text: `$ frog restore "${file}"`, kind: "cmd" },
        { text: "解析 JSON · 校验 schemaVersion / ID 唯一性 / 分组引用…", kind: "info" },
      ] },
    }));
    setTimeout(() => {
      setS((p) => {
        if (!p.job) return p;
        if (/损坏/.test(file)) {
          return { ...p, job: { ...p.job, status: "error", lines: [
            ...p.job.lines,
            { text: "✗ 校验失败：书签引用了不存在的分组 g-404。", kind: "error" },
            { text: "当前数据保持完整，未写入任何内容。", kind: "muted" },
          ] } };
        }
        return { ...p, job: { ...p.job, status: "ok", lines: [
          ...p.job.lines,
          { text: `✓ 恢复完成：${p.doc.bookmarks.length} 条书签 · ${p.doc.groups.length} 个分组`, kind: "ok" },
          { text: "数据目录位置不变；外部同步工具会继续同步结果。", kind: "muted" },
        ] } };
      });
    }, 700);
  };

  const runCd = (path) => {
    if (!path) { pushLog("✗ 目录路径为空", "error"); return; }
    setS((p) => ({ ...p, prompt: null, buffer: "job",
      job: { title: "cd", status: "running", lines: [
        { text: `$ frog cd "${path}"`, kind: "cmd" },
        { text: "检查 bookmarks.json 与读写权限…", kind: "info" },
      ] },
    }));
    setTimeout(() => {
      setS((p) => {
        if (!p.job) return p;
        if (/无权限/.test(path)) {
          return { ...p, job: { ...p.job, status: "error", lines: [
            ...p.job.lines,
            { text: "✗ 没有读取该目录的权限。原数据目录保持不变。", kind: "error" },
            { text: "可重新执行 :cd 选择其他目录。", kind: "muted" },
          ] } };
        }
        return {
          ...p,
          job: { ...p.job, status: "ok", lines: [
            ...p.job.lines,
            { text: `✓ 数据目录已切换到 ${path}`, kind: "ok" },
            { text: "bookmarks.json 已读取；旧目录数据保留。", kind: "muted" },
          ] },
          settings: { ...p.settings, dataPath: path },
        };
      });
    }, 600);
  };

  /* ---------------- 命令执行 ---------------- */
  const runCommand = (raw) => {
    const cmd = raw.trim();
    if (!cmd) return;
    const [nameRaw, ...rest] = cmd.split(/\s+/);
    const name = nameRaw.toLowerCase();
    const arg = rest.join(" ");
    const finish = (text, kind) => pushLog(text, kind);

    if (name === "add" || name === "a") { startAdd(); return; }
    if (name === "edit" || name === "e") { startEdit(arg === "url" ? "url" : "title"); return; }
    if (name === "rename" || name === "r") { startRename(); return; }
    if (name === "delete" || name === "del") { beginDelete(); return; }
    if (name === "move" || name === "mv") { beginMove(); return; }
    if (name === "backup" || name === "b") { if (arg) runBackup(arg); else beginBackup(); return; }
    if (name === "restore") { if (arg) runRestore(arg); else beginRestore(); return; }
    if (name === "cd") { if (arg) runCd(arg); else beginCd(); return; }
    if (name === "help" || name === "man") { openBuffer("help"); return; }
    if (name === "atlas" || name === "map") { openBuffer("atlas"); return; }
    if (name === "log" || name === "logs") { openBuffer("log"); return; }
    if (name === "retry") {
      setS((p) => ({ ...p, flags: { ...p.flags, corrupt: false, dirUnavailable: false, conflict: false } }));
      finish("✓ 已重新载入数据", "ok"); return;
    }
    if (name === "clear") { setS((p) => ({ ...p, log: [] })); return; }
    if (name === "q" || name === "quit") { finish("原型不退出：真实应用中对应 ⌘Q", "info"); return; }
    if (name === "open" || name === "o") {
      const n = parseInt(arg, 10);
      const it = view.items[n - 1];
      if (it && it.kind === "bookmark") openBookmark(it.bm.id);
      else if (it && it.kind === "folder") openFolder(it.group.id);
      else finish(`✗ 没有第 ${arg || "?"} 个可打开项`, "error");
      return;
    }
    if (name === "copy") {
      const it = view.items[s.cursor];
      if (it && it.kind === "bookmark") copyBookmark(it.bm.id);
      else finish("✗ 请选择书签", "error");
      return;
    }
    if (name === "mkdir" || name === "md") {
      if (!arg) { beginMkdir(); return; }
      const error = createFolder(arg);
      if (error) finish(`✗ ${error}`, "error");
      return;
    }
    if (name === "group" || name === "g") {
      const g = s.doc.groups.find((x) => x.name.startsWith(arg));
      if (g) openFolder(g.id);
      else if (arg === "根目录") closeFolder();
      else finish(`✗ 找不到文件夹 “${arg}”`, "error");
      return;
    }
    if (name === "find") { setS((p) => ({ ...p, input: { kind: "search", value: arg }, query: arg, scroll: 0, cursor: 0 })); return; }
    if (name === "calc" || name === "calculator") {
      if (arg) {
        if (arg.toLowerCase() === "clear") {
          resetCalc();
          finish("✓ 计算器已清空", "ok");
        } else {
          finish("✗ 用法：:calc 打开计算器，:calc clear 清空", "error");
        }
        return;
      }
      openBuffer("calc");
      return;
    }
    if (name === "set") { runSet(rest[0], rest.slice(1).join(" ")); return; }
    finish(`✗ 未知命令 “${nameRaw}” · 输入 :help 查看命令`, "error");
  };

  const runSet = (key, value) => {
    if (!key) { openBuffer("settings"); return; }
    const k = key.toLowerCase();
    const v = value.trim().toLowerCase();
    if (k === "login") {
      if (v === "approve") {
        setS((p) => ({ ...p, settings: { ...p.settings, loginApproval: false, loginError: null } }));
        pushLog("✓ 登录项已获系统批准", "ok");
        return;
      }
      const on = v === "on" || v === "true" || v === "1";
      setS((p) => ({ ...p, settings: { ...p.settings, login: on, loginApproval: on, loginError: null } }));
      pushLog(on ? "登录时启动：等待系统批准（:set login approve 模拟批准）" : "✓ 已关闭登录时启动", on ? "warn" : "ok");
      return;
    }
    if (k === "hotkey") {
      if (v === "record") { beginHotkey(); return; }
      if (v === "reset") {
        setS((p) => ({ ...p, settings: { ...p.settings, hotkeyText: "Opt+Space", hotkeyError: null, hotkeyConflict: false } }));
        pushLog("✓ 已恢复默认快捷键 ⌥ Space", "ok"); return;
      }
      const on = v === "on" || v === "true" || v === "1";
      setS((p) => ({ ...p, settings: { ...p.settings, hotkey: on } }));
      pushLog(on ? "✓ 已启用全局快捷键" : "全局快捷键已关闭", on ? "ok" : "info"); return;
    }
    if (k === "corner") {
      const corners = ["left-up", "left-down", "right-up", "right-down"];
      if (!corners.includes(value)) { pushLog("✗ corner 只能是 left-up / left-down / right-up / right-down", "error"); return; }
      flashSetting("corner");
      setS((p) => ({ ...p, settings: { ...p.settings, corner: true, cornerText: value, cornerError: null } }));
      pushLog(`✓ 屏幕触角：${value}`, "ok"); return;
    }
    if (k === "finder") {
      if (v === "authorize") {
        setS((p) => ({ ...p, settings: { ...p.settings, finderMissing: false, finderError: null } }));
        pushLog("✓ 已获得辅助功能与 Finder 自动化权限", "ok"); return;
      }
      const on = v === "on" || v === "true" || v === "1";
      setS((p) => ({ ...p, settings: {
        ...p.settings, finderJump: on,
        finderMissing: on,
        finderConflict: on && p.settings.hotkeyText === "Ctrl+G",
      } }));
      pushLog(on ? "Finder 快跳：需要辅助功能权限（:set finder authorize 模拟授权）" : "Finder 目录快跳已关闭", on ? "warn" : "info");
      return;
    }
    if (k === "data") { if (value) runCd(value); else beginCd(); return; }
    pushLog(`✗ 未知设置项 “${key}” · 可用 login / hotkey / corner / finder / data`, "error");
  };

  /* ---------------- 书签动作 ---------------- */
  // 点击结果结束搜索/命令输入，但保留筛选；未提交提示流仍由 Esc 显式取消。
  const setCursor = (cursor) => {
    if (s.prompt) {
      if (activeText) imeRef.current?.focus({ preventScroll: true });
      return;
    }
    setS((p) => ({ ...p, cursor, input: null }));
  };
  const openFolder = (id) => {
    const has = s.doc.bookmarks.some((b) => b.groupId === id);
    setS((p) => ({ ...p, folderId: id, scroll: 0, cursor: has ? 1 : 0, query: "", input: null }));
  };
  const closeFolder = () => setS((p) => ({ ...p, folderId: null, scroll: 0, cursor: 0, query: "", input: null }));
  // 滚轮按行滚动，同时把选中项带进可视区；提示流未提交时不接管滚动。
  const scrollBy = (delta) => setS((p) => {
    if (p.prompt) return p;
    const v = buildView(p);
    const scroll = Math.min(v.maxScroll, Math.max(0, v.scroll + delta));
    const cursor = Math.min(Math.max(p.cursor, scroll), Math.max(0, Math.min(v.items.length - 1, scroll + v.visible - 1)));
    return { ...p, scroll, cursor };
  });
  const activate = () => {
    const it = view.items[s.cursor];
    if (!it) return;
    if (it.kind === "add") startAdd();
    else if (it.kind === "folder") openFolder(it.group.id);
    else openBookmark(it.bm.id);
  };
  const openBookmark = (id) => {
    const bm = s.doc.bookmarks.find((b) => b.id === id);
    if (!bm) return;
    pushLog(`✓ 已打开 ${bm.title} · ${bm.url}`, "ok");
    setS((p) => ({ ...p, input: null, prompt: null }));
  };
  const copyBookmark = (id) => {
    const bm = s.doc.bookmarks.find((b) => b.id === id);
    if (!bm) return;
    if (navigator.clipboard) navigator.clipboard.writeText(bm.url).catch(() => {});
    pushLog(`✓ 已复制链接 ${hostOf(bm.url)}`, "ok");
  };
  const toggleOrganize = () => {
    if (s.mode !== "organize" && s.query.trim()) {
      pushLog("搜索结果不能排序；先按 Esc 清空搜索，再按 o 整理。", "warn");
      return;
    }
    setS((p) => ({ ...p, mode: p.mode === "organize" ? "normal" : "organize",
      moveSource: null, moveTarget: null }));
  };

  const reorderSelected = (direction) => setS((p) => {
    if (p.mode !== "organize" || p.query.trim()) return p;
    const current = buildView(p);
    const selected = current.items[p.cursor];
    if (!selected || selected.kind !== "bookmark") return p;
    const items = current.all.filter((item) => item.kind === "bookmark");
    const from = items.findIndex((item) => item.bm.id === selected.bm.id);
    const to = from + direction;
    if (from < 0 || to < 0 || to >= items.length) return p;
    [items[from], items[to]] = [items[to], items[from]];
    const orders = new Map(items.map((item, i) => [item.bm.id, i + 1]));
    const withOrder = (item) => {
      const order = orders.get(item.id);
      return order === undefined || order === item.order ? item : { ...item, order };
    };
    const position = to + current.all.length - items.length;
    return { ...p,
      doc: { ...p.doc, bookmarks: p.doc.bookmarks.map(withOrder) },
      cursor: position,
    };
  });
  const startMove = beginMove;
  const requestDelete = beginDelete;

  /* ---------------- 设置反馈 ---------------- */
  /* 设置缓冲区里改值时高亮该行：缓冲区视图不显示日志区，需要就地反馈 */
  const flashSetting = (key) => {
    const flash = { key };
    setS((p) => ({ ...p, flash }));
    setTimeout(() => setS((p) => (p.flash === flash ? { ...p, flash: null } : p)), 900);
  };

  /* ---------------- 输入提交 ---------------- */
  const submitInput = () => {
    if (s.prompt) { submitPrompt(); return; }
    if (!s.input) return;
    if (s.input.kind === "command") {
      const cmd = s.input.value.trim();
      setS((p) => ({ ...p, input: null, histIndex: -1, history: cmd ? [...p.history, cmd].slice(-50) : p.history }));
      runCommand(cmd);
      return;
    }
    const q = s.input.value.trim();
    if (!q) { cancelAll(); return; }
    const it = view.items[s.cursor];
    if (it && it.kind === "bookmark") openBookmark(it.bm.id);
    else if (it && it.kind === "folder") openFolder(it.group.id);
    else pushLog(`↗ 用默认浏览器搜索 “${q}”`, "info");
  };

  /* ---------------- 场景 ---------------- */
  function makeJob(title, status, lines) { return { title, status, lines }; }

  const jumpScene = (id) => {
    const st = baseState();
    const bms = st.doc.bookmarks;
    const withPrompt = (over) => ({ ...st, screen: "main", ...over });
    let next = { ...st, sceneId: id };
    switch (id) {
      case "main-root": break;
      case "main-folder": next = { ...next, folderId: "g-dev", cursor: 1 }; break;
      case "search": next = { ...next, query: "git", cursor: 0 }; break;
      case "search-focus": next = { ...next, query: "git", input: { kind: "search", value: "git" } }; break;
      case "search-empty": next = { ...next, query: "zzzz", cursor: 0 }; break;
      case "empty-root": next = { ...next, doc: { groups: [], bookmarks: [] } }; break;
      case "empty-folder": {
        const doc = { groups: [...st.doc.groups, { id: "g-empty", name: "新建文件夹", order: 18 }], bookmarks: st.doc.bookmarks };
        next = { ...next, doc, folderId: "g-empty", cursor: 0 }; break;
      }
      case "loading": next = { ...next, flags: { ...st.flags, loading: true } }; break;
      case "corrupt": next = { ...next, flags: { ...st.flags, corrupt: true },
        log: [{ seq: 1, time: nowTime(), kind: "error", text: "bookmarks.json 损坏：第 12 行缺少字段 url。原文件已保留，未写入新数据。" },
              { seq: 2, time: nowTime(), kind: "muted", text: "修复文件后执行 :retry 重新载入，或 :cd 切换目录。" }] }; break;
      case "dir-unavailable": next = { ...next, flags: { ...st.flags, dirUnavailable: true },
        log: [{ seq: 1, time: nowTime(), kind: "warn", text: "数据目录不可用：~/Documents/同步/青蛙导航 未挂载。写操作已暂停。" },
              { seq: 2, time: nowTime(), kind: "muted", text: "恢复挂载后 :retry，或 :cd 选择其他目录。" }] }; break;
      case "conflict": next = { ...next,
        log: [{ seq: 1, time: nowTime(), kind: "warn", text: "数据文件已被外部修改，本次修改未保存。" },
              { seq: 2, time: nowTime(), kind: "muted", text: "执行 :retry 载入最新数据后重试。" }] }; break;
      case "organize": next = { ...next, mode: "organize", cursor: st.doc.groups.length + 1 }; break;
      case "drag-reorder": next = { ...next, mode: "move", cursor: st.doc.groups.length + 1, moveSource: bms[1].id, moveReorder: true, moveTarget: st.doc.groups.length + 2 }; break;
      case "drag-into-folder": next = { ...next, mode: "move", cursor: st.doc.groups.length + 1, moveSource: bms[1].id, moveTarget: 0 }; break;
      case "drag-create-folder": next = { ...next, mode: "move", cursor: st.doc.groups.length, moveSource: bms[0].id, moveTarget: st.doc.groups.length + 1 }; break;
      case "prompt-add-url": next = withPrompt({ prompt: { cmd: "add", step: 0, label: "url", value: "", payload: { url: "", title: "" }, options: [], optIndex: 0, hint: "Enter 下一步 · Esc 取消" } }); break;
      case "prompt-add-title": next = withPrompt({ prompt: { cmd: "add", step: 1, label: "title", value: "GitHub", payload: { url: "https://github.com", title: "" }, options: [], optIndex: 0, hint: "Enter 下一步 · Esc 取消" } }); break;
      case "prompt-add-location": next = withPrompt({ prompt: { cmd: "add", step: 2, label: "location", value: "开发工具", payload: { url: "https://example.com", title: "示例书签" }, options: groupOptions(st.doc), optIndex: 1, filterable: true, hint: "Tab 补全 · Enter 选择 · Esc 取消" } }); break;
      case "prompt-add-folder": next = withPrompt({ prompt: { cmd: "add", step: 3, label: "folder", value: "", payload: { url: "https://example.com", title: "示例书签" }, options: [], optIndex: 0, hint: "Enter 创建 · Esc 取消" } }); break;
      case "prompt-edit-title": next = withPrompt({ cursor: st.doc.groups.length, prompt: { cmd: "edit", step: 0, label: "title", value: bms[0].title, payload: { id: bms[0].id, field: "title", title: bms[0].title, url: bms[0].url }, options: [], optIndex: 0, hint: "Tab/Shift+Tab 切换标题/网址 · Enter 保存全部 · Esc 取消" } }); break;
      case "prompt-edit-url": next = withPrompt({ cursor: st.doc.groups.length, prompt: { cmd: "edit", step: 1, label: "url", value: bms[0].url, payload: { id: bms[0].id, field: "url", title: bms[0].title, url: bms[0].url }, options: [], optIndex: 0, hint: "Tab/Shift+Tab 切换标题/网址 · Enter 保存全部 · Esc 取消" } }); break;
      case "prompt-delete": next = withPrompt({ cursor: st.doc.groups.length, prompt: { cmd: "delete", step: 0, label: "confirm", value: "", payload: { kind: "bookmark", id: bms[0].id, title: bms[0].title }, options: [], optIndex: 0, hint: `删除“${bms[0].title}”？ y 删除 · n 取消` } }); break;
      case "prompt-rename": next = withPrompt({ prompt: { cmd: "rename", step: 0, label: "name", value: "开发工具", payload: { id: "g-dev" }, options: [], optIndex: 0, hint: "Enter 保存 · Esc 取消" } }); break;
      case "prompt-mkdir": next = withPrompt({ prompt: { cmd: "mkdir", step: 0, label: "name", value: "", payload: {}, options: [], optIndex: 0, hint: "Enter 创建 · Esc 取消" } }); break;
      case "prompt-move": next = withPrompt({ cursor: st.doc.groups.length, prompt: { cmd: "move", step: 0, label: "to", value: "开发工具", payload: { id: bms[0].id }, options: groupOptions(st.doc).filter((o) => o.id !== bms[0].groupId), optIndex: 1, filterable: true, hint: "Tab 补全 · Enter 移动 · Esc 取消" } }); break;
      case "prompt-move-folder": next = withPrompt({ cursor: st.doc.groups.length, prompt: { cmd: "move", step: 1, label: "name", value: "", payload: { id: bms[0].id }, options: [], optIndex: 0, hint: "Enter 创建并移动 · Shift+Tab 返回 · Esc 取消" } }); break;
      case "prompt-backup": next = withPrompt({ prompt: { cmd: "backup", step: 0, label: "path", value: "~/Documents/青蛙导航-Bookmarks-20261104.json", payload: {}, options: dirOptions(), optIndex: 0, hint: "Enter 导出 · Tab 选择目录 · Esc 取消" } }); break;
      case "prompt-restore": next = withPrompt({ prompt: { cmd: "restore", step: 0, label: "file", value: backupFiles()[0].label, payload: {}, options: backupFiles(), optIndex: 0, filterable: true, hint: "Tab 选择 · Enter 恢复 · Esc 取消" } }); break;
      case "prompt-cd": next = withPrompt({ prompt: { cmd: "cd", step: 0, label: "path", value: dirOptions()[1].label, payload: {}, options: dirOptions(), optIndex: 1, filterable: true, hint: "Tab 补全 · Enter 切换 · Esc 取消" } }); break;
      case "prompt-hotkey": next = withPrompt({ prompt: { cmd: "hotkey", step: 0, label: "press keys", value: "", payload: {}, options: [], optIndex: 0, hint: "按下组合键 · Esc 取消" } }); break;
      case "buffer-settings": next = { ...next, buffer: "settings" }; break;
      case "buffer-settings-login-approval": next = { ...next, buffer: "settings", settings: { ...st.settings, login: true, loginApproval: true } }; break;
      case "buffer-settings-login-error": next = { ...next, buffer: "settings", settings: { ...st.settings, login: true, loginError: "无法更新登录项：系统拒绝了注册请求。" } }; break;
      case "buffer-settings-hotkey-conflict": next = { ...next, buffer: "settings", settings: { ...st.settings, hotkeyConflict: true, hotkeyError: "快捷键已被其他应用占用，原绑定未生效。" } }; break;
      case "buffer-settings-corner-error": next = { ...next, buffer: "settings", settings: { ...st.settings, cornerError: "无法监听鼠标事件，屏幕触角未生效。" } }; break;
      case "buffer-settings-finder-missing": next = { ...next, buffer: "settings", settings: { ...st.settings, finderJump: true, finderMissing: true } }; break;
      case "buffer-settings-finder-error": next = { ...next, buffer: "settings", settings: { ...st.settings, finderJump: true, finderError: "无法读取 Finder 窗口：自动化权限被拒绝。" } }; break;
      case "buffer-calc":
        calcSeq.current = 3;
        next = { ...next, buffer: "calc", calc: {
          expr: "12 * (8 - 3)",
          caret: 12,
          selectionEnd: 12,
          history: [
            { id: 1, time: "09:41:02", expr: "12 * (8 - 3)", value: "60" },
            { id: 2, time: "09:40:51", expr: "0.1 + 0.2", value: "0.3" },
            { id: 3, time: "09:39:12", expr: "(2 + 3) * 4", value: "20" },
          ],
          histIndex: -1, offset: 0, error: null, copied: null,
        } }; break;
      case "buffer-help": next = { ...next, buffer: "help" }; break;
      case "buffer-atlas": next = { ...next, buffer: "atlas", atlasCursor: 0 }; break;
      case "buffer-log": next = { ...next, buffer: "log", log: [
        { seq: 1, time: "09:30:12", kind: "info", text: "frog-nav 1.0.0 · 37 bookmarks · UTF-8" },
        { seq: 2, time: "09:30:18", kind: "ok", text: "✓ 已打开 GitHub" },
        { seq: 3, time: "09:31:02", kind: "ok", text: "✓ 已添加 “Swift 并发” → 开发工具" },
        { seq: 4, time: "09:31:40", kind: "warn", text: "快捷键 ⌃G 已被占用，原绑定未生效" },
        { seq: 5, time: "09:32:11", kind: "error", text: "✗ 校验失败：书签引用了不存在的分组 g-404" },
        { seq: 6, time: "09:32:30", kind: "ok", text: "✓ 恢复完成：37 条书签 · 5 个分组" },
      ] }; break;
      case "job-backup-ok": next = { ...next, buffer: "job", job: makeJob("backup", "ok", [
        { text: "$ frog backup --out \"~/Documents/青蛙导航-Bookmarks-20261104.json\"", kind: "cmd" },
        { text: "✓ 已写入 ~/Documents/青蛙导航-Bookmarks-20261104.json", kind: "ok" },
        { text: "包含 37 条书签 · 5 个分组 · 不含本机偏好", kind: "muted" },
      ]) }; break;
      case "job-backup-error": next = { ...next, buffer: "job", job: makeJob("backup", "error", [
        { text: "$ frog backup --out \"/Volumes/未挂载/backup.json\"", kind: "cmd" },
        { text: "✗ 无法写入备份：目标目录不存在或没有写权限。", kind: "error" },
        { text: "当前数据未被修改。重试 :backup ~/Documents/…", kind: "muted" },
      ]) }; break;
      case "job-restore-invalid": next = { ...next, buffer: "job", job: makeJob("restore", "error", [
        { text: "$ frog restore 旧备份-损坏.json", kind: "cmd" },
        { text: "✗ 校验失败：书签引用了不存在的分组 g-404。", kind: "error" },
        { text: "当前数据保持完整，未写入任何内容。", kind: "muted" },
      ]) }; break;
      case "job-restore-ok": next = { ...next, buffer: "job", job: makeJob("restore", "ok", [
        { text: "$ frog restore 青蛙导航-Bookmarks-20261101.json", kind: "cmd" },
        { text: "✓ 恢复完成：37 条书签 · 5 个分组", kind: "ok" },
        { text: "数据目录位置不变；同步工具会继续同步结果。", kind: "muted" },
      ]) }; break;
      case "job-cd-error": next = { ...next, buffer: "job", job: makeJob("cd", "error", [
        { text: "$ frog cd ~/Desktop/无权限目录", kind: "cmd" },
        { text: "✗ 没有读取该目录的权限。原数据目录保持不变。", kind: "error" },
        { text: "重新执行 :cd 选择其他目录。", kind: "muted" },
      ]) }; break;
      case "filepanel": next = { ...next, screen: "filepanel", filepanel: { hidden: false } }; break;
      case "filepanel-hidden": next = { ...next, screen: "filepanel", filepanel: { hidden: true } }; break;
      default: break;
    }
    setS(next);
  };

  /* ---------------- 键盘 ---------------- */
  useEffect(() => {
    const onKey = (e) => {
      if (e.isComposing) return;
      const k = e.key;
      const mod = e.metaKey || e.ctrlKey || e.altKey;

      if (k === "F1") { e.preventDefault(); openBuffer("atlas"); return; }
      if (e.metaKey && k === ",") { e.preventDefault(); openBuffer("settings"); return; }
      if (e.metaKey && (k === "n" || k === "N")) { e.preventDefault(); startAdd(); return; }

      /* 快捷键录入 */
      if (s.prompt && s.prompt.cmd === "hotkey") {
        e.preventDefault();
        if (k === "Escape") { closePrompt(); return; }
        if (["Meta", "Alt", "Control", "Shift"].includes(k)) return;
        const parts = [];
        if (e.metaKey) parts.push("Cmd"); if (e.altKey) parts.push("Opt");
        if (e.ctrlKey) parts.push("Ctrl"); if (e.shiftKey) parts.push("Shift");
        if (!parts.length) {
          setS((p) => ({ ...p, prompt: { ...p.prompt, error: "至少需要搭配 ⌘、⌥ 或 ⌃" } }));
          return;
        }
        const mainKey = k === " " ? "Space" : (k.length === 1 ? k.toUpperCase() : k);
        const label = parts.join("+") + "+" + mainKey;
        const conflict = label === "Ctrl+G";
        setS((p) => ({
          ...p, prompt: null, buffer: "settings",
          settings: { ...p.settings, hotkeyText: label, hotkeyConflict: conflict,
            hotkeyError: conflict ? "该组合已被其他应用占用，原绑定未生效。" : null },
          log: [...p.log, { seq: ++logSeq.current, time: nowTime(),
            text: conflict ? `✗ 快捷键注册失败 ${label}` : `✓ 已更新快捷键 ${label}`, kind: conflict ? "error" : "ok" }],
        }));
        return;
      }

      /* 设置页只通过命令操作，字符键不落入主列表快捷键 */
      if (s.buffer === "settings" && !s.input && !s.prompt) {
        if (k === "Escape") { e.preventDefault(); closeBuffer(); return; }
        if (k === ":") { e.preventDefault(); startCommand(); return; }
        return;
      }
      if (s.buffer === "atlas" && !s.input && !s.prompt) {
        if (k === "Escape" || k === "F1") { e.preventDefault(); closeBuffer(); return; }
        const total = FROG_SCENES.flatMap((g) => g.items).length;
        if (k === "j" || k === "ArrowDown") { e.preventDefault(); setS((p) => ({ ...p, atlasCursor: Math.min(total - 1, p.atlasCursor + 1) })); return; }
        if (k === "k" || k === "ArrowUp") { e.preventDefault(); setS((p) => ({ ...p, atlasCursor: Math.max(0, p.atlasCursor - 1) })); return; }
        if (k === "Enter") {
          e.preventDefault();
          const flat = FROG_SCENES.flatMap((g) => g.items.map(([id]) => id));
          if (flat[s.atlasCursor]) jumpScene(flat[s.atlasCursor]);
          return;
        }
        return;
      }
      if (s.buffer === "calc" && !s.input && !s.prompt) {
        if (k === "Escape") { e.preventDefault(); closeBuffer(); return; }
        if (k === "Enter" || (k === "=" && !mod)) { e.preventDefault(); evalCalc(); return; }
        if (k === "ArrowUp" || k === "ArrowDown") {
          e.preventDefault(); browseCalcHistory(k === "ArrowUp"); return;
        }
        if (k === "c" && !mod) { e.preventDefault(); copyCalcResult(); return; }
        if (k === ":") { e.preventDefault(); startCommand(); return; }
        if (k === "Tab") { e.preventDefault(); return; }
        // 算式只接受数字、运算符、括号、小数点与空格，其余字符不进入输入框。
        if (!mod && k.length === 1 && !/[\d+\-*/().eE（）\s]/.test(k)) { e.preventDefault(); return; }
        return;
      }
      if (s.buffer && !s.input && !s.prompt) {
        if (k === "Escape") { e.preventDefault(); closeBuffer(); return; }
        return;
      }

      /* 文件面板 */
      if (s.screen === "filepanel") {
        if (k === "Escape") { e.preventDefault(); setS((p) => ({ ...p, screen: "main" })); return; }
        if (k === "g" || k === "G") { e.preventDefault(); setS((p) => ({ ...p, filepanel: { hidden: !p.filepanel.hidden } })); return; }
        return;
      }

      /* 提示流 */
      if (s.prompt) {
        if (s.prompt.cmd === "delete") {
          if (k === "y" || k === "Y") {
            e.preventDefault();
            setS((p) => {
              const target = p.prompt.payload;
              let doc = p.doc;
              if (target.kind === "bookmark") doc = { ...p.doc, bookmarks: p.doc.bookmarks.filter((b) => b.id !== target.id) };
              else {
                if (p.doc.bookmarks.some((b) => b.groupId === target.id)) {
                  return { ...p, prompt: { ...p.prompt, error: "文件夹内仍有书签，需先移出或删除" } };
                }
                doc = { ...p.doc, groups: p.doc.groups.filter((g) => g.id !== target.id) };
              }
              return { ...p, doc, prompt: null, cursor: 0, scroll: 0,
                log: [...p.log, { seq: ++logSeq.current, time: nowTime(), text: `✓ 已删除 “${target.title}”`, kind: "ok" }] };
            });
            return;
          }
          if (k === "n" || k === "N" || k === "Escape") { e.preventDefault(); closePrompt(); return; }
          return;
        }
        if (k === "Escape") { e.preventDefault(); closePrompt(); return; }
        if (k === "Enter") { e.preventDefault(); submitPrompt(); return; }
        if (k === "Tab" && s.prompt.cmd === "edit") { e.preventDefault(); switchEditField(); return; }
        if (k === "Tab" && e.shiftKey) { e.preventDefault(); previousPrompt(); return; }
        if (k === "Tab") {
          e.preventDefault();
          setS((p) => {
            if (!p.prompt || !p.prompt.options || !p.prompt.options.length) return p;
            const idx = (p.prompt.optIndex + 1) % p.prompt.options.length;
            return { ...p, prompt: { ...p.prompt, optIndex: idx, value: p.prompt.options[idx].label } };
          });
          return;
        }
        if (k === "ArrowDown" || k === "ArrowUp") {
          e.preventDefault();
          setS((p) => {
            if (!p.prompt || !p.prompt.options || !p.prompt.options.length) return p;
            const n = p.prompt.options.length;
            const idx = k === "ArrowDown" ? (p.prompt.optIndex + 1) % n : (p.prompt.optIndex - 1 + n) % n;
            return { ...p, prompt: { ...p.prompt, optIndex: idx, value: p.prompt.options[idx].label } };
          });
          return;
        }
        return;
      }

      /* 命令行 / 搜索 */
      if (s.input) {
        if (k === "Escape") { e.preventDefault(); cancelAll(); return; }
        if (k === "Enter") { e.preventDefault(); submitInput(); return; }
        if (k === "Tab") {
          e.preventDefault();
          if (s.input.kind === "command") {
            const val = s.input.value.trim().toLowerCase();
            const hit = COMMANDS.find(([name]) => name.startsWith(val));
            if (hit) setS((p) => ({ ...p, input: { ...p.input, value: hit[0] } }));
          }
          return;
        }
        if ((k === "ArrowUp" || k === "ArrowDown") && s.input.kind === "command") {
          e.preventDefault();
          setS((p) => {
            const hist = p.history;
            if (!hist.length) return p;
            const cur = p.histIndex < 0 ? hist.length : p.histIndex;
            const next = k === "ArrowUp" ? Math.max(0, cur - 1) : Math.min(hist.length, cur + 1);
            return { ...p, histIndex: next, input: { ...p.input, value: hist[next] || "" } };
          });
          return;
        }
        return;
      }

      /* 移动模式 */
      if (s.mode === "move") {
        if (k === "Escape") { e.preventDefault(); setS((p) => ({ ...p, mode: "normal", moveSource: null, moveTarget: null, moveReorder: false })); return; }
        if (k === "j" || k === "ArrowDown") { e.preventDefault(); setS((p) => ({ ...p, moveTarget: Math.min(view.items.length - 1, (p.moveTarget ?? 0) + 1) })); return; }
        if (k === "k" || k === "ArrowUp") { e.preventDefault(); setS((p) => ({ ...p, moveTarget: Math.max(0, (p.moveTarget ?? 0) - 1) })); return; }
        if (k === "Enter") { e.preventDefault(); setS((p) => ({ ...p, mode: "normal", moveSource: null, moveTarget: null, moveReorder: false })); return; }
        return;
      }

      if (s.screen !== "main") return;
      if (mod) return;
      if (s.mode === "organize" && (k === "J" || (e.shiftKey && k === "ArrowDown"))) {
        e.preventDefault(); reorderSelected(1); return;
      }
      if (s.mode === "organize" && (k === "K" || (e.shiftKey && k === "ArrowUp"))) {
        e.preventDefault(); reorderSelected(-1); return;
      }

      /* 导航 */
      if (k === "j" || k === "ArrowDown" || k === "k" || k === "ArrowUp") {
        e.preventDefault();
        const d = (k === "j" || k === "ArrowDown") ? 1 : -1;
        setS((p) => ({ ...p, cursor: Math.max(0, Math.min(view.items.length - 1, p.cursor + d)) }));
        return;
      }
      if (k === "Enter") { e.preventDefault(); activate(); return; }
      if (k === "/") { e.preventDefault(); startSearch(); return; }
      if (k === ":") { e.preventDefault(); startCommand(); return; }
      if (k === "a") { e.preventDefault(); startAdd(); return; }
      if (k === "n") { e.preventDefault(); beginMkdir(); return; }
      if (k === "e") { e.preventDefault(); startEdit("title"); return; }
      if (k === "r") { e.preventDefault(); startRename(); return; }
      if (k === "m") { e.preventDefault(); beginMove(); return; }
      if (k === "D") { e.preventDefault(); beginDelete(); return; }
      if (k === "C") { e.preventDefault(); const it = view.items[s.cursor]; if (it && it.kind === "bookmark") copyBookmark(it.bm.id); return; }
      if (k === "o") { e.preventDefault(); toggleOrganize(); return; }
      if (k === ",") { e.preventDefault(); openBuffer("settings"); return; }
      if (k === "?") { e.preventDefault(); openBuffer("help"); return; }
      if (k === "PageUp") { e.preventDefault(); setCursor(Math.max(0, s.cursor - view.visible)); return; }
      if (k === "PageDown") { e.preventDefault(); setCursor(Math.min(view.items.length - 1, s.cursor + view.visible)); return; }
      if (k === "g") { e.preventDefault(); setCursor(0); return; }
      if (k === "G") { e.preventDefault(); setCursor(view.items.length - 1); return; }
      if (k === "Escape") { e.preventDefault(); cancelAll(); return; }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [s, view, activeText, pushLog, jumpScene]);

  /* 预览钩子 */
  useEffect(() => { window.frogJumpScene = (id) => jumpScene(id); });
  const initialScene = useRef(false);
  useEffect(() => {
    if (initialScene.current) return;
    initialScene.current = true;
    const q = new URLSearchParams(location.search).get("scene");
    if (q) jumpScene(q);
  }, []);

  const act = {
    setCursor, scrollBy, openFolder, closeFolder, activate,
    openBookmark, copyBookmark,
    startAdd, startEdit, startRename, beginDelete, requestDelete, beginMove, startMove, toggleOrganize,
    startCommand, startSearch, cancel: cancelAll, submit: submitInput, setActiveText, focusInput,
    evalCalc, browseCalcHistory, calcUse: useCalcEntry, resetCalc, syncSelection: syncActiveSelection,
    openSettings: () => openBuffer("settings"), openBuffer, closeBuffer, openAtlas: () => openBuffer("atlas"),
    openHelp: () => openBuffer("help"), openLog: () => openBuffer("log"),
    openFilePanel: () => setS((p) => ({ ...p, screen: "filepanel", filepanel: { hidden: false } })),
    closeScreen: () => setS((p) => ({ ...p, screen: "main" })),
    jumpScene,
    setPromptOption: (i) => setS((p) => (p.prompt && p.prompt.options ? { ...p, prompt: { ...p.prompt, optIndex: i, value: p.prompt.options[i].label } } : p)),
    retryNotice: () => { setS((p) => ({ ...p, flags: { ...p.flags, corrupt: false, dirUnavailable: false, conflict: false } })); pushLog("✓ 已重新载入数据", "ok"); },
    beginBackup, beginRestore, beginCd, beginHotkey,
    runBackup, runRestore, runCd, runSet, pushLog, clearLog: () => setS((p) => ({ ...p, log: [] })),
  };

  const ctx = {
    s, act, view, items: view.items, allItems: view.all,
    scroll: view.scroll, visible: view.visible, maxScroll: view.maxScroll,
    folderName, groupName, commands: COMMANDS, shortcuts: SHORTCUTS,
    locationChoices: groupOptions(s.doc),
  };

  const main = window.FrogMain ? window.FrogMain.renderContent(ctx) : null;
  const buffers = window.FrogBuffers;
  const showFilepanel = s.screen === "filepanel";

  return (
    <div className="stage">
      <svg className="board" viewBox={`0 0 ${LAYOUT.W} ${LAYOUT.H}`} width="100%" height="100%"
           xmlns="http://www.w3.org/2000/svg" role="img" aria-label="青蛙导航 回声终端 原型">
        <R x={0} y={0} w={LAYOUT.W} h={LAYOUT.H} fill={COLOR.paper} />

        {showFilepanel && buffers && <g>{buffers.renderFilePanel(ctx)}</g>}
        {!showFilepanel && s.buffer && buffers && <g>{buffers.renderBuffer(ctx)}</g>}
        {!showFilepanel && !s.buffer && <g>{main}<LogPane s={s} act={act} /></g>}

        {!showFilepanel && <CommandChrome s={s} act={act} />}
        <StatusChrome s={s} ctx={ctx} />
        {s.buffer !== "settings" && s.buffer !== "calc" && <HintsChrome />}
      </svg>

      <input
        ref={imeRef}
        className="ime"
        autoComplete="off"
        autoCorrect="off"
        spellCheck={false}
        aria-label="命令行输入"
        onChange={(e) => act.setActiveText(e.target.value, {
          start: e.target.selectionStart ?? e.target.value.length,
          end: e.target.selectionEnd ?? e.target.value.length,
        }, composingRef.current)}
        onSelect={() => act.syncSelection()}
        onKeyUp={() => act.syncSelection()}
        onCompositionStart={() => { composingRef.current = true; }}
        onCompositionEnd={(e) => {
          composingRef.current = false;
          act.setActiveText(e.target.value, {
            start: e.target.selectionStart ?? e.target.value.length,
            end: e.target.selectionEnd ?? e.target.value.length,
          });
        }}
      />
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
