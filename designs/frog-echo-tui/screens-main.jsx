/* 青蛙导航 · 回声终端 — 主流程内容区
 * 只绘制单列表内容区；命令行 / 状态栏 / 按键条由 app.jsx 绘制。
 * 视觉全部为 SVG，色值只取自 COLOR，坐标基于 1440×900 画板。
 */

(function () {
"use strict";

const FM_ROW_H = LAYOUT.rowH;
const FM_ROW_X = LAYOUT.list.x + 6;
const FM_ROW_W = LAYOUT.list.w - 12;
const FM_BLOCK_H = FM_ROW_H - 2;
const FM_LIST_CX = LAYOUT.list.x + LAYOUT.list.w / 2;
const FM_ICON_X = FM_ROW_X + 46;
const FM_TITLE_X = FM_ROW_X + 80;
const FM_RIGHT = FM_ROW_X + FM_ROW_W - 4;


/* 列表几何：单页滚动，可视行数由画板高度决定；文件夹内让出面包屑高度 */
function fmListGeom(showCrumb) {
  const g = frogListGeom(showCrumb);
  return {
    rowsTop: g.rowsTop,
    rowsBottom: g.rowsBottom,
    visible: g.visible,
  };
}


/* ================= 面包屑 ================= */

function fmCrumbs(ctx) {
  const { act } = ctx;
  const y = LAYOUT.list.y + 19;
  const x = FM_ROW_X;
  const backW = textW("根目录", 12.5);
  return (
    <g key="crumbs">
      <g onClick={() => act.closeFolder()} style={{ cursor: "pointer" }}>
        <T x={x} y={y} size={12.5} fill={COLOR.green}>根目录</T>
      </g>
      <T x={x + backW + 8} y={y} size={12} fill={COLOR.muted}>›</T>
      <T x={x + backW + 22} y={y} size={16} weight={700} fill={COLOR.ink}>
        {truncate(ctx.folderName, 16, 600)}
      </T>
    </g>
  );
}

/* ================= 行 ================= */

function fmRenderRow(ctx, it, i, geom) {
  const { s, act } = ctx;
  const top = geom.rowsTop + i * FM_ROW_H;
  const cy = top + FM_ROW_H / 2;
  const moving = s.mode === "move";
  const organize = s.mode === "organize";
  const isTarget = moving && s.moveTarget === i;
  const selected = s.cursor === i;
  const inverse = selected && !isTarget;
  const struck = moving && it.kind === "bookmark" && s.moveSource === it.bm.id;
  const addOffset = ctx.items[0] && ctx.items[0].kind === "add" ? 1 : 0;
  const rowNo = String(i - addOffset + 1).padStart(3, "0");

  const fg = inverse ? COLOR.paper : COLOR.ink;
  const metaFill = inverse ? COLOR.mint : COLOR.muted;
  const indexFill = selected ? (inverse ? COLOR.yellow : COLOR.ink) : COLOR.muted;
  const danger = inverse ? COLOR.lemon : COLOR.red;

  // SVG 分组本身没有点击面积：整行提供透明命中区，而不是仅文字和图标。
  const pieces = [<R key="hit" x={FM_ROW_X} y={top} w={FM_ROW_W} h={FM_ROW_H} fill="transparent" />];
  if (selected && !isTarget) {
    pieces.push(<R key="bg" x={FM_ROW_X} y={top + 1} w={FM_ROW_W} h={FM_BLOCK_H} fill={COLOR.ink} />);
    pieces.push(<R key="bar" x={FM_ROW_X} y={top + 1} w={3} h={FM_BLOCK_H} fill={COLOR.yellow} />);
  }

  const rowStyle = { cursor: "pointer" };
  const onRow = () => act.setCursor(i);

  /* 添加行（文件夹首行） */
  if (it.kind === "add") {
    return (
      <g key="row-add" onClick={() => act.startAdd()} style={rowStyle}>
        {pieces}
        <Icon name="plus" x={FM_ICON_X} y={cy - 8} size={16} color={inverse ? COLOR.mint : COLOR.green} />
        <T x={FM_TITLE_X} y={cy} size={14} weight={600} fill={inverse ? COLOR.mint : COLOR.green}>添加书签</T>
        <Kbd x={1368} y={cy} label="a" size={10} dark={inverse} />
      </g>
    );
  }

  /* 文件夹行 */
  if (it.kind === "folder") {
    pieces.push(<T key="idx" x={FM_ROW_X + 36} y={cy} size={11} anchor="end" fill={indexFill}>{rowNo}</T>);
    pieces.push(<Icon key="icon" name="folder" x={FM_ICON_X} y={cy - 8} size={16} color={inverse ? COLOR.mint : COLOR.purple} />);
    pieces.push(
      <T key="name" x={FM_TITLE_X} y={cy} size={14} weight={600} fill={inverse ? COLOR.paper : COLOR.purple}>
        {truncate(it.group.name, 14, FM_RIGHT - FM_TITLE_X - 120)}
      </T>
    );
    pieces.push(<T key="count" x={FM_RIGHT} y={cy} size={11.5} anchor="end" fill={metaFill}>{it.count} 项{organize ? " · 固定" : ""}</T>);
    return (
      <g key={"row-folder-" + it.group.id} onClick={onRow} style={rowStyle}
         onDoubleClick={() => act.openFolder(it.group.id)}>
        {pieces}
      </g>
    );
  }

  /* 书签行 */
  const bm = it.bm;
  const host = hostOf(bm.url);
  const hostW = textW(host, 12);
  let titleMax = (FM_RIGHT - hostW - 18) - FM_TITLE_X;
  const tagLabel = s.query.trim() ? it.groupName : null;
  const tagW = tagLabel ? textW(tagLabel, 10) + 10 : 0;
  if (tagLabel) titleMax -= tagW + 12;
  const titleStr = truncate(bm.title, 14, Math.max(90, titleMax));

  if (organize) {
    pieces.push(
      <g key="del" style={{ cursor: "pointer" }}
         onClick={(e) => { e.stopPropagation(); act.requestDelete(it); }}>
        <T x={FM_ROW_X + 8} y={cy} size={12} weight={600} fill={danger}>[×]</T>
      </g>
    );
  } else {
    pieces.push(<T key="idx" x={FM_ROW_X + 36} y={cy} size={11} anchor="end" fill={indexFill}>{rowNo}</T>);
  }

  pieces.push(<IconTile key="tile" x={FM_ICON_X} y={cy} id={bm.id} title={bm.title} size={20} />);
  pieces.push(
    <T key="title" x={FM_TITLE_X} y={cy} size={14} fill={fg} style={struck ? { textDecoration: "line-through" } : undefined}>
      {titleStr}
    </T>
  );
  if (tagLabel) {
    const tagX = FM_TITLE_X + textW(titleStr, 14) + 10;
    pieces.push(
      <Tag key="tag" x={tagX} y={cy} label={truncate(tagLabel, 10, 220)} fill={COLOR.line} fg={COLOR.purple} size={10} px={5} />
    );
  }
  pieces.push(<T key="host" x={FM_RIGHT} y={cy} size={12} anchor="end" fill={metaFill}>{host}</T>);

  return (
    <g key={"row-bm-" + bm.id} onClick={onRow} style={rowStyle} opacity={struck ? 0.45 : 1}
       onDoubleClick={() => act.openBookmark(bm.id)}>
      {pieces}
    </g>
  );
}

/* ================= 提示 / 空态 / 骨架 ================= */

function fmEmptyBlock(key, title, sub) {
  return (
    <g key={key}>
      <T x={FM_LIST_CX} y={352} size={38} anchor="middle" fill={COLOR.muted} opacity={0.42}>∅</T>
      <T x={FM_LIST_CX} y={402} size={15} weight={600} anchor="middle" fill={COLOR.ink2}>{title}</T>
      <T x={FM_LIST_CX} y={428} size={12} anchor="middle" fill={COLOR.muted}>{sub}</T>
    </g>
  );
}

function fmSearchEmpty(query) {
  const q = truncate(query.trim(), 12, 220);
  const text = `用默认浏览器搜索“${q}”`;
  const kw = Math.max(20, textW("Enter", 10) + 10);
  const tw = textW(text, 12);
  const startX = FM_LIST_CX - (kw + 10 + tw) / 2;
  return (
    <g key="search-empty">
      <Icon name="search" x={FM_LIST_CX - 14} y={324} size={28} color={COLOR.muted} opacity={0.6} />
      <T x={FM_LIST_CX} y={388} size={16} weight={600} anchor="middle" fill={COLOR.ink2}>没有匹配的书签</T>
      <Kbd x={startX} y={420} label="Enter" size={10} />
      <T x={startX + kw + 10} y={420} size={12} fill={COLOR.muted}>{text}</T>
    </g>
  );
}

function fmCorruptState() {
  return (
    <g key="corrupt">
      <Icon name="warn" x={FM_LIST_CX - 18} y={324} size={36} color={COLOR.red} />
      <T x={FM_LIST_CX} y={392} size={15} weight={600} anchor="middle" fill={COLOR.red}>数据文件已损坏，原文件已保留</T>
      <T x={FM_LIST_CX} y={420} size={11.5} anchor="middle" fill={COLOR.muted}>未写入新数据 · 可重试或更换数据目录</T>
    </g>
  );
}

function fmSkeleton(geom) {
  const rows = [];
  for (let i = 0; i < 10; i++) {
    const top = geom.rowsTop + i * FM_ROW_H;
    rows.push(
      <g key={i} opacity={0.9 - i * 0.035}>
        <R x={FM_ROW_X} y={top + 1} w={FM_ROW_W} h={FM_BLOCK_H} stroke={COLOR.line} sw={1} dash="4 5" />
        <R x={FM_ICON_X} y={top + 8} w={18} h={18} stroke={COLOR.line} sw={1} dash="3 3" />
        <R x={FM_TITLE_X} y={top + 14} w={150 + (i % 3) * 42} h={8} stroke={COLOR.line} sw={1} dash="3 4" />
        <R x={1270 - (i % 2) * 26} y={top + 14} w={110} h={8} stroke={COLOR.line} sw={1} dash="3 4" />
      </g>
    );
  }
  return (
    <g key="loading">
      {rows}
      <Icon name="refresh" x={FM_LIST_CX - 62} y={geom.rowsTop + 392} size={14} color={COLOR.teal} />
      <T x={FM_LIST_CX - 42} y={geom.rowsTop + 399} size={12} fill={COLOR.teal}>载入书签数据…</T>
    </g>
  );
}

/* ================= 移动模式 ================= */

function fmMoveUnderlay(ctx, geom) {
  const { s } = ctx;
  if (s.mode !== "move" || s.moveTarget == null) return null;
  const t = s.moveTarget;
  const target = ctx.items[t];
  if (!target || target.kind === "add") return null;
  const top = geom.rowsTop + t * FM_ROW_H;
  return <R key="move-under" x={FM_ROW_X} y={top + 1} w={FM_ROW_W} h={FM_BLOCK_H} fill={COLOR.mint} />;
}

function fmMoveOverlay(ctx, geom) {
  const { s } = ctx;
  if (s.mode !== "move") return null;

  const t = s.moveTarget == null ? s.cursor : s.moveTarget;
  const items = ctx.items;
  const src = s.doc.bookmarks.find((b) => b.id === s.moveSource);
  const target = items[t] || null;
  const lineY = geom.rowsTop + Math.min(t, items.length) * FM_ROW_H;

  let label = "插入到此";
  if (target && target.kind === "folder") label = `移入「${target.group.name}」`;
  else if (target && target.kind === "bookmark" && target.bm.id !== s.moveSource && !s.moveReorder) label = "＋ 创建文件夹";

  const labelW = textW(label, 11) + 16;
  const labelX = 1394 - labelW;

  const out = [
    <R key="line" x={FM_ROW_X} y={lineY - 1} w={FM_ROW_W} h={2} fill={COLOR.green} />,
    <R key="label-bg" x={labelX} y={lineY - 24} w={labelW} h={18} fill={COLOR.mint} />,
    <T key="label" x={labelX + 8} y={lineY - 15} size={11} weight={600} fill={COLOR.pine}>{label}</T>,
  ];

  if (target && target.kind !== "add") {
    const top = geom.rowsTop + t * FM_ROW_H;
    out.push(<R key="frame" x={FM_ROW_X} y={top + 1} w={FM_ROW_W} h={FM_BLOCK_H} stroke={COLOR.green} sw={2} />);
  }

  return <g key="move-overlay">{out}</g>;
}

/* ================= 内容区 ================= */

function fmRenderContent(ctx) {
  const { s, view } = ctx;
  const geom = fmListGeom(frogShowsCrumb(s));
  const loading = s.flags.loading;
  const corrupt = s.flags.corrupt;
  const q = s.query.trim();
  const total = view.all.length;
  const noRows = ctx.items.length === 0;
  const onlyAdd = ctx.items.length === 1 && ctx.items[0].kind === "add" && !q;
  const searchEmpty = !loading && !corrupt && !!q && noRows;
  const emptyRoot = !loading && !corrupt && !q && !s.folderId && total === 0;
  const emptyFolder = !loading && !corrupt && !q && !!s.folderId && onlyAdd;
  const showRows = !loading && !corrupt && !searchEmpty && !emptyRoot;

  const rows = [];
  if (showRows) {
    ctx.items.forEach((it, i) => rows.push(fmRenderRow(ctx, it, i, geom)));
  }
  const scrollRows = (e) => ctx.act.scrollBy(
    Math.sign(e.deltaY) * Math.max(1, Math.round(Math.abs(e.deltaY) / 40))
  );

  return (
    <g key="main-content">

      <defs>
        <clipPath id="frogListClip">
          <rect x={LAYOUT.list.x} y={geom.rowsTop}
                width={LAYOUT.list.w} height={geom.rowsBottom - geom.rowsTop} />
        </clipPath>
      </defs>

      {frogShowsCrumb(s) ? fmCrumbs(ctx) : null}

      {loading ? fmSkeleton(geom) : null}
      {!loading && corrupt ? fmCorruptState() : null}
      {!loading && searchEmpty ? fmSearchEmpty(s.query) : null}
      {!loading && emptyRoot ? fmEmptyBlock("empty-root", "无书签", "按 a 添加第一条书签") : null}
      {!loading && emptyFolder ? fmEmptyBlock("empty-folder", "无书签", "按 a 添加第一条书签") : null}

      {showRows ? (
        <g key="list-scroll" clipPath="url(#frogListClip)" onWheel={scrollRows}>
          <g transform={`translate(0 ${-ctx.scroll * FM_ROW_H})`}>
            {fmMoveUnderlay(ctx, geom)}
            {rows}
            {!onlyAdd && !searchEmpty ? fmMoveOverlay(ctx, geom) : null}
          </g>
        </g>
      ) : null}
    </g>
  );
}

/* ================= 对外接口 ================= */

window.FrogMain = {
  renderContent: fmRenderContent,
};

})();
