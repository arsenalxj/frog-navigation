/* 青蛙导航 · 涟漪原型 — 键盘优先的全屏命令面板
 * 概念：蛙鸣入水，涟漪扩散。抛弃图标网格，typography-first。
 * 核心交互：浏览（分栏铺陈） + 搜索（跨书签过滤） + 打开（涟漪 + toast）。
 */

const { useState, useEffect, useRef, useCallback, useMemo } = React;

/* 从 URL 提取展示域名 */
function hostOf(url) {
  try {
    return new URL(url).host.replace(/^www\./, "");
  } catch (e) {
    return url;
  }
}

function App() {
  const data = useMemo(() => frogSeedData(), []);
  const groups = useMemo(() => [...data.groups].sort((a, b) => a.order - b.order), [data]);

  const [query, setQuery] = useState("");
  const [sel, setSel] = useState({ col: 0, row: 0 });
  const [ripples, setRipples] = useState([]);
  const [toast, setToast] = useState(null);
  const [focused, setFocused] = useState(false);

  const inputRef = useRef(null);
  const layerRef = useRef(null);
  const rowRefs = useRef({});
  const rippleSeq = useRef(0);
  const toastTimer = useRef(null);

  /* ===== 分栏数据 =====
   * 无输入：第 1 栏「跃点」= 根目录书签（前 9 个为 1-9 直达池），其余栏 = 各分组；
   *         每栏最多显示 7 条，超出显示「+N」。
   * 有输入：标题 + URL 子串过滤（不区分大小写），空栏隐藏，最多 3 栏，每栏最多 8 条。 */
  const columns = useMemo(() => {
    const q = query.trim().toLowerCase();
    const byOrder = (a, b) => a.order - b.order;
    const match = (b) => !q || (b.title + " " + b.url).toLowerCase().includes(q);

    const cols = [];
    const root = data.bookmarks.filter((b) => b.groupId == null && match(b)).sort(byOrder);
    if (root.length) cols.push({ id: "root", name: "跃点", items: root, total: root.length });
    groups.forEach((g) => {
      const items = data.bookmarks.filter((b) => b.groupId === g.id && match(b)).sort(byOrder);
      if (items.length) cols.push({ id: g.id, name: g.name, items, total: items.length });
    });

    const limited = q ? cols.slice(0, 3) : cols;
    return limited.map((c) => {
      const max = q ? 8 : 7;
      const shown = c.items.slice(0, max);
      return { ...c, shown, extra: c.items.length - shown.length };
    });
  }, [data, groups, query]);

  /* 「跃点」1-9 直达池：根目录前 9 条（与栏内展示条数解耦） */
  const jumpPool = useMemo(() => {
    const root = columns.find((c) => c.id === "root");
    return root ? root.items.slice(0, 9) : [];
  }, [columns]);

  /* 数据变化后收敛选中位置，保证不越界 */
  useEffect(() => {
    setSel((s) => {
      if (!columns.length) return { col: 0, row: 0 };
      const col = Math.min(s.col, columns.length - 1);
      const row = Math.min(s.row, columns[col].shown.length - 1);
      return col === s.col && row === s.row ? s : { col, row };
    });
  }, [columns]);

  /* ===== 涟漪反馈：从指定行位置扩散 3 个同心圆，动画结束移除 ===== */
  const spawnRipple = useCallback((col, row) => {
    const layer = layerRef.current;
    const el = rowRefs.current[col + ":" + row];
    if (!layer || !el) return;
    const lr = layer.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    const id = ++rippleSeq.current;
    setRipples((rs) => [...rs, { id, x: r.left + r.width / 2 - lr.left, y: r.top + r.height / 2 - lr.top }]);
    setTimeout(() => setRipples((rs) => rs.filter((p) => p.id !== id)), 950);
  }, []);

  const moveSel = useCallback((col, row) => {
    setSel({ col, row });
    spawnRipple(col, row);
  }, [spawnRipple]);

  /* ===== Toast：2 秒自动消失 ===== */
  const showToast = useCallback((text) => {
    clearTimeout(toastTimer.current);
    setToast({ id: Date.now(), text });
    toastTimer.current = setTimeout(() => setToast(null), 2000);
  }, []);

  /* 「打开」不真实跳转：涟漪 + toast */
  const openBookmark = useCallback((b, col, row) => {
    spawnRipple(col, row);
    showToast("已打开 " + b.title);
  }, [spawnRipple, showToast]);

  /* ===== 键盘：一等公民 ===== */
  useEffect(() => {
    const onKey = (e) => {
      if (e.isComposing || e.keyCode === 229) return; // 中文输入法合成中不响应
      const inInput = document.activeElement === inputRef.current;
      const k = e.key;

      if (k === "Escape") {
        if (query) {
          e.preventDefault();
          setQuery(""); // 有输入 → 清空；焦点保持在搜索框（若原本聚焦）
        }
        return; // 无输入 → 无操作
      }
      if (!columns.length) return;

      const colLen = (c) => columns[c].shown.length;
      const navRow = (d) => {
        const len = colLen(sel.col);
        if (!len) return;
        moveSel(sel.col, (sel.row + d + len) % len);
      };
      const navCol = (d) => {
        const col = (sel.col + d + columns.length) % columns.length;
        moveSel(col, Math.min(sel.row, colLen(col) - 1));
      };

      if (k === "ArrowDown") { e.preventDefault(); navRow(1); return; }
      if (k === "ArrowUp") { e.preventDefault(); navRow(-1); return; }
      if (k === "ArrowRight") { e.preventDefault(); navCol(1); return; }
      if (k === "ArrowLeft") { e.preventDefault(); navCol(-1); return; }
      if (k === "Tab") { e.preventDefault(); navCol(e.shiftKey ? -1 : 1); return; }

      if (k === "Enter") {
        e.preventDefault();
        const b = columns[sel.col] && columns[sel.col].shown[sel.row];
        if (b) openBookmark(b, sel.col, sel.row);
        return;
      }

      if (inInput) return; // 输入框聚焦时，可打印字符自然进入输入框

      /* 搜索框为空且未聚焦：1-9 直达「跃点」第 N 条 */
      if (!query && /^[1-9]$/.test(k)) {
        const idx = Number(k) - 1;
        const b = jumpPool[idx];
        if (b) {
          e.preventDefault();
          setSel({ col: 0, row: Math.min(idx, columns[0].shown.length - 1) });
          openBookmark(b, 0, Math.min(idx, columns[0].shown.length - 1));
        }
        return;
      }

      /* 任意可打印字符：仅聚焦搜索框，不 preventDefault ——
       * keypress 会自然落入新聚焦的输入框，避免手动追加造成重复输入 */
      if (k.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey && inputRef.current) {
        inputRef.current.focus();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [columns, sel, query, jumpPool, moveSel, openBookmark]);

  /* ===== 渲染 ===== */
  return (
    <div className="stage">
      <div className="hero">
        <div className="frog"><IcFrogMark size={96} /></div>
        <div className={"search " + (focused ? "is-focus" : "is-idle")}>
          <IcSearch size={20} />
          <input
            ref={inputRef}
            value={query}
            placeholder="输入以唤游…"
            spellCheck="false"
            onChange={(e) => setQuery(e.target.value)}
            onFocus={() => setFocused(true)}
            onBlur={() => setFocused(false)}
          />
          {query
            ? <span className="esc-hint"><kbd>Esc</kbd> 清空</span>
            : (!focused && <span className="type-hint">直接输入即可搜索</span>)}
        </div>
      </div>

      <div className="results" ref={layerRef}>
        {columns.length === 0 && (
          <div className="empty">
            <IcRipple size={40} />
            <span>潭面无波，未寻得「{query.trim()}」</span>
          </div>
        )}
        {columns.map((c, ci) => (
          <div className="col" key={c.id}>
            <div className="col-head">
              <span className="col-name">{c.name}</span>
              <span className="col-count">{c.total}</span>
            </div>
            {c.shown.map((b, ri) => {
              const active = ci === sel.col && ri === sel.row;
              return (
                <div
                  key={b.id}
                  ref={(el) => {
                    const kk = ci + ":" + ri;
                    if (el) rowRefs.current[kk] = el;
                    else delete rowRefs.current[kk];
                  }}
                  className={"row" + (active ? " active" : "")}
                  onMouseEnter={() => setSel({ col: ci, row: ri })}
                  onClick={() => { setSel({ col: ci, row: ri }); openBookmark(b, ci, ri); }}
                >
                  <span className="row-icon" style={frogIconStyle(b)}>{frogInitial(b.title)}</span>
                  <span className="row-text">
                    <span className="row-title">{b.title}</span>
                    <span className="row-host">{hostOf(b.url)}</span>
                  </span>
                  {!query && c.id === "root" && ri < 9 && <kbd className="row-key">{ri + 1}</kbd>}
                </div>
              );
            })}
            {c.extra > 0 && <div className="more">+{c.extra}</div>}
          </div>
        ))}

        <svg className="ripple-layer">
          {ripples.map((p) => (
            <g key={p.id}>
              {[0, 1, 2].map((i) => (
                <circle
                  key={i}
                  className="ring"
                  cx={p.x}
                  cy={p.y}
                  r={120}
                  style={{ animationDelay: (i * 0.12) + "s" }}
                />
              ))}
            </g>
          ))}
        </svg>
      </div>

      <footer className="hints">
        <span><kbd>↑</kbd><kbd>↓</kbd> 选择</span><i>·</i>
        <span><kbd>←</kbd><kbd>→</kbd>/<kbd>Tab</kbd> 换栏</span><i>·</i>
        <span><kbd>1-9</kbd> 直达</span><i>·</i>
        <span><kbd>Enter</kbd> 打开</span><i>·</i>
        <span><kbd>Esc</kbd> 清空</span>
      </footer>

      {toast && (
        <div className="toast" key={toast.id}>
          <IcCheck size={15} />
          <span>{toast.text}</span>
        </div>
      )}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
