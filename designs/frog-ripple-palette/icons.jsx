/* 青蛙导航 · 涟漪原型 — 内联 SVG 图标（SF Symbols 风格，细描边圆角线端） */

function IcSearch({ size = 20 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
      <circle cx="7" cy="7" r="4.6"></circle>
      <line x1="10.6" y1="10.6" x2="14" y2="14"></line>
    </svg>
  );
}

function IcCheck({ size = 15 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 8.6l3.3 3.3L13 5"></path>
    </svg>
  );
}

/* 空结果：同心涟漪 */
function IcRipple({ size = 38 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 36 36" fill="none" stroke="currentColor" strokeWidth="1.4">
      <circle cx="18" cy="18" r="3" opacity="0.9"></circle>
      <circle cx="18" cy="18" r="8.5" opacity="0.55"></circle>
      <circle cx="18" cy="18" r="14.5" opacity="0.28"></circle>
    </svg>
  );
}

/* 品牌蛙标 */
function IcFrogMark({ size = 96 }) {
  return <img src="../../assets/frog-navigation.png" alt="青蛙导航" width={size} height={size} style={{ objectFit: "contain", display: "block" }} />;
}

Object.assign(window, {
  IcSearch,
  IcCheck,
  IcRipple,
  IcFrogMark
});
