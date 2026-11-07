/* macOS 自定义命令交互原型；仅预览，不调用宿主机 shell。 */
const FROG_COMMAND_STORAGE = "frog-echo-macos-commands-v1";
const FROG_COMMAND_TYPES = { terminal: "终端命令", program: "程序 / 脚本", url: "网址" };
const FROG_COMMAND_SEEDS = [
  { name: "aiomp", title: "项目 OMP", type: "terminal", directory: "~/Documents/frog-navigation", target: "omp", args: "", terminal: "Terminal" },
  { name: "codefrog", title: "用 VS Code 打开项目", type: "program", directory: "~/Documents/frog-navigation", target: "/usr/bin/open", args: '-a "Visual Studio Code" .', terminal: "不使用终端" },
  { name: "gh", title: "搜索 GitHub", type: "url", directory: "", target: "https://github.com/search?q={query}", args: "", terminal: "" },
];
function frogLoadCommands() {
  try {
    const raw = localStorage.getItem(FROG_COMMAND_STORAGE);
    if (!raw) return { items: FROG_COMMAND_SEEDS, error: "" };
    const items = JSON.parse(raw);
    if (!Array.isArray(items) || items.some(c => !c || !Object.hasOwn(FROG_COMMAND_TYPES, c.type) || ["name", "title", "directory", "target", "args", "terminal"].some(k => typeof c[k] !== "string"))) throw Error();
    return { items, error: "" };
  } catch { return { items: [], error: "原型本地配置无法读取；下次保存会覆盖受损数据。请检查浏览器存储。" }; }
}
function frogCommandError(c, items, original) {
  if (!/^[a-z][a-z0-9_-]*$/i.test(c.name)) return "命令名须以字母开头，仅含字母、数字、短横线或下划线。";
  const reserved = [...COMMANDS.map(c => c[0]), "commands", "a", "e", "r", "del", "mv", "b", "man", "map", "logs", "quit", "o", "md", "g", "calculator"];
  if (reserved.includes(c.name.toLowerCase())) return "该名称由内置命令保留，请换一个名称。";
  if (items.some(x => x.name !== original && x.name.toLowerCase() === c.name.toLowerCase())) return "命令名已存在，请换一个名称。";
  if (!c.title.trim() || !c.target.trim()) return "名称与执行内容不能为空。";
  if (c.type !== "url" && !/^(\/|~\/)/.test(c.directory)) return "工作目录请填写绝对路径或 ~/ 开头的路径。";
  if (c.type === "url") {
    try { if (!["https:", "http:"].includes(new URL(c.target).protocol)) throw Error(); }
    catch { return "网址必须是有效的 http:// 或 https:// 地址。"; }
  }
  return "";
}
function frogCommandMatches(items, input) {
  const q = input.trim().toLowerCase();
  if (/\s/.test(q)) return [];
  return [...items.map(c => [c.name, c.title, FROG_COMMAND_TYPES[c.type]]), ["commands", "管理自定义命令", "macOS"], ...COMMANDS.map(c => [c[0], c[1], "内置"])].filter(c => !q || `${c[0]} ${c[1]}`.toLowerCase().includes(q));
}
function FrogCommandDiscovery({ items, input, choose }) {
  const matches = frogCommandMatches(items, input.value);
  const index = input.choice ?? -1;
  const start = Math.max(0, index - 6);
  const height = 74 + Math.max(1, Math.min(7, matches.length)) * 40;
  const top = BV.y + BV.h - height;
  if (/\s/.test(input.value.trim())) return null;
  return <g>
    <R x={40} y={top} w={1360} h={height} fill={COLOR.paper} stroke={COLOR.line} />
    <T x={60} y={top + 26} size={12} fill={COLOR.green}>命令 · {matches.length} 项</T>
    <T x={1380} y={top + 26} size={11} anchor="end" fill={COLOR.muted}>↑↓ 选择 · Tab / 点击补全 · Enter 执行明确命令 · :commands 管理</T>
    {matches.slice(start, start + 7).map(([name, title, type], i) => {
      const selected = i + start === index;
      return <g key={name} onClick={() => choose(name)} style={{ cursor: "pointer" }}>
        <R x={52} y={top + 48 + i * 40} w={1336} h={38} fill={selected ? COLOR.ink : i % 2 ? COLOR.surface : COLOR.paper} />
        <T x={70} y={top + 67 + i * 40} fill={selected ? COLOR.paper : COLOR.teal}>:{name}</T>
        <T x={320} y={top + 67 + i * 40} fill={selected ? COLOR.paper : COLOR.ink}>{title}</T>
        <T x={1368} y={top + 67 + i * 40} size={12} anchor="end" fill={selected ? COLOR.mint : COLOR.muted}>{type}</T>
      </g>;
    })}
    {!matches.length && <T x={70} y={top + 80} fill={COLOR.muted}>未找到命令；不会将输入作为 shell 执行。</T>}
  </g>;
}
function FrogCommands({ items, saveItems, initialPreview, suspended, close, startCommand, storageError }) {
  const [mode, setMode] = React.useState(initialPreview ? "preview" : "list");
  const [cursor, setCursor] = React.useState(0);
  const [draft, setDraft] = React.useState(null);
  const [original, setOriginal] = React.useState(null);
  const [field, setField] = React.useState(0);
  const [error, setError] = React.useState(storageError || "");
  const [notice, setNotice] = React.useState("");
  const [preview, setPreview] = React.useState(initialPreview);
  const [query, setQuery] = React.useState("");
  const [searching, setSearching] = React.useState(false);
  const input = React.useRef(null);
  const filtered = items.filter(c => `${c.name} ${c.title}`.toLowerCase().includes(query.toLowerCase()));
  const selected = filtered[Math.min(cursor, Math.max(0, filtered.length - 1))];
  const fields = draft ? [["name", "命令名"], ["title", "名称"], ["type", "动作类型"], ...(draft.type === "url" ? [] : [["directory", "工作目录"]]), ["target", draft.type === "url" ? "网址模板" : "执行内容"], ...(draft.type === "url" ? [] : [["args", "参数模板"], ["terminal", "终端"]])] : [];
  const current = fields[field];
  const editingText = mode === "edit" && current && !["type", "terminal"].includes(current[0]);
  React.useEffect(() => {
    if (suspended || (!editingText && !searching)) return;
    const el = input.current;
    el.focus();
    el.setSelectionRange(el.value.length, el.value.length);
  }, [mode, field, searching, suspended]);
  const edit = (c, copy = false) => {
    setOriginal(c && !copy ? c.name : null);
    setDraft(c ? { ...c, name: copy ? c.name + "-copy" : c.name } : { name: "", title: "", type: "terminal", directory: "~/Documents", target: "", args: "", terminal: "Terminal" });
    setField(0); setError(""); setNotice(""); setMode("edit"); setSearching(false);
  };
  const save = () => {
    const c = { ...draft, name: draft.name.trim().toLowerCase(), title: draft.title.trim(), directory: draft.directory.trim(), target: draft.target.trim() };
    const issue = frogCommandError(c, items, original);
    if (issue) { setError(issue); return; }
    const next = original ? items.map(x => x.name === original ? c : x) : [...items, c];
    const failure = saveItems(next);
    if (failure) { setError(failure); return; }
    setMode("list"); setQuery(""); setCursor(next.findIndex(x => x.name === c.name)); setError(""); setNotice("已保存到本浏览器；不修改正式应用数据。");
  };
  const cycle = () => {
    const key = current[0];
    const values = key === "type" ? Object.keys(FROG_COMMAND_TYPES) : draft.type === "program" ? ["不使用终端", "Terminal", "iTerm2"] : ["Terminal", "iTerm2"];
    const value = values[(values.indexOf(draft[key]) + 1) % values.length];
    setDraft({ ...draft, [key]: value, ...(key === "type" ? { terminal: value === "program" ? "不使用终端" : "Terminal" } : {}) });
  };
  const showPreview = (c, args = "") => { setPreview({ command: c, args }); setMode("preview"); setError(""); };
  React.useEffect(() => {
    if (suspended) return;
    const onKey = e => {
      if (e.isComposing) { e.stopImmediatePropagation(); return; }
      const k = e.key;
      if (k === "Escape") {
        e.preventDefault(); setError(""); setNotice("");
        if (searching) setSearching(false);
        else if (mode !== "list") setMode("list");
        else if (query) setQuery("");
        else close();
        return;
      }
      if (mode === "edit") {
        if ((e.metaKey || e.ctrlKey) && k === "Enter") { e.preventDefault(); save(); return; }
        if (k === "Tab" || k === "Enter") {
          e.preventDefault();
          if (k === "Enter" && field === fields.length - 1) save();
          else setField((field + (e.shiftKey ? -1 : 1) + fields.length) % fields.length);
        } else if (!editingText && [" ", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(k)) { e.preventDefault(); cycle(); }
        return;
      }
      if (mode === "delete") {
        if (k.toLowerCase() === "y") {
          e.preventDefault();
          const failure = saveItems(items.filter(c => c.name !== selected.name));
          if (failure) setError(failure);
          else { setMode("list"); setCursor(0); setError(""); setNotice("已删除命令配置，未删除目标文件。"); }
        } else if (k.toLowerCase() === "n") { e.preventDefault(); setMode("list"); }
        return;
      }
      if (searching) { if (k === "Enter") { e.preventDefault(); setSearching(false); } return; }
      if (k === ":") { e.preventDefault(); startCommand(); return; }
      if (mode === "preview" && k === "e" && !e.metaKey && !e.ctrlKey && !e.altKey) { e.preventDefault(); edit(preview.command); return; }
      if (mode !== "list" || e.metaKey || e.ctrlKey || e.altKey) return;
      if (["ArrowDown", "j", "ArrowUp", "k"].includes(k)) { e.preventDefault(); setCursor(Math.max(0, Math.min(filtered.length - 1, cursor + (["j", "ArrowDown"].includes(k) ? 1 : -1)))); }
      if (k === "a") { e.preventDefault(); edit(null); }
      if (k === "/") { e.preventDefault(); setSearching(true); }
      if (selected && ["e", "c", "D", "Enter"].includes(k)) {
        e.preventDefault();
        if (k === "e" || k === "c") edit(selected, k === "c");
        if (k === "D") { setMode("delete"); setError(""); }
        if (k === "Enter") showPreview(selected);
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  });
  const X = BV.x + 32;
  const RIGHT = BV.x + BV.w - 32;
  const rowStart = Math.max(0, cursor - CALC_VISIBLE_ROWS + 1);
  const label = mode === "edit" ? (original ? "编辑命令" : "新建命令") : mode === "preview" ? "执行预览" : mode === "delete" ? "删除确认" : "自定义命令";
  const command = mode === "preview" ? preview.command : mode === "edit" ? draft : selected;
  const actions = mode === "list" ? [
    ["/ 搜索", () => setSearching(true)], ["a 新建", () => edit(null)],
    ...(selected ? [["e 编辑", () => edit(selected)], ["c 复制", () => edit(selected, true)], ["D 删除", () => { setMode("delete"); setError(""); }], ["Enter 预览", () => showPreview(selected)]] : []),
  ] : mode === "edit" ? [["⌘Enter 保存", save], ["Esc 取消", () => { setMode("list"); setError(""); }]]
    : mode === "preview" ? [["e 编辑", () => edit(preview.command)], ["Esc 返回", () => setMode("list")]] : [];
  const chromeState = {
    buffer: "commands",
    statusHint: mode === "delete" ? "y 确认 · n / Esc 取消" : mode === "edit" ? "Tab 切换 · ⌘Enter 保存 · Esc 取消" : mode === "preview" ? "e 编辑 · Esc 返回命令列表" : searching ? "Enter 确认筛选 · Esc 结束输入" : ": 命令 · Esc 关闭",
    prompt: mode === "edit" ? { cmd: "commands", label: current[1], value: editingText ? draft[current[0]] : (current[0] === "type" ? FROG_COMMAND_TYPES[draft.type] : draft.terminal), hint: "Tab 切换 · ⌘Enter 保存 · Esc 取消" }
      : mode === "delete" ? { cmd: "commands", label: "删除", value: `:${selected.name} · y / N`, hint: "y 确认 · n / Esc 取消" } : null,
    input: searching ? { kind: "search", value: query } : null,
  };
  return <g>
    {bvTitle({}, "commands", `${items.length} 条命令 · macOS · ${label} · Esc 返回`)}
    {command ? <g>
      <T x={X} y={BV.bodyTop + 30} size={40} weight={700} fill={mode === "delete" ? COLOR.red : COLOR.green}>{truncate(`:${command.name || "新命令"}`, 40, RIGHT - X)}</T>
      <T x={X} y={BV.bodyTop + 66} size={12} fill={COLOR.muted}>{truncate(mode === "delete" ? "只删除命令配置，不删除目录、应用或脚本。" : `${command.title || label} · ${FROG_COMMAND_TYPES[command.type]}`, 12, RIGHT - X)}</T>
    </g> : <T x={X} y={BV.bodyTop + 26} size={14} fill={COLOR.muted}>{items.length ? "没有匹配的命令" : "按 a 新建自定义命令"}</T>}
    <L x1={X} y1={BV.bodyTop + 84} x2={RIGHT} y2={BV.bodyTop + 84} stroke={COLOR.line} />
    <T x={X} y={BV.bodyTop + 108} size={10.5} fill={COLOR.muted} spacing={1.6}>
      {mode === "list" ? `COMMANDS · ${filtered.length} 条${query ? " · / " + truncate(query, 10.5, 240) : ""}` : mode === "edit" ? "CONFIG · " + label : mode === "preview" ? "PREVIEW · 仅展示执行计划" : "CONFIRM · y / N"}
    </T>
    {actions.map(([text, action], i) => {
      const width = textW(text, 10.5);
      const right = RIGHT - actions.slice(i + 1).reduce((sum, [t]) => sum + textW(t, 10.5) + 24, 0);
      return <g key={text} onClick={action} style={{ cursor: "pointer" }}>
        <R x={right - width - 8} y={BV.bodyTop + 97} w={width + 16} h={22} fill="transparent" />
        <T x={right} y={BV.bodyTop + 108} size={10.5} anchor="end" fill={COLOR.muted}>{text}</T>
      </g>;
    })}
    {mode === "list" && filtered.slice(rowStart, rowStart + CALC_VISIBLE_ROWS).map((c, i) => {
      const active = c === selected;
      const y = BV.bodyTop + 132 + i * 26;
      return <g key={c.name} data-command-row={c.name} onClick={() => { setCursor(i + rowStart); setSearching(false); }} onDoubleClick={() => edit(c)} style={{ cursor: "pointer" }}>
        <R x={X - 8} y={y - 11} w={RIGHT - X + 16} h={22} fill={active ? COLOR.ink : "transparent"} />
        {active && <R x={X - 8} y={y - 11} w={3} h={22} fill={COLOR.yellow} />}
        <T x={X} y={y} size={10} fill={active ? COLOR.yellow : COLOR.muted}>{String(rowStart + i + 1).padStart(2, "0")}</T>
        <T x={X + 28} y={y} size={12.5} fill={active ? COLOR.paper : COLOR.ink}>{truncate(":" + c.name, 12.5, 200)}</T>
        <T x={X + 248} y={y} size={12.5} fill={active ? COLOR.paper : COLOR.ink}>{truncate(c.title, 12.5, 280)}</T>
        <T x={X + 552} y={y} size={11} fill={active ? COLOR.mint : COLOR.muted}>{FROG_COMMAND_TYPES[c.type]}</T>
        <T x={RIGHT} y={y} size={11} anchor="end" fill={active ? COLOR.mint : COLOR.green}>{truncate(c.type === "url" ? c.target : c.directory, 11, RIGHT - X - 700)}</T>
      </g>;
    })}
    {mode === "edit" && fields.map(([key, text], i) => {
      const y = BV.bodyTop + 132 + i * 26;
      const active = i === field;
      const option = ["type", "terminal"].includes(key);
      return <g key={key} data-command-field={key} onClick={() => { if (active && option) cycle(); else setField(i); input.current?.focus(); }} style={{ cursor: option ? "pointer" : "text" }}>
        <R x={X - 8} y={y - 11} w={RIGHT - X + 16} h={22} fill={active ? COLOR.ink : "transparent"} />
        {active && <R x={X - 8} y={y - 11} w={3} h={22} fill={COLOR.yellow} />}
        <T x={X} y={y} size={10} fill={active ? COLOR.yellow : COLOR.muted}>{String(i + 1).padStart(2, "0")}</T>
        <T x={X + 28} y={y} size={11} fill={active ? COLOR.mint : COLOR.muted}>{text}</T>
        <T x={X + 200} y={y} size={12.5} fill={active ? COLOR.paper : COLOR.ink}>{truncate(key === "type" ? FROG_COMMAND_TYPES[draft.type] : draft[key] || "（未填写）", 12.5, RIGHT - X - 330)}</T>
        {option && <T x={RIGHT} y={y} size={10.5} anchor="end" fill={active ? COLOR.mint : COLOR.muted}>空格 / 点击切换</T>}
      </g>;
    })}
    {mode === "preview" && (preview.command.type === "url" ? [
      ["打开方式", "默认浏览器"], ["目标网址", preview.command.target.replaceAll("{query}", encodeURIComponent(preview.args))],
    ] : [
      ["工作目录", preview.command.directory], ["终端", preview.command.terminal], ["执行内容", preview.command.target], ["参数模板", preview.command.args || "（无）"], ["输入参数（数据）", preview.args || "（无）"],
    ]).map(([key, value], i) => {
      const y = BV.bodyTop + 132 + i * 26;
      return <g key={key}><title>{value}</title>
        <T x={X} y={y} size={10} fill={COLOR.muted}>{String(i + 1).padStart(2, "0")}</T>
        <T x={X + 28} y={y} size={11} fill={COLOR.muted}>{key}</T>
        <T x={X + 200} y={y} size={12.5} fill={COLOR.ink}>{truncate(value, 12.5, RIGHT - X - 200)}</T>
      </g>;
    })}
    {mode === "delete" && <T x={X} y={BV.bodyTop + 132} size={12.5} fill={COLOR.red}>确认删除 :{selected.name}？按 y 确认，n / Esc 取消。</T>}
    {error && <T x={X} y={BV.y + BV.h - 36} size={12} fill={COLOR.amber}>{error}</T>}
    {notice && <T x={X} y={BV.y + BV.h - (error ? 54 : 36)} size={12} fill={COLOR.green}>{notice}</T>}
    <T x={X} y={BV.y + BV.h - 10} size={10} fill={COLOR.muted}>
      {mode === "edit" ? "Tab / Shift+Tab 切换字段 · 参数模板使用 {args}，网址使用 {query} · Esc 丢弃草稿"
        : mode === "preview" ? "仅预览：未打开终端、未运行命令，也未检查目录或程序是否存在"
        : mode === "delete" ? "仅删除当前命令配置 · n / Esc 取消，不改变已有数据"
        : "↑↓ 选择 · 点击选中 / 双击编辑 · 本浏览器保存 · 原型不执行系统命令"}
    </T>
    {!suspended && <g>
      <CommandChrome s={chromeState} act={{ focusInput: () => { if (editingText || searching) input.current?.focus(); else if (mode === "list" || mode === "preview") startCommand(); } }} />
      <StatusChrome s={chromeState} />
    </g>}
    {ReactDOM.createPortal(<input ref={input} className="ime" aria-label={searching ? "搜索自定义命令" : "自定义命令字段"} value={searching ? query : editingText ? draft[current[0]] : ""} onChange={e => { if (searching) { setQuery(e.target.value); setCursor(0); } else if (editingText) { setDraft({ ...draft, [current[0]]: e.target.value }); setError(""); } }} />, document.body)}
  </g>;
}
