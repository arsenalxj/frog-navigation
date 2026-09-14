/* 青蛙导航 Windows 启动台原型 — 内联 SVG 图标
 * 风格对齐 Segoe Fluent Icons：几何、细描边、方端为主；
 * 另含 Windows 11 任务栏所需的徽标图标（开始 / 搜索 / 任务视图 / Edge / 资源管理器 / 托盘）。
 */

function IcSearch({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4">
      <circle cx="7" cy="7" r="4.8"></circle>
      <line x1="10.8" y1="10.8" x2="14" y2="14"></line>
    </svg>
  );
}

function IcGear({ size = 17 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 18 18" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <circle cx="9" cy="9" r="2.3"></circle>
      <path d="M9 1.6v1.8M9 14.6v1.8M1.6 9h1.8M14.6 9h1.8M3.8 3.8l1.3 1.3M12.9 12.9l1.3 1.3M14.2 3.8l-1.3 1.3M5.1 12.9l-1.3 1.3"></path>
    </svg>
  );
}

function IcPlus({ size = 22 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6">
      <line x1="12" y1="5" x2="12" y2="19"></line>
      <line x1="5" y1="12" x2="19" y2="12"></line>
    </svg>
  );
}

function IcClose({ size = 10 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.8">
      <line x1="2" y1="2" x2="10" y2="10"></line>
      <line x1="10" y1="2" x2="2" y2="10"></line>
    </svg>
  );
}

function IcChevronRight({ size = 12 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round">
      <polyline points="4.5 2.5 8 6 4.5 9.5"></polyline>
    </svg>
  );
}

function IcChevronUp({ size = 12 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round">
      <polyline points="2.5 7.5 6 4 9.5 7.5"></polyline>
    </svg>
  );
}

function IcExternal({ size = 14 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <path d="M8 2h4v4"></path>
      <path d="M12 2 6.5 7.5"></path>
      <path d="M9.5 8.5V11a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V5.5a1 1 0 0 1 1-1h2.5"></path>
    </svg>
  );
}

function IcLink({ size = 14 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <path d="M5.8 8.2a3 3 0 0 0 4.2 0l2-2a3 3 0 1 0-4.2-4.2l-1 1"></path>
      <path d="M8.2 5.8a3 3 0 0 0-4.2 0l-2 2a3 3 0 1 0 4.2 4.2l1-1"></path>
    </svg>
  );
}

function IcPencil({ size = 14 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <path d="M9.8 2.4a1.5 1.5 0 0 1 2.1 2.1L4.5 12H2.3V9.8l7.5-7.4z"></path>
    </svg>
  );
}

function IcRefresh({ size = 14 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <path d="M12 7A5 5 0 1 1 7 2c1.9 0 3.5 1 4.4 2.6"></path>
      <polyline points="12 1.5 12 4.8 8.8 4.8"></polyline>
    </svg>
  );
}

function IcFolderMove({ size = 14 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h2L7 4.5h4.5A1.5 1.5 0 0 1 13 6v4.5a1.5 1.5 0 0 1-1.5 1.5h-8A1.5 1.5 0 0 1 2 10.5v-6z"></path>
      <path d="M7 7v3.4M5.6 8.8 7 7.4l1.4 1.4"></path>
    </svg>
  );
}

function IcTrash({ size = 14 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <path d="M1.8 3.6h10.4M5.5 3.4V2.3a.8.8 0 0 1 .8-.8h1.4a.8.8 0 0 1 .8.8v1.1M3.4 3.8l.6 7.4a1 1 0 0 0 1 .9h4a1 1 0 0 0 1-.9l.6-7.4"></path>
    </svg>
  );
}

function IcCheck({ size = 14 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round">
      <polyline points="3 8.5 6.5 12 13 4.5"></polyline>
    </svg>
  );
}

function IcFolder({ size = 14 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <path d="M2 5a1.5 1.5 0 0 1 1.5-1.5h2.4L7.5 5h5A1.5 1.5 0 0 1 14 6.5v5A1.5 1.5 0 0 1 12.5 13h-9A1.5 1.5 0 0 1 2 11.5V5z"></path>
    </svg>
  );
}

function IcSave({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <path d="M13 13.5H3a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1h8l3 3v7a1 1 0 0 1-1 1z"></path>
      <path d="M10.5 13.5v-4h-5v4M5 2.5V5h4.5"></path>
    </svg>
  );
}

function IcPower({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <path d="M8 2v5.5"></path>
      <path d="M4.2 4.2a5.2 5.2 0 1 0 7.6 0"></path>
    </svg>
  );
}

function IcKeyboard({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round">
      <rect x="1.5" y="3.5" width="13" height="9" rx="1.5"></rect>
      <path d="M4 6h.9M7.5 6h.9M11 6h.9M4 8.5h.9M7.5 8.5h.9M11 8.5h.9M5 11h6"></path>
    </svg>
  );
}

function IcCorner({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <rect x="2" y="2" width="12" height="12" rx="1.5"></rect>
      <rect x="2" y="2" width="4.5" height="4.5" rx="1" fill="currentColor" stroke="none"></rect>
    </svg>
  );
}

function IcInfo({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3">
      <circle cx="8" cy="8" r="6"></circle>
      <line x1="8" y1="7.4" x2="8" y2="11"></line>
      <circle cx="8" cy="5" r="0.5" fill="currentColor"></circle>
    </svg>
  );
}

/* 青蛙导航 应用图标（四格点阵徽标） */
function IcFrogMark({ size = 26 }) {
  return <img src="../../assets/frog-navigation.png" alt="青蛙导航" width={size} height={size} style={{ objectFit: "contain", borderRadius: "20%" }} />;
}

/* Windows 徽标（开始按钮） */
function IcWindows({ size = 20 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" fill="currentColor">
      <rect x="1.5" y="1.5" width="8" height="8" rx="0.8"></rect>
      <rect x="10.5" y="1.5" width="8" height="8" rx="0.8"></rect>
      <rect x="1.5" y="10.5" width="8" height="8" rx="0.8"></rect>
      <rect x="10.5" y="10.5" width="8" height="8" rx="0.8"></rect>
    </svg>
  );
}

/* 任务视图 */
function IcTaskView({ size = 19 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.2">
      <rect x="2" y="3.5" width="9" height="13" rx="1.2"></rect>
      <rect x="13.5" y="3.5" width="4.5" height="7.5" rx="1" fill="currentColor" stroke="none" opacity="0.55"></rect>
    </svg>
  );
}

/* Edge（近似：圆环 + 波浪） */
function IcEdge({ size = 21 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 22 22" fill="none" stroke="currentColor" strokeWidth="1.5">
      <path d="M19 11a8 8 0 1 0-2.6 5.9"></path>
      <path d="M3 12.5c2.5-3.6 6-4.6 9.2-3.4 2.2.8 3.4 2.3 3.8 4.4"></path>
    </svg>
  );
}

/* 文件资源管理器 */
function IcExplorer({ size = 20 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" fill="currentColor">
      <path d="M2 5.2A1.7 1.7 0 0 1 3.7 3.5h3l1.6 1.6h8A1.7 1.7 0 0 1 18 6.8v7.7a1.7 1.7 0 0 1-1.7 1.7H3.7A1.7 1.7 0 0 1 2 14.5V5.2z" opacity="0.92"></path>
      <path d="M2 8h16v6.5a1.7 1.7 0 0 1-1.7 1.7H3.7A1.7 1.7 0 0 1 2 14.5V8z" opacity="0.55"></path>
    </svg>
  );
}

function IcWifi({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3">
      <path d="M2 6.2a9 9 0 0 1 12 0M4.4 9a5.6 5.6 0 0 1 7.2 0M6.8 11.7a2.4 2.4 0 0 1 2.4 0"></path>
      <circle cx="8" cy="13.4" r="0.7" fill="currentColor" stroke="none"></circle>
    </svg>
  );
}

function IcVolume({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <path d="M2 6v4h2.6L8.5 13V3L4.6 6H2z" fill="currentColor" stroke="none" opacity="0.9"></path>
      <path d="M10.8 5.4a3.7 3.7 0 0 1 0 5.2M12.7 3.6a6.2 6.2 0 0 1 0 8.8"></path>
    </svg>
  );
}

function IcBattery({ size = 20 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 22 12" fill="none" stroke="currentColor" strokeWidth="1">
      <rect x="1" y="1.5" width="16" height="9" rx="2"></rect>
      <rect x="3" y="3.5" width="10" height="5" rx="1" fill="currentColor" stroke="none"></rect>
      <path d="M19 4.5v3a1.6 1.6 0 0 0 0-3z" fill="currentColor" stroke="none"></path>
    </svg>
  );
}

function IcBell({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round">
      <path d="M8 2a4.2 4.2 0 0 0-4.2 4.2V9L2.5 11.5h11L12.2 9V6.2A4.2 4.2 0 0 0 8 2z"></path>
      <path d="M6.6 13a1.5 1.5 0 0 0 2.8 0"></path>
    </svg>
  );
}

Object.assign(window, {
  IcSearch, IcGear, IcPlus, IcClose, IcChevronRight, IcChevronUp,
  IcExternal, IcLink, IcPencil, IcRefresh, IcFolderMove, IcTrash,
  IcCheck, IcFolder, IcSave, IcPower, IcKeyboard, IcCorner, IcInfo,
  IcFrogMark, IcWindows, IcTaskView, IcEdge, IcExplorer,
  IcWifi, IcVolume, IcBattery, IcBell
});
