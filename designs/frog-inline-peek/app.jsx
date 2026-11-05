/* 青蛙导航 · 方向一：行内摘要 — 原型
 * 问题：根目录看不到文件夹里有哪些书签，必须 Enter 进入。
 * 方案：文件夹行右侧直接叠放前 3 个书签的首字图标，并紧跟标题摘要与总数，
 *       不展开、不切换视图，扫一眼就知道文件夹里有什么。
 * 取舍：零交互成本、始终可见；但只能预览前 2–3 个标题，长名称会被裁断。
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

/* ================= 几何 ================= */

const ROW_H = LAYOUT.rowH;
const ROW_X = LAYOUT.list.x + 6;
const ROW_W = LAYOUT.list.w - 12;
const ICON_X = ROW_X + 46;
const TITLE_X = ROW_X + 80;
const RIGHT = ROW_X + ROW_W - 4;
const LIST_CX = LAYOUT.list.x + LAYOUT.list.w / 2;

/* ================= 行 ================= */

function FolderRow({ it, i, selected, onPick, onOpen }) {
  const top = LAYOUT.list.y + i * ROW_H;
  const cy = top + ROW_H / 2;
  const inv = selected;
  const count = it.children.length;
  const rowNo = String(i + 1).padStart(3, "0");

  const countText = `共 ${count} 项`;
  const countW = textW(countText, 11.5);

  /* 叠放图标：前 3 个，16px，右对齐贴住计数 */
  const mini = it.children.slice(0, 3);
  const miniStep = 11;
  const miniW = mini.length ? 16 + (mini.length - 1) * miniStep : 0;
  const miniRight = RIGHT - countW - 14;
  const miniX = miniRight - miniW;

  /* 标题摘要：前 3 个标题，超出 N 个补 "+N" */
  const more = count > 3 ? " …" : "";
  const summary = mini.map((b) => b.title).join(" · ") + more;
  const sumRight = miniX - 12;
  const nameMaxW = 230;
  const sumMaxW = Math.max(0, sumRight - (TITLE_X + nameMaxW + 24));
  const sumText = truncate(summary, 12, sumMaxW);

  const fg = inv ? COLOR.paper : COLOR.purple;
  const sumFill = inv ? COLOR.mint : COLOR.ink2;
  const metaFill = inv ? COLOR.mint : COLOR.muted;

  return (
    <g onClick={onPick} onDoubleClick={onOpen} style={{ cursor: "pointer" }}>
      <R x={ROW_X} y={top} w={ROW_W} h={ROW_H} fill="transparent" />
      {inv && <R x={ROW_X} y={top + 1} w={ROW_W} h={ROW_H - 2} fill={COLOR.ink} />}
      {inv && <R x={ROW_X} y={top + 1} w={3} h={ROW_H - 2} fill={COLOR.yellow} />}
      <T x={ROW_X + 36} y={cy} size={11} anchor="end" fill={inv ? COLOR.yellow : COLOR.muted}>{rowNo}</T>
      <Icon name="folder" x={ICON_X} y={cy - 8} size={16} color={inv ? COLOR.mint : COLOR.purple} />
      <T x={TITLE_X} y={cy} size={14} weight={600} fill={fg}>
        {truncate(it.group.name, 14, nameMaxW)}
      </T>
      {sumMaxW > 60 && <T x={sumRight} y={cy} size={12} anchor="end" fill={sumFill}>{sumText}</T>}
      {mini.map((b, k) => (
        <IconTile key={b.id} x={miniX + k * miniStep} y={cy} id={b.id} title={b.title} size={16} />
      ))}
      <T x={RIGHT} y={cy} size={11.5} anchor="end" fill={metaFill}>{countText}</T>
    </g>
  );
}

function BmRow({ it, i, selected, onPick, onOpen }) {
  const top = LAYOUT.list.y + i * ROW_H;
  const cy = top + ROW_H / 2;
  const inv = selected;
  const bm = it.bm;
  const host = hostOf(bm.url);
  const titleMax = RIGHT - textW(host, 12) - 18 - TITLE_X;
  return (
    <g onClick={onPick} onDoubleClick={onOpen} style={{ cursor: "pointer" }}>
      <R x={ROW_X} y={top} w={ROW_W} h={ROW_H} fill="transparent" />
      {inv && <R x={ROW_X} y={top + 1} w={ROW_W} h={ROW_H - 2} fill={COLOR.ink} />}
      {inv && <R x={ROW_X} y={top + 1} w={3} h={ROW_H - 2} fill={COLOR.yellow} />}
      <T x={ROW_X + 36} y={cy} size={11} anchor="end" fill={inv ? COLOR.yellow : COLOR.muted}>
        {String(i + 1).padStart(3, "0")}
      </T>
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
  const { x, y, w, h } = LAYOUT.cmd;
  return (
    <g>
      <L x1={0} y1={y} x2={LAYOUT.W} y2={y} stroke={COLOR.line} />
      <T x={x + 6} y={y + h / 2} size={14} fill={COLOR.green}>›</T>
      <T x={x + 26} y={y + h / 2} size={13} fill={COLOR.muted} opacity={0.85}>
        : 打开命令 · / 搜索 · ? 帮助
      </T>
    </g>
  );
}

function StatusBar({ mode, total }) {
  const { y, h } = LAYOUT.status;
  return (
    <g>
      <R x={0} y={y} w={LAYOUT.W} h={h} fill={COLOR.forest} />
      <T x={24} y={y + h / 2} size={12} fill={COLOR.paper}>{mode}</T>
      <T x={LAYOUT.W - 24} y={y + h / 2} size={11.5} anchor="end" fill={COLOR.mint}>
        {total} 个书签
      </T>
    </g>
  );
}

function HintsBar() {
  const pairs = [["j / k", "移动"], ["Enter", "打开 / 进入"], ["Esc", "返回"], ["/", "搜索"], [":", "命令"]];
  let x = LAYOUT.margin;
  return (
    <g>
      {pairs.map(([k, label]) => {
        const kw = Math.max(24, textW(k, TYPE.sm) + 12);
        const lw = textW(label, TYPE.sm);
        const el = (
          <g key={k}>
            <Kbd x={x} y={LAYOUT.hintY} label={k} />
            <T x={x + kw + 8} y={LAYOUT.hintY + 0.5} size={TYPE.sm} fill={COLOR.muted}>{label}</T>
          </g>
        );
        x += kw + 8 + lw + 26;
        return el;
      })}
      <T x={LAYOUT.W - LAYOUT.margin} y={LAYOUT.hintY + 0.5} size={TYPE.sm} anchor="end" fill={COLOR.purple}>
        方向一 · 文件夹内容在行内直接预览
      </T>
    </g>
  );
}

/* ================= App ================= */

function nowT() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function App() {
  const data = useMemo(frogSeedData, []);
  const [folderId, setFolderId] = useState(null);
  const [cursor, setCursor] = useState(0);
  const [log, setLog] = useState(() => [
    { t: nowT(), level: "ok", text: `已载入 ${data.groups.length} 个文件夹 · ${data.bookmarks.length} 个书签` },
  ]);
  const pushLog = (text, level = "info") =>
    setLog((l) => l.concat({ t: nowT(), level, text }).slice(-12));

  const items = useMemo(() => {
    if (!folderId) return rootItems(data);
    const g = data.groups.find((x) => x.id === folderId);
    return data.bookmarks.filter((b) => b.groupId === folderId).sort((a, b) => a.order - b.order)
      .map((b) => ({ kind: "bm", bm: b }));
  }, [data, folderId]);

  const folder = folderId ? data.groups.find((g) => g.id === folderId) : null;
  const clamp = (n) => Math.max(0, Math.min(items.length - 1, n));

  const openItem = (it) => {
    if (it.kind === "folder") {
      setFolderId(it.group.id);
      setCursor(0);
      pushLog(`进入文件夹 ${it.group.name}（${it.children.length} 项）`, "ok");
    } else {
      pushLog(`打开 ${it.bm.title} → ${it.bm.url}`, "ok");
    }
  };

  useEffect(() => {
    const onKey = (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const k = e.key;
      if (k === "j" || k === "ArrowDown") { setCursor((c) => clamp(c + 1)); e.preventDefault(); }
      else if (k === "k" || k === "ArrowUp") { setCursor((c) => clamp(c - 1)); e.preventDefault(); }
      else if (k === "Enter") { if (items[cursor]) openItem(items[cursor]); e.preventDefault(); }
      else if (k === "Escape") {
        if (folderId) { setFolderId(null); setCursor(0); pushLog("返回根目录"); }
        e.preventDefault();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [items, cursor, folderId]);

  /* 单页可视区：方向一不做分页，超出部分滚动由后续迭代处理（种子数据一屏可放下） */
  const visible = Math.floor((LAYOUT.log.y - 16 - LAYOUT.list.y) / ROW_H);
  const rows = items.slice(0, visible);

  return (
    <div className="stage">
      <svg className="board" viewBox={`0 0 ${LAYOUT.W} ${LAYOUT.H}`} preserveAspectRatio="xMidYMid meet">
        <R x={0} y={0} w={LAYOUT.W} h={LAYOUT.H} fill={COLOR.paper} />

        {folder && (
          <g>
            <g onClick={() => { setFolderId(null); setCursor(0); pushLog("返回根目录"); }} style={{ cursor: "pointer" }}>
              <T x={ROW_X} y={LAYOUT.list.y + 10} size={12.5} fill={COLOR.green}>根目录</T>
            </g>
            <T x={ROW_X + textW("根目录", 12.5) + 8} y={LAYOUT.list.y + 10} size={12} fill={COLOR.muted}>›</T>
            <T x={ROW_X + textW("根目录", 12.5) + 22} y={LAYOUT.list.y + 10} size={16} weight={700} fill={COLOR.ink}>
              {folder.name}
            </T>
          </g>
        )}

        {rows.map((it, i) => it.kind === "folder" ? (
          <FolderRow key={it.group.id} it={it} i={i} selected={cursor === i}
                     onPick={() => setCursor(i)} onOpen={() => openItem(it)} />
        ) : (
          <BmRow key={it.bm.id} it={it} i={i} selected={cursor === i}
                 onPick={() => setCursor(i)} onOpen={() => openItem(it)} />
        ))}

        <LogPane log={log} />
        <CmdBar />
        <StatusBar mode={folder ? `文件夹 · ${folder.name}` : "浏览 · 根目录"} total={data.bookmarks.length} />
        <HintsBar />
      </svg>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
})();
