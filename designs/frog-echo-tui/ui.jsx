/* 青蛙导航 · 回声终端 — SVG 原子组件与命令行外壳
 * 无弹窗：命令行走提示流，输出进日志 / 缓冲区。
 */

function T({ x, y, children, size = TYPE.body, fill = COLOR.ink, weight = 400, anchor = "start",
           spacing = 0, opacity = 1, sans = false, style, baseline = "central" }) {
  return (
    <text x={x} y={y} fontSize={size} fill={fill} fontWeight={weight} textAnchor={anchor}
          letterSpacing={spacing} opacity={opacity} dominantBaseline={baseline}
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

function R({ x, y, w, h, fill = "none", stroke = "none", sw = 1, rx = 0, opacity = 1, dash, className, onClick, onMouseEnter, onContextMenu, style }) {
  return (
    <rect x={x} y={y} width={w} height={h} fill={fill} stroke={stroke} strokeWidth={sw}
          rx={rx} opacity={opacity} className={className} onClick={onClick}
          onMouseEnter={onMouseEnter} onContextMenu={onContextMenu} style={style}
          strokeDasharray={dash} />
  );
}

function L({ x1, y1, x2, y2, stroke = COLOR.line, sw = 1, dash, opacity = 1 }) {
  return <line x1={x1} y1={y1} x2={x2} y2={y2} stroke={stroke} strokeWidth={sw}
               strokeDasharray={dash} opacity={opacity} />;
}

function Caret({ x, y, h = 16, w = 7, color = COLOR.amber }) {
  return <rect className="frog-caret" x={x} y={y - h / 2} width={w} height={h} fill={color} />;
}

function Kbd({ x, y, label, size = TYPE.sm, dark = false }) {
  const w = Math.max(24, textW(label, size) + 12);
  const h = 22;
  return (
    <g>
      <R x={x} y={y - h / 2} w={w} h={h} rx={2}
         fill={dark ? "none" : COLOR.surface}
         stroke={dark ? "rgba(255,254,248,0.35)" : COLOR.line} sw={1} />
      <T x={x + w / 2} y={y + 0.5} size={size} anchor="middle"
         fill={dark ? COLOR.paper : COLOR.ink2}>{label}</T>
    </g>
  );
}

function Btn({ x, y, w = 88, h = 28, label, kind = "default", onClick, disabled = false }) {
  const fill = kind === "primary" ? COLOR.green : kind === "danger" ? COLOR.red : "none";
  const fg = kind === "default" ? COLOR.ink : COLOR.paper;
  const stroke = kind === "default" ? COLOR.ink : fill;
  return (
    <g opacity={disabled ? 0.38 : 1} onClick={disabled ? undefined : onClick}
       style={{ cursor: disabled ? "default" : "pointer" }}>
      <R x={x} y={y} w={w} h={h} fill={fill} stroke={stroke} sw={1} />
      <T x={x + w / 2} y={y + h / 2 + 0.5} size={13} weight={600} anchor="middle" fill={fg}>{label}</T>
    </g>
  );
}

function Tag({ x, y, label, fill = COLOR.yellow, fg = COLOR.ink, size = TYPE.sm, px = 6 }) {
  const w = textW(label, size) + px * 2;
  return (
    <g>
      <R x={x} y={y - 9} w={w} h={18} fill={fill} />
      <T x={x + w / 2} y={y + 0.5} size={size} weight={700} anchor="middle" fill={fg}>{label}</T>
    </g>
  );
}

function IconTile({ x, y, id, title, size = 20 }) {
  const color = frogTileColor(id);
  return (
    <g>
      <R x={x} y={y - size / 2} w={size} h={size} rx={3} fill={color} />
      <T x={x + size / 2} y={y + 0.5} size={size * 0.55} weight={700} anchor="middle"
         fill={COLOR.paper}>{frogInitial(title)}</T>
    </g>
  );
}

/* ================= 窗口外壳 ================= */

function CommandChrome({ s, act }) {
  const { x, y, w } = LAYOUT.cmd;
  const p = s.prompt;
  const input = s.input;
  let promptChar = "›", promptColor = COLOR.green, label = null, value = "", caret = true, right = null;

  if (p) {
    promptChar = ":";
    promptColor = COLOR.amber;
    const total = p.cmd === "add" ? 4 : p.cmd === "edit" ? 2 : p.cmd === "move" ? 2 : 0;
    label = `${p.cmd}${total ? ` ${p.step + 1}/${total}` : ""} › ${p.label}`;
    value = p.value;
    right = p.error
      ? { text: p.error, kind: "error" }
      : { text: p.hint || "", kind: "info" };
  } else if (input) {
    promptChar = input.kind === "search" ? "/" : ":";
    promptColor = input.kind === "search" ? COLOR.teal : COLOR.amber;
    value = input.value;
    right = {
      text: input.kind === "search" ? "Enter 打开 · Esc 清空" : "Tab 补全 · ↑↓ 历史 · Esc 取消",
      kind: "info",
    };
  } else if (s.buffer === "calc") {
    promptChar = "=";
    promptColor = COLOR.green;
    label = "calc › 算式";
    value = s.calc.expr;
    right = s.calc.copied
      ? { text: s.calc.copied, kind: s.calc.copied.startsWith("✓") ? "ok" : "error" }
      : { text: "Enter 计算 · ↑↓ 历史 · c 复制 · Esc 关闭", kind: "info" };
  }
  const placeholder = !p && !input && s.buffer !== "calc"
    ? s.buffer === "settings" ? ": 输入命令 · :help 查看帮助" : ": 打开命令 · / 搜索 · ? 帮助"
    : null;
  const inputX = x + LAYOUT.margin + 18 + (label ? textW(label, 13) + 12 : 0);
  const calcMode = !p && !input && s.buffer === "calc";
  const selStart = calcMode ? Math.min(s.calc.caret ?? value.length, value.length) : value.length;
  const selEnd = calcMode
    ? Math.min(Math.max(selStart, s.calc.selectionEnd ?? selStart), value.length)
    : selStart;

  return (
    <g onClick={() => act.focusInput()} style={{ cursor: "text" }}>
      {/* 整条命令行都是回焦命中区，点标签或提示文字也不会丢失输入焦点。 */}
      <R x={x} y={y} w={w} h={LAYOUT.cmd.h} fill="transparent" />
      {p && <R x={x} y={y} w={w} h={LAYOUT.cmd.h} fill={COLOR.surface} opacity={0.7} />}
      {p && <R x={x} y={y} w={3} h={LAYOUT.cmd.h} fill={COLOR.yellow} />}
      <L x1={x} y1={y} x2={x + w} y2={y} stroke={COLOR.line} />
      <T x={x + LAYOUT.margin} y={y + 21} size={17} weight={700} fill={promptColor}>{promptChar}</T>
      {label && <T x={x + LAYOUT.margin + 18} y={y + 21} size={13} fill={COLOR.muted}>{label}</T>}
      <g>
        {selEnd > selStart && (
          <R x={inputX + textW(value.slice(0, selStart), 15.5)} y={y + 10}
             w={Math.max(1, textW(value.slice(selStart, selEnd), 15.5))} h={22}
             fill={COLOR.yellow} opacity={0.4} />
        )}
        <T x={inputX} y={y + 21} size={15.5} fill={COLOR.ink}
           style={calcMode ? { fontVariantNumeric: "tabular-nums" } : undefined}>{value}</T>
        {caret && <Caret x={inputX + textW(value.slice(0, selStart), 15.5)} y={y + 21} h={18}
                         w={calcMode ? textW("0", 15.5) : 7} />}
        {placeholder && (
          <T x={inputX + 16} y={y + 21} size={14} fill={COLOR.muted} opacity={0.8}>{placeholder}</T>
        )}
      </g>
      {right && (
        <T x={x + w - LAYOUT.margin} y={y + 21} size={12} anchor="end"
           fill={right.kind === "error" ? COLOR.red : right.kind === "ok" ? COLOR.green : COLOR.muted}>{right.text}</T>
      )}
    </g>
  );
}

function StatusChrome({ s, ctx }) {
  const { x, y, w, h } = LAYOUT.status;
  const mode = s.prompt ? "PROMPT"
    : s.input ? (s.input.kind === "search" ? "SEARCH" : "COMMAND")
    : s.buffer ? `BUFFER:${s.buffer.toUpperCase()}`
    : s.screen === "filepanel" ? "FINDER JUMP"
    : s.query ? "SEARCH"
    : s.mode === "organize" ? "ORGANIZE"
    : s.mode === "move" ? "MOVE"
    : "NORMAL";
  const count = ctx ? ctx.items.length : 0;
  const pos = count ? `${Math.min(s.cursor + 1, count)}/${count}` : "0/0";
  const modeW = textW(mode, 12.5) + 48;
  return (
    <g>
      <R x={x} y={y} w={w} h={h} fill={COLOR.forest} />
      <T x={x + LAYOUT.margin} y={y + 19.5} size={12.5} weight={700} fill={COLOR.yellow} spacing={1.2}>{mode}</T>
      {s.buffer !== "settings" && s.buffer !== "calc" && (
        <T x={x + LAYOUT.margin - 16 + modeW} y={y + 19.5} size={12.5} fill={COLOR.paper} opacity={0.82}>
          · {s.query ? `“${s.query}”` : ctx.folderName} · {pos}
        </T>
      )}
      <T x={x + w - LAYOUT.margin} y={y + 19.5} size={12} anchor="end" fill={COLOR.mint} opacity={0.9}>
        {s.buffer === "settings" ? ":set <key> <value> · :help 帮助 · Esc 返回"
          : s.buffer === "calc" ? ": 命令 · Esc 关闭并保留算式"
          : ": 命令 · F1 地图 · ? 帮助"}
      </T>
    </g>
  );
}

function HintsChrome() {
  let cx = LAYOUT.margin;
  const y = LAYOUT.hintY;
  return (
    <g>
      <T x={cx} y={y} size={11.5} fill={COLOR.muted} spacing={0.8}>按键</T>
      {KEYMAP_HINTS.map(([key, label]) => {
        const kw = Math.max(24, textW(key, 11.5) + 12);
        const item = (
          <g key={key}>
            <Kbd x={cx} y={y} label={key} size={11.5} />
            <T x={cx + kw + 6} y={y + 0.5} size={11.5} fill={COLOR.muted}>{label}</T>
          </g>
        );
        cx += kw + 6 + textW(label, 11.5) + 18;
        return item;
      })}
    </g>
  );
}

/* 日志 / 补全：位于列表下方，永远可见 */
function LogPane({ s, act }) {
  const { x, y, w, h } = LAYOUT.log;

  /* 提示流：在日志区显示步骤与候选，避免“按了没反应” */
  const pr = s.prompt;
  if (pr) {
    const steps = pr.cmd === "add" ? ["url", "title", "location", "folder"] : pr.cmd === "edit" ? ["title", "url"] : null;
    const options = pr.options && pr.options.length ? pr.options : null;
    const optionStart = Math.max(0, pr.optIndex - 2);
    const ctxText = pr.cmd === "add"
      ? (pr.step === 0 ? "网址可省略 https://；Enter 下一步，Shift+Tab 无上一步"
        : pr.step === 1 ? "Shift+Tab 返回网址；Enter 下一步"
        : pr.step === 2 ? "Tab 循环候选；Shift+Tab 返回标题"
        : "输入新文件夹名称；Shift+Tab 返回位置")
      : pr.cmd === "delete" ? `目标：${pr.payload && pr.payload.title ? pr.payload.title : ""}`
      : pr.cmd === "hotkey" ? "按下组合键；Esc 取消"
      : pr.cmd === "edit" ? truncate(pr.label === "title" ? `网址：${pr.payload.url}` : `标题：${pr.payload.title}`, 11.5, w - 28)
      : pr.cmd === "rename" ? "光标在名称末尾；Enter 保存"
      : pr.cmd === "mkdir" ? "新文件夹建在根目录；名称不能与现有文件夹重复"
      : pr.cmd === "move" && pr.step === 1 ? "新文件夹建在根目录；书签将移入该文件夹"
      : "Tab 补全候选；Enter 执行";
    return (
      <g>
        <R x={x} y={y} w={w} h={h} fill={COLOR.surface} opacity={0.55} />
        <R x={x} y={y} w={3} h={h} fill={COLOR.yellow} />
        <L x1={x} y1={y} x2={x + w} y2={y} stroke={COLOR.line} />
        <T x={x + 14} y={y + 14} size={10.5} fill={COLOR.muted} spacing={1.6}>
          {`PROMPT · ${pr.cmd.toUpperCase()}${options ? ` · 候选 ${options.length}` : ""}`}
        </T>
        {steps && (
          <g>
            {steps.map((st, i) => {
              const cx = x + 150 + i * 66;
              const state = i < pr.step ? "done" : i === pr.step ? "now" : "next";
              return (
                <g key={st}>
                  <T x={cx} y={y + 14} size={11.5}
                     weight={state === "now" ? 700 : 400}
                     fill={state === "now" ? COLOR.amber : state === "done" ? COLOR.green : COLOR.muted}>
                    {st}
                  </T>
                  {i < steps.length - 1 && <T x={cx + 46} y={y + 14} size={11} fill={COLOR.line}>{">"}</T>}
                </g>
              );
            })}
          </g>
        )}
        <T x={x + w - 10} y={y + 14} size={10.5} anchor="end" fill={COLOR.muted}>
          {pr.cmd === "edit"
            ? "Tab/Shift+Tab 切换字段 · Enter 保存全部 · Esc 取消"
            : pr.cmd === "add" && pr.step === 0
            ? "步骤 1/4 · Enter 下一步 · Esc 取消"
            : steps ? `步骤 ${pr.step + 1}/${steps.length} · Shift+Tab 返回 · Esc 取消`
            : "Esc 取消"}
        </T>
        {options ? (
          options.slice(optionStart, optionStart + 3).map((opt, offset) => {
            const i = optionStart + offset;
            const sel = i === pr.optIndex;
            const oy = y + 34 + offset * 14;
            return (
              <g key={opt.id + i} onClick={() => act.setPromptOption && act.setPromptOption(i)} style={{ cursor: "pointer" }}>
                {sel && <R x={x} y={oy - 8} w={w} h={16} fill={COLOR.ink} />}
                <T x={x + 10} y={oy} size={11.5} fill={sel ? COLOR.yellow : COLOR.muted}>{String(i + 1).padStart(2, "0")}</T>
                <T x={x + 38} y={oy} size={12.5} fill={sel ? COLOR.paper : COLOR.ink}>{opt.label}</T>
                {opt.hint && <T x={x + w - 10} y={oy} size={11} anchor="end" fill={sel ? COLOR.mint : COLOR.muted}>{opt.hint}</T>}
              </g>
            );
          })
        ) : (
          <g>
            <T x={x + 14} y={y + 36} size={12.5} fill={COLOR.ink2}>{pr.hint || "Enter 确认 · Esc 取消"}</T>
            <T x={x + 14} y={y + 54} size={11.5} fill={COLOR.muted}>{ctxText}</T>
          </g>
        )}
      </g>
    );
  }

  if (s.mode === "organize") {
    return (
      <g>
        <L x1={x} y1={y} x2={x + w} y2={y} stroke={COLOR.line} />
        <T x={x} y={y + 14} size={11} weight={700} fill={COLOR.green}>整理 / ORGANIZE</T>
        <T x={x} y={y + 35} size={13} fill={COLOR.ink2}>j/k 选择 · Shift+↑/↓ 或 J/K 调整书签顺序 · m 移到文件夹 · D 删除确认</T>
        <T x={x} y={y + 54} size={12} fill={COLOR.muted}>文件夹始终置顶，位置固定；仅书签参与排序。按 o 或 Esc 完成整理。</T>
      </g>
    );
  }

  const promptOptions = null;
  const cmdPrefix = s.input && s.input.kind === "command" && !/\s/.test(s.input.value)
    ? s.input.value.trim().toLowerCase() : null;
  const cmdOptions = cmdPrefix != null
    ? COMMANDS.filter(([n]) => n.startsWith(cmdPrefix)).slice(0, 3).map(([n, d, usage]) => ({ id: n, label: ":" + n, hint: d, usage }))
    : null;
  const options = promptOptions && promptOptions.length ? promptOptions : cmdOptions;
  const showOptions = options && options.length > 0;
  const isCommandComplete = !promptOptions && cmdOptions;
  const lines = (s.log || []).slice(-3);
  return (
    <g>
      <L x1={x} y1={y} x2={x + w} y2={y} stroke={COLOR.line} />
      <T x={x} y={y + 15} size={10.5} fill={COLOR.muted} spacing={1.6}>
        {showOptions ? (isCommandComplete ? "COMMANDS · Tab 补全 · ↑↓ 历史" : "COMPLETE · Tab 循环 · ↑↓ 选择 · Enter 确认") : "OUTPUT"}
      </T>
      <T x={x + w} y={y + 15} size={10.5} anchor="end" fill={COLOR.muted}>
        {showOptions ? (isCommandComplete ? options.length + " 项" : `${s.prompt.optIndex + 1}/${options.length}`) : ":log 查看全部"}
      </T>
      {showOptions ? (
        options.slice(0, 3).map((opt, i) => {
          const sel = !isCommandComplete && i === (s.prompt.optIndex % Math.max(1, options.length));
          const oy = y + 34 + i * 16;
          return (
            <g key={opt.id + i}>
              {sel && <R x={x} y={oy - 8} w={w} h={16} fill={COLOR.ink} />}
              <T x={x + 8} y={oy} size={11.5} fill={sel ? COLOR.yellow : COLOR.muted}>{String(i + 1).padStart(2, "0")}</T>
              <T x={x + 34} y={oy} size={12.5} fill={sel ? COLOR.paper : COLOR.ink}>{opt.label}</T>
              {opt.hint && <T x={x + w - 8} y={oy} size={11} anchor="end" fill={sel ? COLOR.mint : COLOR.muted}>{opt.hint}</T>}
            </g>
          );
        })
      ) : lines.length ? (
        lines.map((l, i) => (
          <g key={l.seq || i}>
            <T x={x} y={y + 34 + i * 16} size={11.5} fill={COLOR.muted}>{l.time}</T>
            <T x={x + 66} y={y + 34 + i * 16} size={12.5}
               fill={l.kind === "error" ? COLOR.red : l.kind === "warn" ? COLOR.amber : l.kind === "ok" ? COLOR.green : COLOR.ink2}>
              {truncate(l.text, 12.5, w - 80)}
            </T>
          </g>
        ))
      ) : (
        <T x={x} y={y + 40} size={12} fill={COLOR.muted} opacity={0.75}>
          就绪。输入 : 打开命令，/ 搜索，a 添加，? 帮助。
        </T>
      )}
    </g>
  );
}
