/* 青蛙导航 Launchpad 原型 — 内联 SVG 图标（SF Symbols 风格，细描边圆角线端） */

function IcSearch({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
      <circle cx="7" cy="7" r="4.6"></circle>
      <line x1="10.6" y1="10.6" x2="14" y2="14"></line>
    </svg>
  );
}

function IcGear({ size = 18 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 18 18" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="9" cy="9" r="2.4"></circle>
      <path d="M9 1.8v1.7M9 14.5v1.7M1.8 9h1.7M14.5 9h1.7M3.9 3.9l1.2 1.2M12.9 12.9l1.2 1.2M14.1 3.9l-1.2 1.2M5.1 12.9l-1.2 1.2"></path>
    </svg>
  );
}

function IcPlus({ size = 26 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
      <line x1="12" y1="5.5" x2="12" y2="18.5"></line>
      <line x1="5.5" y1="12" x2="18.5" y2="12"></line>
    </svg>
  );
}

function IcClose({ size = 11 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <line x1="2" y1="2" x2="10" y2="10"></line>
      <line x1="10" y1="2" x2="2" y2="10"></line>
    </svg>
  );
}

function IcChevronRight({ size = 12 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="4.5 2.5 8 6 4.5 9.5"></polyline>
    </svg>
  );
}

function IcExternal({ size = 13 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M8 2h4v4"></path>
      <path d="M12 2 6.5 7.5"></path>
      <path d="M9.5 8.5V11a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V5.5a1 1 0 0 1 1-1h2.5"></path>
    </svg>
  );
}

function IcLink({ size = 13 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M5.8 8.2a3 3 0 0 0 4.2 0l2-2a3 3 0 1 0-4.2-4.2l-1 1"></path>
      <path d="M8.2 5.8a3 3 0 0 0-4.2 0l-2 2a3 3 0 1 0 4.2 4.2l1-1"></path>
    </svg>
  );
}

function IcPencil({ size = 13 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M9.8 2.4a1.5 1.5 0 0 1 2.1 2.1L4.5 12H2.3V9.8l7.5-7.4z"></path>
    </svg>
  );
}

function IcRefresh({ size = 13 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 7A5 5 0 1 1 7 2c1.9 0 3.5 1 4.4 2.6"></path>
      <polyline points="12 1.5 12 4.8 8.8 4.8"></polyline>
    </svg>
  );
}

function IcFolderMove({ size = 13 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h2L7 4.5h4.5A1.5 1.5 0 0 1 13 6v4.5a1.5 1.5 0 0 1-1.5 1.5h-8A1.5 1.5 0 0 1 2 10.5v-6z"></path>
      <path d="M7 7v3.4M5.6 8.8 7 7.4l1.4 1.4"></path>
    </svg>
  );
}

function IcTrash({ size = 13 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M1.8 3.6h10.4M5.5 3.4V2.3a.8.8 0 0 1 .8-.8h1.4a.8.8 0 0 1 .8.8v1.1M3.4 3.8l.6 7.4a1 1 0 0 0 1 .9h4a1 1 0 0 0 1-.9l.6-7.4"></path>
    </svg>
  );
}

function IcCheck({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="3 8.5 6.5 12 13 4.5"></polyline>
    </svg>
  );
}

function IcFolder({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M2 5a1.5 1.5 0 0 1 1.5-1.5h2.4L7.5 5h5A1.5 1.5 0 0 1 14 6.5v5A1.5 1.5 0 0 1 12.5 13h-9A1.5 1.5 0 0 1 2 11.5V5z"></path>
    </svg>
  );
}

function IcSave({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M13 13.5H3a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1h8l3 3v7a1 1 0 0 1-1 1z"></path>
      <path d="M10.5 13.5v-4h-5v4M5 2.5V5h4.5"></path>
    </svg>
  );
}

function IcRestore({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M2.5 6.5A5.5 5.5 0 1 1 2.2 10"></path>
      <polyline points="2.5 3 2.5 6.8 6.3 6.8"></polyline>
    </svg>
  );
}

function IcPower({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M8 2v5.5"></path>
      <path d="M4.2 4.2a5.2 5.2 0 1 0 7.6 0"></path>
    </svg>
  );
}

function IcInfo({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="8" cy="8" r="6"></circle>
      <line x1="8" y1="7.4" x2="8" y2="11"></line>
      <circle cx="8" cy="5" r="0.4" fill="currentColor"></circle>
    </svg>
  );
}

/* Dock 内 青蛙导航 应用图标（网格点阵） */
function IcFrogMark({ size = 30 }) {
  return <img src="../../assets/frog-navigation.png" alt="青蛙导航" width={size} height={size} style={{ objectFit: "contain", borderRadius: "20%" }} />;
}

function IcSafari({ size = 28 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
      <circle cx="12" cy="12" r="8.5"></circle>
      <polygon points="15.5,8.5 10.5,10.5 8.5,15.5 13.5,13.5" fill="currentColor" stroke="none"></polygon>
    </svg>
  );
}

function IcWifi({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
      <path d="M2 6.2a9 9 0 0 1 12 0M4.4 9a5.6 5.6 0 0 1 7.2 0M6.8 11.7a2.4 2.4 0 0 1 2.4 0"></path>
      <circle cx="8" cy="13.4" r="0.7" fill="currentColor" stroke="none"></circle>
    </svg>
  );
}

function IcBattery({ size = 20 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 22 12" fill="none" stroke="currentColor" strokeWidth="1">
      <rect x="1" y="1.5" width="16" height="9" rx="2.5"></rect>
      <rect x="3" y="3.5" width="10" height="5" rx="1.2" fill="currentColor" stroke="none"></rect>
      <path d="M19 4.5v3a1.6 1.6 0 0 0 0-3z" fill="currentColor" stroke="none"></path>
    </svg>
  );
}

Object.assign(window, {
  IcSearch, IcGear, IcPlus, IcClose, IcChevronRight,
  IcExternal, IcLink, IcPencil, IcRefresh, IcFolderMove, IcTrash,
  IcCheck, IcFolder, IcSave, IcRestore, IcPower, IcInfo,
  IcFrogMark, IcSafari, IcWifi, IcBattery
});
