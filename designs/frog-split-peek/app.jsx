/* 青蛙导航 · 方向三：双栏预览 — 原型
 * 问题：根目录看不到文件夹里有哪些书签，必须 Enter 进入。
 * 方案：列表收窄到左侧，右侧常驻预览栏；光标停在文件夹时实时列出全部子书签，
 *       光标停在书签时显示网址、位置与创建时间。预览只读，Enter 才真正进入或打开。
 * 取舍：能看到完整内容与书签详情；代价是列表变窄、标题更早截断，且占用横向空间。
 * 视觉与交互沿用回声终端规格：1440×900 SVG、j/k 移动、Enter 打开、Esc 返回。
 */
(function () {
"use strict";
const { useState, useEffect, useMemo } = React;

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

function fmtDate(ts) {
  const d = new Date(ts);
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
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
const LIST_W = 880;
const ROW_X = LAYOUT.list.x + 6;
const ROW_W = LIST_W - 12;
const RIGHT = ROW_X + ROW_W - 4;
const ICON_X = ROW_X + 46;
const TITLE_X = ROW_X + 80;
const ROWS_TOP = LAYOUT.list.y;

const PANEL = { x: 944, y: 24, w: 456, h: 600 };
const PX = PANEL.x + 16;
const PR = PANEL.x + PANEL.w - 16;

/* ================= 左列表行 ================= */

function FolderRow({ it, i, selected, onPick, onOpen }) {
  const top = ROWS_TOP + i * ROW_H;
  const cy = top + ROW_H / 2;
  const inv = selected;
  const nameMax = RIGHT - TITLE_X - 90;
  return (
    <g onClick={onPick} onDoubleClick={onOpen} style={{ cursor: "pointer" }}>
      <R x={ROW_X} y={top} w={ROW_W} h={ROW_H} fill="transparent" />
      {inv && <R x={ROW_X} y={top + 1} w={ROW_W} h={ROW_H - 2} fill={COLOR.ink} />}
      {inv && <R x={ROW_X} y={top + 1} w={3} h={ROW_H - 2} fill={COLOR.yellow} />}
      <T x={ROW_X + 36} y={cy} size={11} anchor="end" fill={inv ? COLOR.yellow : COLOR.muted}>
        {String(i + 1).padStart(3, "0")}
      </T>
      <Icon name="folder" x={ICON_X} y={cy - 8} size={16} color={inv ? COLOR.mint : COLOR.purple} />
      <T x={TITLE_X} y={cy} size={14} weight={600} fill={inv ? COLOR.paper : COLOR.purple}>
        {truncate(it.group.name, 14, nameMax)}
      </T>
      <T x={RIGHT} y={cy} size={11.5} anchor="end" fill={inv ? COLOR.mint : COLOR.muted}>{it.children.length} 项</T>
    </g>
  );
}

function BmRow({ it, i, selected, onPick, onOpen }) {
  const top = ROWS_TOP + i * ROW_H;
  const cy = top + ROW_H / 2;
  const inv = selected;
  const bm = it.bm;
  const host = hostOf(bm.url);
  const titleMax = RIGHT - textW(host, 12) - 16 - TITLE_X;
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

/* ================= 右预览栏 ================= */

function PanelShell({ children }) {
  return (
    <g>
      <R x={PANEL.x} y={PANEL.y} w={PANEL.w} h={PANEL.h} fill={COLOR.surface} stroke={COLOR.line} sw={1} />
      {children}
    </g>
  );
}

function FolderPanel({ it, onOpen }) {
  const top = PANEL.y + 16;
  const rowsTop = PANEL.y + 88;
  const fit = Math.floor((PANEL.h - 88 - 44) / 34);
  const shown = it.children.slice(0, fit);
  return (
    <PanelShell>
      <T x={PX} y={top + 6} size={10.5} fill={COLOR.muted}>文件夹预览</T>
      <Icon name="folderOpen" x={PX} y={top + 24} size={16} color={COLOR.purple} />
      <T x={PX + 24} y={top + 32} size={15} weight={700} fill={COLOR.purple}>
        {truncate(it.group.name, 15, 260)}
      </T>
      <T x={PR} y={top + 32} size={11.5} anchor="end" fill={COLOR.muted}>{it.children.length} 项</T>
      <L x1={PX} y1={PANEL.y + 72} x2={PR} y2={PANEL.y + 72} stroke={COLOR.line} />
      {shown.map((b, k) => {
        const cy = rowsTop + k * 34 + 17;
        return (
          <g key={b.id} onClick={() => onOpen(b)} style={{ cursor: "pointer" }}>
            <R x={PX - 8} y={cy - 15} w={PANEL.w - 16} h={30} fill="transparent" />
            <IconTile x={PX} y={cy} id={b.id} title={b.title} size={18} />
            <T x={PX + 28} y={cy} size={13} fill={COLOR.ink}>
              {truncate(b.title, 13, PR - PX - 28 - textW(hostOf(b.url), 11) - 16)}
            </T>
            <T x={PR} y={cy} size={11} anchor="end" fill={COLOR.muted}>{hostOf(b.url)}</T>
          </g>
        );
      })}
      {it.children.length === 0 && (
        <T x={PX} y={rowsTop + 24} size={12} fill={COLOR.muted}>空文件夹</T>
      )}
      <T x={PX} y={PANEL.y + PANEL.h - 20} size={11} fill={COLOR.teal}>Enter 进入文件夹</T>
    </PanelShell>
  );
}

function DetailPanel({ bm, location }) {
  const top = PANEL.y + 16;
  const tileY = top + 72;
  const rows = [
    ["网址", bm.url],
    ["位置", location],
    ["添加", fmtDate(bm.createdAt)],
  ];
  return (
    <PanelShell>
      <T x={PX} y={top + 6} size={10.5} fill={COLOR.muted}>书签详情</T>
      <T x={PR} y={top + 6} size={10.5} anchor="end" fill={COLOR.muted}>{hostOf(bm.url)}</T>
      <IconTile x={PX} y={tileY} id={bm.id} title={bm.title} size={40} />
      <T x={PX + 56} y={tileY - 9} size={16} weight={700} fill={COLOR.ink}>
        {truncate(bm.title, 16, PR - PX - 56)}
      </T>
      <T x={PX + 56} y={tileY + 12} size={11.5} fill={COLOR.teal}>
        {truncate(bm.url, 11.5, PR - PX - 56)}
      </T>
      <L x1={PX} y1={PANEL.y + 120} x2={PR} y2={PANEL.y + 120} stroke={COLOR.line} />
      {rows.map(([label, value], k) => (
        <g key={label}>
          <T x={PX} y={PANEL.y + 148 + k * 26} size={11} fill={COLOR.muted}>{label}</T>
          <T x={PX + 44} y={PANEL.y + 148 + k * 26} size={11.5} fill={COLOR.ink2}>
            {truncate(value, 11.5, PR - PX - 44)}
          </T>
        </g>
      ))}
      <L x1={PX} y1={PANEL.y + 236} x2={PR} y2={PANEL.y + 236} stroke={COLOR.line} dash="2 3" />
      <T x={PX} y={PANEL.y + PANEL.h - 20} size={11} fill={COLOR.teal}>Enter 打开 · C 复制网址</T>
    </PanelShell>
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
        方向三 · 右侧实时预览选中项
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
  const roots = useMemo(() => rootItems(data), [data]);
  const [folderId, setFolderId] = useState(null);
  const [cursorKey, setCursorKey] = useState("f:g-dev");
  const [log, setLog] = useState(() => [
    { t: nowT(), level: "ok", text: `已载入 ${data.groups.length} 个文件夹 · ${data.bookmarks.length} 个书签` },
  ]);
  const pushLog = (text, level = "info") =>
    setLog((l) => l.concat({ t: nowT(), level, text }).slice(-12));

  const folder = folderId ? data.groups.find((g) => g.id === folderId) : null;
  const rows = useMemo(() => {
    if (!folderId) {
      return roots.map((r) => r.kind === "folder"
        ? { ...r, key: "f:" + r.group.id }
        : { ...r, key: "b:" + r.bm.id });
    }
    return data.bookmarks.filter((b) => b.groupId === folderId).sort((a, b) => a.order - b.order)
      .map((b) => ({ kind: "bm", key: "b:" + b.id, bm: b }));
  }, [data, roots, folderId]);

  const idx = Math.max(0, rows.findIndex((r) => r.key === cursorKey));
  const cur = rows[idx];
  const visible = Math.floor((LAYOUT.log.y - 16 - ROWS_TOP) / ROW_H);
  const shown = rows.slice(0, visible);

  const logOpen = (bm) => pushLog(`打开 ${bm.title} → ${bm.url}`, "ok");

  const openRow = (row) => {
    if (!row) return;
    if (row.kind === "folder") {
      setFolderId(row.group.id);
      setCursorKey(row.children.length ? "b:" + row.children[0].id : "f:" + row.group.id);
      pushLog(`进入文件夹 ${row.group.name}`, "ok");
    } else {
      logOpen(row.bm);
    }
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
      } else if (k === "Enter") {
        openRow(cur);
        e.preventDefault();
      } else if (k === "C") {
        if (cur && cur.kind !== "folder") {
          pushLog(`已复制 ${cur.bm.url}`, "ok");
          if (navigator.clipboard) navigator.clipboard.writeText(cur.bm.url).catch(() => {});
        }
        e.preventDefault();
      } else if (k === "Escape") {
        if (folderId) {
          setFolderId(null);
          setCursorKey("f:" + folderId);
          pushLog("返回根目录");
        }
        e.preventDefault();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [rows, idx, cur, folderId]);

  return (
    <div className="stage">
      <svg className="board" viewBox={`0 0 ${LAYOUT.W} ${LAYOUT.H}`} preserveAspectRatio="xMidYMid meet">
        <R x={0} y={0} w={LAYOUT.W} h={LAYOUT.H} fill={COLOR.paper} />

        {folder && (
          <g>
            <g onClick={() => { setFolderId(null); setCursorKey("f:" + folder.id); pushLog("返回根目录"); }} style={{ cursor: "pointer" }}>
              <T x={ROW_X} y={LAYOUT.list.y + 10} size={12.5} fill={COLOR.green}>根目录</T>
            </g>
            <T x={ROW_X + textW("根目录", 12.5) + 8} y={LAYOUT.list.y + 10} size={12} fill={COLOR.muted}>›</T>
            <T x={ROW_X + textW("根目录", 12.5) + 22} y={LAYOUT.list.y + 10} size={16} weight={700} fill={COLOR.ink}>
              {folder.name}
            </T>
          </g>
        )}

        {shown.map((it, i) => it.kind === "folder" ? (
          <FolderRow key={it.group.id} it={it} i={i} selected={idx === i}
                     onPick={() => setCursorKey("f:" + it.group.id)} onOpen={() => openRow(it)} />
        ) : (
          <BmRow key={"b:" + it.bm.id} it={it} i={i} selected={idx === i}
                 onPick={() => setCursorKey("b:" + it.bm.id)} onOpen={() => openRow(it)} />
        ))}

        {cur && cur.kind === "folder" && <FolderPanel it={cur} onOpen={logOpen} />}
        {cur && cur.kind !== "folder" && (
          <DetailPanel bm={cur.bm} location={folder ? folder.name : "根目录"} />
        )}

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
