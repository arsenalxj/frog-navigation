/* 青蛙导航 · 蛙眼轮盘原型 — 键盘优先的雷达表盘
 * 概念：一圈雷达盘。书签沿外环排布，分组是内环弧段，中心蛙眼盯着当前选中项。
 * 交互：←→ 旋转 · ↑↓ 换组 · 1-6 直达 · 输入过滤 · Enter 打开（脉冲 + toast） · Esc 清空。
 */

const { useState, useEffect, useRef, useCallback, useMemo } = React;

/* ===== 几何常量（viewBox 0 0 720 720） ===== */
const CX = 360;
const R_TICK = 338;
const R_ITEM = 266;
const R_LABEL = 312;
const R_GROUP = 172;
const R_GROUP_IN = 156;
const R_GROUP_OUT = 182;
const R_GROUP_LABEL = 150;
const MAX_ITEMS = 13;

const rad = (deg) => (deg * Math.PI) / 180;

function polar(r, deg) {
  return { x: CX + r * Math.cos(rad(deg)), y: CX + r * Math.sin(rad(deg)) };
}

function hostOf(url) {
  try {
    return new URL(url).host.replace(/^www\./, "");
  } catch (e) {
    return url;
  }
}

/* 标签截断到 8 个字符（按字形切分） */
function clipLabel(title) {
  const chars = Array.from(title || "");
  return (chars.length > 8 ? chars.slice(0, 8).join("") : title).trim();
}

/* 切线方向标签：左半圈先补 180°，再归一到 (-90°, 90°]。
 * 归一化保证任何位置字形顶边都朝屏幕上方，不会倒置。 */
function tangentRotation(angle) {
  const deg = ((angle % 360) + 360) % 360;
  let rot = angle + 90;
  if (deg >= 90 && deg <= 270) rot += 180;
  rot = ((rot % 360) + 360) % 360;
  if (rot > 90 && rot <= 270) rot -= 180;
  else if (rot > 270) rot -= 360;
  return rot;
}

function arcPath(r, a0, a1) {
  const p0 = polar(r, a0);
  const p1 = polar(r, a1);
  const large = Math.abs(a1 - a0) > 180 ? 1 : 0;
  return `M${p0.x.toFixed(2)} ${p0.y.toFixed(2)} A${r} ${r} 0 ${large} 1 ${p1.x.toFixed(2)} ${p1.y.toFixed(2)}`;
}

/* 环形扇区（带缺口的弧段） */
function sectorPath(rIn, rOut, a0, a1) {
  const po0 = polar(rOut, a0);
  const po1 = polar(rOut, a1);
  const pi1 = polar(rIn, a1);
  const pi0 = polar(rIn, a0);
  const large = a1 - a0 > 180 ? 1 : 0;
  return [
    `M${po0.x.toFixed(2)} ${po0.y.toFixed(2)}`,
    `A${rOut} ${rOut} 0 ${large} 1 ${po1.x.toFixed(2)} ${po1.y.toFixed(2)}`,
    `L${pi1.x.toFixed(2)} ${pi1.y.toFixed(2)}`,
    `A${rIn} ${rIn} 0 ${large} 0 ${pi0.x.toFixed(2)} ${pi0.y.toFixed(2)}`,
    "Z"
  ].join(" ");
}

/* 72 根刻度，每 6 根加长 */
const TICKS = Array.from({ length: 72 }, (_, i) => {
  const angle = i * 5 - 90;
  const major = i % 6 === 0;
  const p1 = polar(major ? R_TICK - 8 : R_TICK - 4.5, angle);
  const p2 = polar(major ? R_TICK + 8 : R_TICK + 4.5, angle);
  return { id: i, major, x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y };
});

/* 让选中弧走最短路径旋转，避免绕远 */
function useDialRotation(target) {
  const [rot, setRot] = useState(0);
  const rotRef = useRef(0);
  useEffect(() => {
    const current = rotRef.current;
    const delta = (((target - current) % 360) + 540) % 360 - 180;
    if (Math.abs(delta) < 0.01) return;
    const next = current + delta;
    rotRef.current = next;
    setRot(next);
  }, [target]);
  return rot;
}

function App() {
  const data = useMemo(() => frogSeedData(), []);
  const groups = useMemo(
    () => [...data.groups].sort((a, b) => a.order - b.order),
    [data]
  );

  /* 泳道：全部（根目录） + 各分组，顺序与分组 order 一致 */
  const lanes = useMemo(() => {
    const byOrder = (a, b) => a.order - b.order;
    const root = data.bookmarks.filter((b) => b.groupId === null).sort(byOrder);
    return [
      { id: "all", name: "全部", items: root },
      ...groups.map((g) => ({
        id: g.id,
        name: g.name,
        items: data.bookmarks.filter((b) => b.groupId === g.id).sort(byOrder)
      }))
    ];
  }, [data, groups]);

  /* 全库（搜索用）：按创建时间排序，保证结果顺序稳定 */
  const allBookmarks = useMemo(
    () => [...data.bookmarks].sort((a, b) => a.createdAt - b.createdAt),
    [data]
  );

  const [laneId, setLaneId] = useState("all");
  const [index, setIndex] = useState(0);
  const [query, setQuery] = useState("");
  const [focused, setFocused] = useState(false);
  const [toast, setToast] = useState(null);
  const [pulses, setPulses] = useState([]);
  const [hoverLane, setHoverLane] = useState(null);

  const inputRef = useRef(null);
  const toastTimer = useRef(null);
  const pulseSeq = useRef(0);
  const pulseTimers = useRef([]);
  const searchOrigin = useRef(null);

  const laneIdx = Math.max(0, lanes.findIndex((l) => l.id === laneId));
  const lane = lanes[laneIdx] || lanes[0];

  const searching = query.trim().length > 0;

  /* 无搜索：当前泳道；搜索：全库（标题 + 域名），最多展示 13 个 */
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return lane.items;
    return allBookmarks.filter(
      (b) =>
        b.title.toLowerCase().includes(q) ||
        hostOf(b.url).toLowerCase().includes(q)
    );
  }, [allBookmarks, lane, query]);

  const shown = filtered.slice(0, MAX_ITEMS);
  const extra = filtered.length - shown.length;

  /* 索引越界收敛 */
  useEffect(() => {
    if (index >= shown.length) setIndex(0);
  }, [shown.length, index]);

  const count = shown.length;
  const safeIndex = count ? Math.min(index, count - 1) : 0;
  const selected = count ? shown[safeIndex] : null;
  const step = count ? 360 / count : 0;
  const selectedAngle = count ? -90 + safeIndex * step : null;
  const targetRot = count ? safeIndex * step : 0;
  const rot = useDialRotation(targetRot);

  const pupilX = selectedAngle === null ? 0 : 12 * Math.cos(rad(selectedAngle));
  const pupilY = selectedAngle === null ? 0 : 12 * Math.sin(rad(selectedAngle));

  /* ===== toast（2 秒） ===== */
  const showToast = useCallback((title) => {
    setToast({ id: Date.now(), title });
    clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast(null), 2000);
  }, []);

  useEffect(() => {
    return () => {
      clearTimeout(toastTimer.current);
      pulseTimers.current.forEach((t) => clearTimeout(t));
    };
  }, []);

  /* ===== 打开：选中节点脉冲 + toast，不跳转 ===== */
  const openBookmark = useCallback(
    (b, i, n) => {
      if (!b) return;
      const angle = -90 + (i * 360) / Math.max(1, n);
      const p = polar(R_ITEM, angle);
      const id = ++pulseSeq.current;
      setPulses((list) => [...list, { id, x: p.x, y: p.y }]);
      const timer = setTimeout(() => {
        setPulses((list) => list.filter((item) => item.id !== id));
      }, 700);
      pulseTimers.current.push(timer);
      showToast(b.title);
    },
    [showToast]
  );

  const goLaneId = useCallback(
    (id) => {
      setLaneId(id);
      setIndex(0);
      setQuery("");
      setHoverLane(null);
      searchOrigin.current = null;
    },
    []
  );

  const goLaneAt = useCallback(
    (n) => {
      if (!lanes[n]) return;
      goLaneId(lanes[n].id);
    },
    [lanes, goLaneId]
  );

  /* 退出搜索：清空并回到进入搜索前的泳道与选中项 */
  const exitSearch = useCallback(() => {
    const origin = searchOrigin.current;
    setQuery("");
    if (origin) {
      setLaneId(origin.laneId);
      setIndex(origin.index);
      searchOrigin.current = null;
    } else {
      setIndex(0);
    }
    if (inputRef.current) inputRef.current.blur();
  }, []);

  /* 输入变化：首次进入搜索时记录落点；删空时同样恢复 */
  const handleQueryChange = (e) => {
    const next = e.target.value;
    const willSearch = next.trim().length > 0;

    if (willSearch && !searching) {
      searchOrigin.current = { laneId, index: safeIndex };
      setHoverLane(null);
    }

    if (!willSearch && searching) {
      const origin = searchOrigin.current;
      if (origin) {
        setLaneId(origin.laneId);
        setIndex(origin.index);
        searchOrigin.current = null;
      } else {
        setIndex(0);
      }
    } else {
      setIndex(0);
    }

    setQuery(next);
  };

  /* ===== 键盘：一等公民 ===== */
  useEffect(() => {
    const onKey = (e) => {
      if (e.isComposing || e.keyCode === 229) return;

      const k = e.key;
      const inInput =
        e.target && (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA");
      const searching = query.trim().length > 0;

      const rotate = (d) => {
        if (!shown.length) return;
        setIndex((i) => {
          const cur = Math.min(i, shown.length - 1);
          return (cur + d + shown.length) % shown.length;
        });
      };

      const laneStep = (d) => {
        const n = lanes.length;
        const next = ((laneIdx + d) % n + n) % n;
        goLaneId(lanes[next].id);
      };

      if (k === "ArrowLeft" || (!inInput && (k === "h" || k === "H"))) {
        e.preventDefault();
        rotate(-1);
        return;
      }
      if (k === "ArrowRight" || (!inInput && (k === "l" || k === "L"))) {
        e.preventDefault();
        rotate(1);
        return;
      }
      if (k === "ArrowUp" || (!inInput && (k === "k" || k === "K"))) {
        e.preventDefault();
        if (searching) rotate(-1);
        else laneStep(-1);
        return;
      }
      if (k === "ArrowDown" || (!inInput && (k === "j" || k === "J"))) {
        e.preventDefault();
        if (searching) rotate(1);
        else laneStep(1);
        return;
      }

      if (k === "Enter") {
        e.preventDefault();
        if (selected) openBookmark(selected, safeIndex, shown.length);
        return;
      }

      if (k === "Escape") {
        e.preventDefault();
        if (searching) exitSearch();
        else if (inputRef.current) inputRef.current.blur();
        return;
      }

      /* 1-6 直达泳道；输入框聚焦时数字作为文本输入 */
      if (!inInput && /^[1-6]$/.test(k)) {
        e.preventDefault();
        goLaneAt(Number(k) - 1);
        return;
      }

      /* 任意可打印字符：聚焦搜索框；不 preventDefault，让键击自然落入输入框 */
      if (
        !inInput &&
        k.length === 1 &&
        !e.ctrlKey &&
        !e.metaKey &&
        !e.altKey &&
        inputRef.current
      ) {
        inputRef.current.focus();
      }
    };

    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [shown, lanes, laneIdx, query, selected, safeIndex, goLaneId, goLaneAt, openBookmark, exitSearch]);

  /* ===== 渲染 ===== */
  const segments = lanes.map((l, i) => {
    const center = -90 + i * 60;
    return { lane: l, center, a0: center - 24, a1: center + 24 };
  });

  return (
    <div className="stage">
      {/* 左上品牌 */}
      <div className="brand">
        <div className="frog">
          <IcFrogMark size={28} />
        </div>
        <div className="brand-text">
          <span className="brand-name">青蛙导航</span>
          <span className="brand-sub">Radial Dial</span>
        </div>
      </div>

      {/* 右上当前泳道 + 数量 */}
      <div className="lane-pill">
        <span className="dot"></span>
        <span className="lp-name">{searching ? "搜索" : lane.name}</span>
        <span className="lp-count">{filtered.length}</span>
      </div>

      {/* 中心表盘 */}
      <div className="dial-wrap">
        <svg className="dial" viewBox="0 0 720 720" aria-label="青蛙导航轮盘">
          <defs>
            <radialGradient id="irisGrad" cx="36%" cy="30%" r="82%">
              <stop offset="0%" stopColor="#C4E5A8" />
              <stop offset="52%" stopColor="#A8D08A" />
              <stop offset="100%" stopColor="#7FB35A" />
            </radialGradient>
            <radialGradient id="coreGlow" cx="50%" cy="50%" r="50%">
              <stop offset="0%" stopColor="#A8D08A" stopOpacity="0.1" />
              <stop offset="100%" stopColor="#A8D08A" stopOpacity="0" />
            </radialGradient>
            <linearGradient
              id="guideFade"
              gradientUnits="userSpaceOnUse"
              x1="360"
              y1="274"
              x2="360"
              y2="114"
            >
              <stop offset="0%" stopColor="#A8D08A" stopOpacity="0" />
              <stop offset="62%" stopColor="#A8D08A" stopOpacity="0.34" />
              <stop offset="100%" stopColor="#A8D08A" stopOpacity="0.8" />
            </linearGradient>
            <filter id="glowSoft" x="-80%" y="-80%" width="260%" height="260%">
              <feGaussianBlur stdDeviation="3.2" result="b" />
              <feMerge>
                <feMergeNode in="b" />
                <feMergeNode in="SourceGraphic" />
              </feMerge>
            </filter>
          </defs>

          <circle cx={CX} cy={CX} r="150" fill="url(#coreGlow)" />

          {/* 刻度环 */}
          {TICKS.map((t) => (
            <line
              key={t.id}
              className={"tick " + (t.major ? "major" : "minor")}
              x1={t.x1}
              y1={t.y1}
              x2={t.x2}
              y2={t.y2}
              strokeWidth={t.major ? 1.6 : 1}
            />
          ))}

          {/* 轨道淡线 */}
          <circle className="orbit" cx={CX} cy={CX} r={R_ITEM} />

          {/* 选中弧 + 引导线（随选中项旋转；压在分组环之下，避免切断弧上文字） */}
          {selected && (
            <g
              className="dial-rotator"
              style={{ transform: `rotate(${rot.toFixed(2)}deg)` }}
            >
              <path className="sel-arc" d={arcPath(R_TICK, -102, -78)} />
              <line
                className="guide"
                x1={CX}
                y1={CX - 86}
                x2={CX}
                y2={CX - 246}
              />
            </g>
          )}

          {/* 分组弧段 */}
          {segments.map((s) => {
            const active = !searching && s.lane.id === lane.id;
            const hover = !searching && s.lane.id === hoverLane;
            return (
              <g key={s.lane.id}>
                <path
                  className={"group-seg" + (searching ? " is-muted" : "")}
                  d={sectorPath(R_GROUP_IN, R_GROUP_OUT, s.a0, s.a1)}
                  fill={
                    active
                      ? "rgba(168,208,138,0.1)"
                      : hover
                      ? "rgba(168,208,138,0.08)"
                      : "rgba(250,245,228,0.022)"
                  }
                  stroke={
                    active
                      ? "rgba(168,208,138,0.78)"
                      : hover
                      ? "rgba(168,208,138,0.42)"
                      : "rgba(168,208,138,0.18)"
                  }
                  strokeWidth={active ? 1.5 : 1}
                  onMouseEnter={() => {
                    if (!searching) setHoverLane(s.lane.id);
                  }}
                  onMouseLeave={() => setHoverLane(null)}
                  onClick={() => {
                    if (!searching) goLaneId(s.lane.id);
                  }}
                />
                {(() => {
                  const p = polar(R_GROUP_LABEL, s.center);
                  const rot2 = tangentRotation(s.center);
                  return (
                    <text
                      className={
                        "group-label" +
                        (active ? " is-active" : hover ? " is-hover" : "") +
                        (searching ? " is-muted" : "")
                      }
                      x={p.x}
                      y={p.y}
                      transform={`rotate(${rot2.toFixed(2)} ${p.x} ${p.y})`}
                      textAnchor="middle"
                      dominantBaseline="central"
                    >
                      {s.lane.name}
                    </text>
                  );
                })()}
              </g>
            );
          })}

          {/* 中心蛙眼 */}
          <g>
            <circle
              cx={CX}
              cy={CX}
              r="82"
              fill="rgba(9,16,11,0.5)"
              stroke="rgba(168,208,138,0.16)"
              strokeWidth="1.2"
            />
            <circle
              cx={CX}
              cy={CX}
              r="68"
              fill="none"
              stroke="rgba(168,208,138,0.07)"
              strokeWidth="1"
            />
            <g className="eye-blink">
              <circle cx={CX} cy={CX} r="54" fill="url(#irisGrad)" />
              <circle
                cx={CX}
                cy={CX}
                r="54"
                fill="none"
                stroke="rgba(62,70,52,0.55)"
                strokeWidth="1.4"
              />
              <g
                className="pupil"
                style={{
                  transform: `translate(${pupilX.toFixed(2)}px, ${pupilY.toFixed(2)}px)`
                }}
              >
                <circle cx={CX} cy={CX} r="22" fill="#0B120D" />
                <circle
                  cx={CX}
                  cy={CX}
                  r="22"
                  fill="none"
                  stroke="rgba(0,0,0,0.5)"
                  strokeWidth="1"
                />
              </g>
              <circle
                cx={CX - 24}
                cy={CX - 25}
                r="6"
                fill="rgba(250,245,228,0.34)"
              />
              <circle
                cx={CX - 11}
                cy={CX - 33}
                r="2.4"
                fill="rgba(250,245,228,0.4)"
              />
            </g>
          </g>

          {/* 条目环：节点 + 切线标签（按泳道重排时淡入旋转） */}
          <g className="lane-layer" key={lane.id}>
            {shown.map((b, i) => {
              const angle = -90 + (i * 360) / Math.max(1, count);
              const p = polar(R_ITEM, angle);
              const active = i === safeIndex;
              const hue = b.hue == null ? 160 : b.hue;
              return (
                <g
                  key={b.id}
                  className="node-item"
                  style={{ transform: `translate(${p.x.toFixed(2)}px, ${p.y.toFixed(2)}px)` }}
                  onMouseEnter={() => setIndex(i)}
                  onClick={() => {
                    setIndex(i);
                    openBookmark(b, i, count);
                  }}
                >
                  <circle
                    className="node-dot"
                    r={active ? 20 : 17}
                    fill={
                      active
                        ? "#A8D08A"
                        : `hsla(${hue}, 26%, 28%, 0.92)`
                    }
                    stroke={
                      active
                        ? "rgba(250,245,228,0.58)"
                        : "rgba(168,208,138,0.26)"
                    }
                    strokeWidth="1.2"
                  />
                  <text
                    className={"node-letter" + (active ? " is-active" : "")}
                    textAnchor="middle"
                    dominantBaseline="central"
                  >
                    {frogInitial(b.title)}
                  </text>
                </g>
              );
            })}

            {shown.map((b, i) => {
              const angle = -90 + (i * 360) / Math.max(1, count);
              const p = polar(R_LABEL, angle);
              const lr = tangentRotation(angle);
              const active = i === safeIndex;
              return (
                <text
                  key={"label-" + b.id}
                  className={"node-label" + (active ? " is-active" : "")}
                  x={p.x}
                  y={p.y}
                  transform={`rotate(${lr.toFixed(2)} ${p.x} ${p.y})`}
                  textAnchor="middle"
                  dominantBaseline="central"
                >
                  {clipLabel(b.title)}
                </text>
              );
            })}
          </g>

          {!shown.length && (
            <text
              className="empty-copy"
              x={CX}
              y={CX + 122}
              textAnchor="middle"
            >
              未寻得匹配项
            </text>
          )}

          {/* 打开脉冲 */}
          {pulses.map((p) => (
            <circle
              key={p.id}
              className="pulse"
              cx={p.x}
              cy={p.y}
              r="22"
            />
          ))}
        </svg>

        {extra > 0 && <div className="overflow-badge">+{extra}</div>}
      </div>

      {/* 搜索条 */}
      <div className="dock">
        <div className={"search" + (focused ? " is-focus" : "")}>
          <IcSearch size={16} />
          <input
            ref={inputRef}
            value={query}
            placeholder="输入搜索…"
            spellCheck="false"
            autoComplete="off"
            aria-label="搜索书签"
            onChange={handleQueryChange}
            onFocus={() => setFocused(true)}
            onBlur={() => setFocused(false)}
          />
          {query && <span className="esc">Esc 清空</span>}
        </div>
      </div>

      {/* 页脚键位提示 */}
      <div className="hints">
        <span>
          <kbd>←</kbd>
          <kbd>→</kbd> 旋转
        </span>
        <i>·</i>
        <span>
          <kbd>↑</kbd>
          <kbd>↓</kbd> 换组
        </span>
        <i>·</i>
        <span>
          <kbd>1</kbd>-<kbd>6</kbd> 直达
        </span>
        <i>·</i>
        <span>输入搜索</span>
        <i>·</i>
        <span>
          <kbd>Enter</kbd> 打开
        </span>
        <i>·</i>
        <span>
          <kbd>Esc</kbd> 清空
        </span>
      </div>

      {/* Toast */}
      {toast && (
        <div className="toast" key={toast.id}>
          <IcCheck size={14} />
          <span>
            已打开 <em>{toast.title}</em>
          </span>
        </div>
      )}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
