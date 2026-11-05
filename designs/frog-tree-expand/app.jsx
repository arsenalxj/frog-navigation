/* 青蛙导航 · 方向二：树形展开 — 原型
 * 问题：根目录看不到文件夹里有哪些书签，必须 Enter 进入。
 * 方案：文件夹行前加展开符，Tab 或点击在原地展开子书签（缩进 + 连接线），
 *       可同时展开多个文件夹，子项可直接选中并 Enter 打开，全程不离开根目录。
 * 取舍：上下文不丢失、能看到全部子项；代价是列表变长，展开多时需要滚动。
 * 视觉与交互沿用回声终端规格：1440×900 SVG、j/k 移动、Enter 打开、Esc 返回。
 */
(function () {
"use strict";
const { useState, useEffect, useMemo, useRef } = React;

/* ================= 原子组件（与回声终端一致） ================= */

function T({ x, y, children, size = TYPE.body, fill = COLOR.ink, weight = 400, anchor = "start",
           opacity = 1, sans = false, style, baseline = "central" }) {
  return (
    <text x={x} y={y} fontSize={size} fill={fill} fontWeight={weight} textAnchor={anchor}
          opacity={opacity} dominantBaseline={baseline}
          fontFamily={sans ? FONT_SANS : FONT_MONO} style={style}>
      {children}
    </text>
  );
}

function textW(str, size = TYPE.body) {
  let w = 0;
  for (const ch of String(str || "")) w += ch.charCodeAt(0) > 255 ? size : size * 0.6;
  return w;
}

function truncate(str, size, maxW) {
  const s = String(str || "");
  if (textW(s, size) <= maxW) return s;
  let out = "";
  for (const ch of s) {
    if (textW(out + ch + "…", size) > maxW) break;
    out += ch;
  }
  return out + "…";
}

function hostOf(url) {
  try { return new URL(url).host.replace(/^www\./, ""); }
  catch (e) { return String(url || "").replace(/^https?:\/\//, "").split("/")[0]; }
}

function R({ x, y, w, h, fill = "none", stroke = "none", sw = 1, rx = 0, opacity = 1, onClick, style }) {
  return <rect x={x} y={y} width={w} height={h} fill={fill} stroke={stroke} strokeWidth={sw}
               rx={rx} opacity={opacity} onClick={onClick} style={style} />;
}

function L({ x1, y1, x2, y2, stroke = COLOR.line, sw = 1, opacity = 1 }) {
  return <line x1={x1} y1={y1} x2={x2} y2={y2} stroke={stroke} strokeWidth={sw} opacity={opacity} />;
}

function Kbd({ x, y, label, size = TYPE.sm, dark = false }) {
  const w = Math.max(24, textW(label, size) + 12);
  return (
    <g>
      <R x={x} y={y - 11} w={w} h={22} rx={2}
         fill={dark ? "none" : COLOR.surface}
         stroke={dark ? "rgba(255,254,248,0.35)" : COLOR.line} sw={1} />
      <T x={x + w / 2} y={y + 0.5} size={size} anchor="middle"
         fill={dark ? COLOR.paper : COLOR.ink2}>{label}</T>
    </g>
  );
}

function IconTile({ x, y, id, title, size = 20 }) {
  return (
    <g>
      <R x={x} y={y - size / 2} w={size} h={size} rx={3} fill={frogTileColor(id)} />
      <T x={x + size / 2} y={y + 0.5} size={size * 0.55} weight={700} anchor="middle"
         fill={COLOR.paper}>{frogInitial(title)}</T>
    </g>
  );
}

/* ================= 数据 ================= */

function rootItems(data) {
  const groups = data.groups.slice().sort((a, b) => a.order - b.order).map((g) => ({
    kind: "folder",
    group: g,
    children: data.bookmarks.filter((b) => b.groupId === g.id).sort((a, b) => a.order - b.order),
  }));
  const bms = data.bookmarks.filter((b) => !b.groupId).sort((a, b) => a.order - b.order)
    .map((b) => ({ kind: "bm", bm: b }));
  return groups.concat(bms);
}

function flatten(items, expanded) {
  const out = [];
  for (const [n, it] of items.entries()) {
    if (it.kind === "folder") {
      out.push({ kind: "folder", key: "f:" + it.group.id, group: it.group, children: it.children, no: n + 1 });
      if (expanded.has(it.group.id)) {
        for (const b of it.children) out.push({ kind: "child", key: "c:" + b.id, bm: b, parent: it.group.id, no: null });
      }
    } else {
      out.push({ kind: "bm", key: "b:" + it.bm.id, bm: it.bm, no: n + 1 });
    }
  }
  return out;
}

/* ================= 几何 ================= */

const ROW_H = LAYOUT.rowH;
const ROW_X = LAYOUT.list.x + 6;
const ROW_W = LAYOUT.list.w - 12;
const ICON_X = ROW_X + 52;
const TITLE_X = ROW_X + 88;
const RIGHT = ROW_X + ROW_W - 4;
const INDENT = 32;
const BRANCH_X = ICON_X + 8;
const ROWS_TOP = LAYOUT.list.y;
const VISIBLE = Math.floor((LAYOUT.log.y - 16 - ROWS_TOP) / ROW_H);

/* ================= 行 ================= */

function FolderRow({ row, i, pos, selected, expanded, onPick, onToggle }) {
  const top = ROWS_TOP + pos * ROW_H;
  const cy = top + ROW_H / 2;
  const inv = selected;
  const count = row.children.length;
  const countText = expanded ? `${count} 项 · 已展开` : `${count} 项`;
  return (
    <g onClick={onPick} onDoubleClick={onToggle} style={{ cursor: "pointer" }}>
      <R x={ROW_X} y={top} w={ROW_W} h={ROW_H} fill="transparent" />
      {inv && <R x={ROW_X} y={top + 1} w={ROW_W} h={ROW_H - 2} fill={COLOR.ink} />}
      {inv && <R x={ROW_X} y={top + 1} w={3} h={ROW_H - 2} fill={COLOR.yellow} />}
      <g onClick={(e) => { e.stopPropagation(); onToggle(); }} style={{ cursor: "pointer" }}>
        <R x={ROW_X + 24} y={top + 4} w={24} h={24} fill="transparent" />
        <Icon name={expanded ? "chevronD" : "chevronR"} x={ROW_X + 28} y={cy - 8} size={16}
              color={inv ? COLOR.yellow : COLOR.muted} />
      </g>
      <Icon name={expanded ? "folderOpen" : "folder"} x={ICON_X} y={cy - 10} size={20}
            color={inv ? COLOR.mint : COLOR.purple} />
      <T x={TITLE_X} y={cy} size={14} weight={600} fill={inv ? COLOR.paper : COLOR.purple}>
        {truncate(row.group.name, 14, 320)}
      </T>
      <T x={RIGHT} y={cy} size={11.5} anchor="end" fill={inv ? COLOR.mint : COLOR.muted}>
        {countText}
      </T>
    </g>
  );
}

function ChildRow({ row, i, pos, selected, onPick, onOpen }) {
  const top = ROWS_TOP + pos * ROW_H;
  const cy = top + ROW_H / 2;
  const inv = selected;
  const bm = row.bm;
  const host = hostOf(bm.url);
  const titleMax = RIGHT - textW(host, 12) - 18 - (TITLE_X + INDENT);
  return (
    <g onClick={onPick} onDoubleClick={onOpen} style={{ cursor: "pointer" }}>
      <R x={ROW_X} y={top} w={ROW_W} h={ROW_H} fill="transparent" />
      {inv && <R x={ROW_X + INDENT} y={top + 1} w={ROW_W - INDENT} h={ROW_H - 2} fill={COLOR.ink} />}
      {inv && <R x={ROW_X + INDENT} y={top + 1} w={3} h={ROW_H - 2} fill={COLOR.yellow} />}
      <L x1={BRANCH_X} y1={top} x2={BRANCH_X} y2={cy} stroke={COLOR.line} sw={1} />
      <L x1={BRANCH_X} y1={cy} x2={ICON_X + INDENT - 6} y2={cy} stroke={COLOR.line} sw={1} />
      <IconTile x={ICON_X + INDENT} y={cy} id={bm.id} title={bm.title} size={18} />
      <T x={TITLE_X + INDENT} y={cy} size={13.5} fill={inv ? COLOR.paper : COLOR.ink}>
        {truncate(bm.title, 13.5, Math.max(90, titleMax))}
      </T>
      <T x={RIGHT} y={cy} size={12} anchor="end" fill={inv ? COLOR.mint : COLOR.muted}>{host}</T>
    </g>
  );
}

function BmRow({ row, i, pos, selected, onPick, onOpen }) {
  const top = ROWS_TOP + pos * ROW_H;
  const cy = top + ROW_H / 2;
  const inv = selected;
  const bm = row.bm;
  const host = hostOf(bm.url);
  const titleMax = RIGHT - textW(host, 12) - 18 - TITLE_X;
  return (
    <g onClick={onPick} onDoubleClick={onOpen} style={{ cursor: "pointer" }}>
      <R x={ROW_X} y={top} w={ROW_W} h={ROW_H} fill="transparent" />
      {inv && <R x={ROW_X} y={top + 1} w={ROW_W} h={ROW_H - 2} fill={COLOR.ink} />}
      {inv && <R x={ROW_X} y={top + 1} w={3} h={ROW_H - 2} fill={COLOR.yellow} />}
      <IconTile x={ICON_X} y={cy} id={bm.id} title={bm.title} size={20} />
      <T x={TITLE_X} y={cy} size={14} fill={inv ? COLOR.paper : COLOR.ink}>
        {truncate(bm.title, 14, Math.max(90, titleMax))}
      </T>
      <T x={RIGHT} y={cy} size={12} anchor="end" fill={inv ? COLOR.mint : COLOR.muted}>{host}</T>
    </g>
  );
}

/* ================= 外壳 ================= */

function LogPane({ log }) {
  const { x, y, w, h } = LAYOUT.log;
  return (
    <g>
      <R x={x} y={y} w={w} h={h} fill={COLOR.surface} />
      {log.slice(-3).map((e, i) => (
        <T key={i} x={x + 14} y={y + 16 + i * 20} size={11.5}
           fill={e.level === "ok" ? COLOR.green : COLOR.muted}>
          {`${e.t}  ${e.text}`}
        </T>
      ))}
    </g>
  );
}

function CmdBar() {
  const { y, h } = LAYOUT.cmd;
  return (
    <g>
      <L x1={0} y1={y} x2={LAYOUT.W} y2={y} stroke={COLOR.line} />
      <T x={6} y={y + h / 2} size={14} fill={COLOR.green}>›</T>
      <T x={26} y={y + h / 2} size={13} fill={COLOR.muted} opacity={0.85}>
        : 打开命令 · / 搜索 · ? 帮助
      </T>
    </g>
  );
}

function StatusBar({ mode, expandedCount, total }) {
  const { y, h } = LAYOUT.status;
  return (
    <g>
      <R x={0} y={y} w={LAYOUT.W} h={h} fill={COLOR.forest} />
      <T x={24} y={y + h / 2} size={12} fill={COLOR.paper}>{mode}</T>
      {expandedCount > 0 && (
        <T x={24 + textW(mode, 12) + 18} y={y + h / 2} size={11.5} fill={COLOR.yellow}>
          {`已展开 ${expandedCount} 个文件夹`}
        </T>
      )}
      <T x={LAYOUT.W - 24} y={y + h / 2} size={11.5} anchor="end" fill={COLOR.mint}>
        {total} 个书签
      </T>
    </g>
  );
}

function HintsBar() {
  const pairs = [["j / k", "移动"], ["Tab", "展开 / 折叠"], ["Enter", "打开 / 切换"], ["z", "全部展开 / 折叠"], ["Esc", "折叠"], ["/", "搜索"]];
  let x = LAYOUT.margin;
  const out = [];
  for (const [k, label] of pairs) {
    const kw = Math.max(24, textW(k, TYPE.sm) + 12);
    const lw = textW(label, TYPE.sm);
    out.push(
      <g key={k}>
        <Kbd x={x} y={LAYOUT.hintY} label={k} />
        <T x={x + kw + 8} y={LAYOUT.hintY + 0.5} size={TYPE.sm} fill={COLOR.muted}>{label}</T>
      </g>
    );
    x += kw + 8 + lw + 26;
  }
  return (
    <g>
      {out}
      <T x={LAYOUT.W - LAYOUT.margin} y={LAYOUT.hintY + 0.5} size={TYPE.sm} anchor="end" fill={COLOR.purple}>
        方向二 · 文件夹在根目录原地展开
      </T>
    </g>
  );
}

/* ================= App ================= */

const EXPANDED_KEY = "frog.tree.expanded";

function loadExpanded() {
  try {
    const ids = JSON.parse(localStorage.getItem(EXPANDED_KEY) || "[]");
    return new Set(Array.isArray(ids) ? ids : []);
  } catch (e) {
    return new Set();
  }
}

function nowT() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function App() {
  const data = useMemo(frogSeedData, []);
  const roots = useMemo(() => rootItems(data), [data]);
  const [expanded, setExpanded] = useState(loadExpanded);
  const [cursorKey, setCursorKey] = useState("f:g-dev");
  const [scrollTop, setScrollTop] = useState(0);
  const [log, setLog] = useState(() => [
    { t: nowT(), level: "ok", text: `已载入 ${data.groups.length} 个文件夹 · ${data.bookmarks.length} 个书签` },
  ]);
  const pushLog = (text, level = "info") =>
    setLog((l) => l.concat({ t: nowT(), level, text }).slice(-12));

  useEffect(() => {
    try {
      localStorage.setItem(EXPANDED_KEY, JSON.stringify([...expanded]));
    } catch (e) {}
  }, [expanded]);

  useEffect(() => {
    setExpanded((prev) => {
      const valid = new Set(folderIds);
      const next = new Set([...prev].filter((id) => valid.has(id)));
      return next.size === prev.size ? prev : next;
    });
  }, [folderIds]);

  const folderIds = useMemo(() => roots.filter((r) => r.kind === "folder").map((r) => r.group.id), [roots]);
  const rows = flatten(roots, expanded);
  const idx = Math.max(0, rows.findIndex((r) => r.key === cursorKey));
  const cur = rows[idx];
  const groupName = (id) => (data.groups.find((g) => g.id === id) || {}).name || "";

  useEffect(() => {
    setScrollTop((st) => {
      let next = st;
      if (idx < st) next = idx;
      else if (idx >= st + VISIBLE) next = idx - VISIBLE + 1;
      const max = Math.max(0, rows.length - VISIBLE);
      return Math.max(0, Math.min(max, next));
    });
  }, [idx, rows.length]);

  const collapse = (groupId) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      next.delete(groupId);
      return next;
    });
  };

  const toggle = (group) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(group.id)) {
        next.delete(group.id);
        pushLog(`折叠文件夹 ${group.name}`);
      } else {
        next.add(group.id);
        pushLog(`展开文件夹 ${group.name}（${data.bookmarks.filter((b) => b.groupId === group.id).length} 项）`);
      }
      return next;
    });
  };

  const openRow = (row) => {
    if (!row) return;
    if (row.kind === "folder") {
      toggle(row.group);
      return;
    }
    const where = row.kind === "child" ? `（${groupName(row.parent)}）` : "";
    pushLog(`打开 ${row.bm.title}${where} → ${row.bm.url}`, "ok");
  };

  useEffect(() => {
    const onKey = (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const k = e.key;
      if (k === "j" || k === "ArrowDown") {
        setCursorKey((prev) => {
          const i = Math.max(0, rows.findIndex((r) => r.key === prev));
          return rows[Math.min(rows.length - 1, i + 1)].key;
        });
        e.preventDefault();
      } else if (k === "k" || k === "ArrowUp") {
        setCursorKey((prev) => {
          const i = Math.max(0, rows.findIndex((r) => r.key === prev));
          return rows[Math.max(0, i - 1)].key;
        });
        e.preventDefault();
      } else if (k === "Tab") {
        if (cur && cur.kind === "folder") toggle(cur.group);
        e.preventDefault();
      } else if (k === "Enter") {
        openRow(cur);
        e.preventDefault();
      } else if (k === "z") {
        const allOpen = expanded.size === folderIds.length;
        setExpanded(allOpen ? new Set() : new Set(folderIds));
        pushLog(allOpen ? "折叠全部文件夹" : `展开全部 ${folderIds.length} 个文件夹`);
        e.preventDefault();
      } else if (k === "Escape") {
        if (cur && cur.kind === "child") {
          collapse(cur.parent);
          setCursorKey("f:" + cur.parent);
          pushLog(`折叠文件夹 ${groupName(cur.parent)}`);
        } else if (cur && cur.kind === "folder" && expanded.has(cur.group.id)) {
          toggle(cur.group);
        } else if (expanded.size) {
          setExpanded(new Set());
          pushLog("折叠全部文件夹");
        }
        e.preventDefault();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [rows, idx, cur, expanded, data]);

  return (
    <div className="stage">
      <svg className="board" viewBox={`0 0 ${LAYOUT.W} ${LAYOUT.H}`} preserveAspectRatio="xMidYMid meet">
        <R x={0} y={0} w={LAYOUT.W} h={LAYOUT.H} fill={COLOR.paper} />

        {rows.slice(scrollTop, scrollTop + VISIBLE).map((row, k) => {
          const i = scrollTop + k;
          const selected = idx === i;
          if (row.kind === "folder") {
            return (
              <FolderRow key={row.key} row={row} i={i} pos={k} selected={selected}
                         expanded={expanded.has(row.group.id)}
                         onPick={() => setCursorKey(row.key)}
                         onToggle={() => toggle(row.group)} />
            );
          }
          if (row.kind === "child") {
            return (
              <ChildRow key={row.key} row={row} i={i} pos={k} selected={selected}
                        onPick={() => setCursorKey(row.key)} onOpen={() => openRow(row)} />
            );
          }
          return (
            <BmRow key={row.key} row={row} i={i} pos={k} selected={selected}
                   onPick={() => setCursorKey(row.key)} onOpen={() => openRow(row)} />
          );
        })}

        <LogPane log={log} />
        <CmdBar />
        <StatusBar
          mode={expanded.size ? "浏览 · 根目录（展开中）" : "浏览 · 根目录"}
          expandedCount={expanded.size}
          total={data.bookmarks.length} />
        <HintsBar />
      </svg>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
})();
