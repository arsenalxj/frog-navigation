/* 青蛙导航 · 蛙眼轮盘原型 — 内联 SVG 图标 */

function IcSearch({ size = 16 }) {
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

/* 品牌蛙标 */
function IcFrogMark({ size = 28 }) {
  return <img src="../../assets/frog-navigation.png" alt="青蛙导航" width={size} height={size} style={{ objectFit: "contain", display: "block" }} />;
}

Object.assign(window, {
  IcSearch,
  IcCheck,
  IcFrogMark
});
