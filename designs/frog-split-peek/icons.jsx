/* 青蛙导航 · 回声终端 — 内联 SVG 图标（16 × 16 线框，stroke = currentColor） */

const ICON_PATHS = {
  search: <><circle cx="7" cy="7" r="4.5" /><path d="M10.4 10.4L14 14" /></>,
  gear: <><circle cx="8" cy="8" r="2.4" /><path d="M8 1.6v2M8 12.4v2M1.6 8h2M12.4 8h2M3.5 3.5l1.4 1.4M11.1 11.1l1.4 1.4M12.5 3.5l-1.4 1.4M4.9 11.1l-1.4 1.4" /></>,
  plus: <path d="M8 3v10M3 8h10" />,
  folder: <path d="M2 4.5c0-.7.6-1.2 1.2-1.2h3l1.4 1.6h5.2c.7 0 1.2.6 1.2 1.2v6.2c0 .7-.6 1.2-1.2 1.2H3.2c-.7 0-1.2-.6-1.2-1.2z" />,
  folderOpen: <><path d="M2 5V4.4c0-.7.6-1.2 1.2-1.2h3l1.4 1.6h4.6c.7 0 1.2.6 1.2 1.2V7" /><path d="M2.2 7h11.6l-1.5 6.3c-.1.5-.6.9-1.1.9H3.2c-.6 0-1-.4-1-.9z" /></>,
  chevronR: <path d="M6 3.5L10.5 8 6 12.5" />,
  chevronD: <path d="M3.5 6L8 10.5 12.5 6" />,
  check: <path d="M3 8.4L6.4 12 13 4.4" />,
  close: <path d="M3.6 3.6l8.8 8.8M12.4 3.6l-8.8 8.8" />,
  warn: <><path d="M8 2.2L14.4 13.4H1.6z" /><path d="M8 6v3.4" /><circle cx="8" cy="11.5" r=".6" fill="currentColor" stroke="none" /></>,
  info: <><circle cx="8" cy="8" r="6" /><path d="M8 7.2v4" /><circle cx="8" cy="5" r=".6" fill="currentColor" stroke="none" /></>,
  external: <><path d="M9 3h4v4" /><path d="M13 3L7.5 8.5" /><path d="M12 9.5V13H3V4h3.5" /></>,
  copy: <><rect x="5.2" y="5.2" width="8" height="8" rx="1" /><path d="M10.8 5.2V3.8c0-.6-.4-1-1-1H3.8c-.6 0-1 .4-1 1v6c0 .6.4 1 1 1h1.4" /></>,
  pencil: <><path d="M11.2 2.6l2.2 2.2L5 13.2l-2.9.7.7-2.9z" /></>,
  refresh: <><path d="M13.2 7A5.3 5.3 0 1 0 12 11.5" /><path d="M13.4 2.8V7H9.2" /></>,
  trash: <><path d="M3 4.5h10M6 4.5V3h4v1.5M4.2 4.5l.6 9h6.4l.6-9" /><path d="M6.6 7v4M9.4 7v4" /></>,
  keyboard: <><rect x="1.6" y="4" width="12.8" height="8" rx="1" /><path d="M4 6.5h.8M7.6 6.5H8.4M11.2 6.5h.8M4 9.5h8" /></>,
  corner: <><path d="M2.5 2.5h4v4h-4z" /><path d="M9.5 9.5h4v4h-4z" /><path d="M6.5 2.5h7M2.5 6.5v7M9.5 6.5h4M6.5 13.5h7" opacity=".55" /></>,
  power: <><path d="M8 2.4v5" /><path d="M4.6 4.4a5.2 5.2 0 1 0 6.8 0" /></>,
  finder: <><rect x="2" y="3" width="12" height="10" rx="1" /><path d="M2 6h12" /><path d="M6.2 9.2v2M9.8 9.2v2" /></>,
  export: <><path d="M8 10V2.6M5.2 5.4L8 2.6l2.8 2.8" /><path d="M3 9.5V13h10V9.5" /></>,
  import: <><path d="M8 2.4V9.8M5.2 7L8 9.8 10.8 7" /><path d="M3 11v2h10v-2" /></>,
  move: <><path d="M8 2.2v11.6M2.2 8h11.6" /><path d="M6.2 4l1.8-1.8L9.8 4M6.2 12l1.8 1.8 1.8-1.8M4 6.2L2.2 8 4 9.8M12 6.2L13.8 8 12 9.8" /></>,
  dot: <circle cx="8" cy="8" r="2.6" fill="currentColor" stroke="none" />,
  page: <><rect x="3" y="2" width="10" height="12" rx="1" /><path d="M5.4 5h5.2M5.4 8h5.2M5.4 11h3.2" /></>,
  level: <><path d="M2 12.4h2.4V9.6H2zM6.8 12.4h2.4V6.4H6.8zM11.6 12.4H14V3.2h-2.4z" /></>,
  link: <><path d="M6.6 9.4l2.8-2.8" /><path d="M7.4 4.8l1-1a2.6 2.6 0 0 1 3.8 3.8l-1 1" /><path d="M8.6 11.2l-1 1A2.6 2.6 0 0 1 3.8 8.4l1-1" /></>,
  clock: <><circle cx="8" cy="8" r="6" /><path d="M8 4.4V8l2.6 1.6" /></>,
};

function Icon({ name, x = 0, y = 0, size = 16, color = COLOR.ink, opacity = 1, strokeWidth = 1.4 }) {
  const art = ICON_PATHS[name];
  if (!art) return null;
  const s = size / 16;
  return (
    <g transform={`translate(${x},${y}) scale(${s})`} fill="none" stroke={color}
       strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" opacity={opacity}>
      {art}
    </g>
  );
}

