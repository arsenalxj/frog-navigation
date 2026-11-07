/* 青蛙导航 · 回声终端 — 缓冲区视图
 * 设置 / 帮助 / 界面地图 / 日志 / 任务输出全部是终端缓冲区，不是弹窗。
 */

const BV = {
  x: 40,
  y: 24,
  w: 1360,
  h: 712,
  bodyTop: 84,
};

function bvTitle(ctx, name, right) {
  const { s, act } = ctx;
  return (
    <g>
      <T x={BV.x} y={BV.y + 12} size={10} fill={COLOR.muted} spacing={1.8}>BUFFER</T>
      <T x={BV.x + 62} y={BV.y + 12} size={13} weight={700} fill={COLOR.ink}>[{name}]</T>
      {right && <T x={BV.x + BV.w} y={BV.y + 12} size={10.5} anchor="end" fill={COLOR.muted}>{right}</T>}
      <L x1={BV.x} y1={BV.y + 26} x2={BV.x + BV.w} y2={BV.y + 26} stroke={COLOR.line} />
    </g>
  );
}

function bvLineNo(x, y, n) {
  return <T x={x} y={y} size={10} fill={COLOR.muted} opacity={0.65}>{String(n).padStart(3, "0")}</T>;
}

/* ================= 设置缓冲区 ================= */

function bvSettings(ctx) {
  const { s } = ctx;
  const st = s.settings;
  const on = (v) => v ? "on" : "off";
  const cx = BV.x + 56;
  const valueX = cx + 190;
  const hintX = BV.x + 800;
  const valueWidth = hintX - (valueX + 18) - 40;
  const rows = [];
  let y = BV.bodyTop + 32;
  const line = (text, opts = {}) => {
    const row = (
      <g key={"l" + rows.length}>
        {bvLineNo(cx, y, rows.length + 1)}
        <T x={cx + 34} y={y} size={12} fill={opts.color || COLOR.ink}>{text}</T>
        {opts.hint && <T x={hintX} y={y} size={10.5} fill={COLOR.muted}>{opts.hint}</T>}
      </g>
    );
    rows.push(row);
    y += 20;
    return row;
  };
  const kv = (key, value, hint, valueColor) => {
    const flashed = s.flash && s.flash.key === key;
    const displayValue = truncate(value, 12, valueWidth);
    const row = (
      <g key={"k" + rows.length}>
        {displayValue !== String(value) && <title>{value}</title>}
        {bvLineNo(cx, y, rows.length + 1)}
        <T x={cx + 34} y={y} size={12} fill={COLOR.teal}>{key}</T>
        <T x={valueX} y={y} size={12} fill={COLOR.muted}>=</T>
        <T x={valueX + 18} y={y} size={12} weight={600} fill={flashed ? COLOR.amber : (valueColor || COLOR.ink)}>{displayValue}</T>
        {flashed ? <T x={valueX + 18 + textW(displayValue, 12) + 8} y={y} size={11} fill={COLOR.amber}>←</T> : null}
        {hint && <T x={hintX} y={y} size={10.5} fill={COLOR.muted}>{hint}</T>}
      </g>
    );
    rows.push(row);
    y += 20;
    return row;
  };

  line("# ~/.config/frog/config.toml · 本机偏好，不进入备份", { color: COLOR.muted });
  line("");
  line("[general] · 通用", { color: COLOR.green });
  kv("login", st.loginApproval ? "pending" : on(st.login), ":set login on|off",
     st.loginApproval ? COLOR.amber : st.login ? COLOR.green : COLOR.muted);
  if (st.loginApproval) line("  # 等待系统批准。执行 :set login approve 模拟批准。", { color: COLOR.amber });
  if (st.loginError) line("  # ! " + st.loginError, { color: COLOR.red });
  kv("hotkey", st.hotkey ? st.hotkeyText : "disabled", ":set hotkey record|reset|on|off",
     st.hotkeyConflict ? COLOR.red : st.hotkey ? COLOR.ink : COLOR.muted);
  if (st.hotkeyError) line("  # ! " + st.hotkeyError, { color: COLOR.red });
  kv("corner", st.corner ? st.cornerText : "disabled", ":set corner left-up|left-down|right-up|right-down",
     st.cornerError ? COLOR.red : COLOR.ink);
  if (st.cornerError) line("  # ! " + st.cornerError, { color: COLOR.red });
  kv("finder", on(st.finderJump), ":set finder on|off", st.finderMissing ? COLOR.amber : COLOR.ink);
  if (st.finderMissing) {
    line("  # 缺少辅助功能 / Finder 自动化权限。", { color: COLOR.amber });
    line("  # 执行 :set finder authorize 模拟授权；⌃G 冲突时调整启动台快捷键。", { color: COLOR.amber });
  }
  if (st.finderConflict) line("  # ! ⌃G 已用于展开启动台，快跳快捷键被暂停。", { color: COLOR.amber });
  if (st.finderError) line("  # ! " + st.finderError, { color: COLOR.red });
  line("");
  line("[data] · 书签数据", { color: COLOR.green });
  kv("file", `${st.dataPath.replace(/\/+$/, "")}/bookmarks.json`, ":cd <目录>", COLOR.ink);
  line("  # 文件名固定为 bookmarks.json；:cd 切换存放目录。", { color: COLOR.muted });
  line("");
  line("[operations] · 数据操作", { color: COLOR.green });
  line("导出备份 · 另存书签与文件夹 JSON", { hint: ":backup [文件路径]" });
  line("恢复备份 · 替换当前全部书签与文件夹", { hint: ":restore <备份文件>" });
  line("自定义命令 · 终端 / 程序 / 网址（macOS）", { hint: ":commands" });
  line("");
  line("[status] · 运行状态", { color: COLOR.green });
  kv("bookmarks", String(s.doc.bookmarks.length), "", COLOR.ink);
  kv("groups", String(s.doc.groups.length), "", COLOR.ink);
  kv("schema", "frog-bookmarks v1", "", COLOR.muted);
  kv("log", `${s.log.length} lines`, ":log", COLOR.muted);

  return (
    <g>
      {bvTitle(ctx, "settings")}
      <T x={cx + 34} y={BV.bodyTop} size={10.5} fill={COLOR.muted}>设置项</T>
      <T x={valueX + 18} y={BV.bodyTop} size={10.5} fill={COLOR.muted}>当前值</T>
      <T x={hintX} y={BV.bodyTop} size={10.5} fill={COLOR.muted}>命令</T>
      {rows}
    </g>
  );
}

/* ================= 帮助缓冲区 ================= */

function bvHelp(ctx) {
  const { s, act } = ctx;
  const X = BV.x + 24;
  const descX = BV.x + 300;
  const usageX = BV.x + 720;
  const keysX = BV.x + 1040;
  return (
    <g>
      {bvTitle(ctx, "help", "? / Esc 返回 · :help <command>")}

      <T x={X} y={BV.bodyTop} size={12} weight={700} fill={COLOR.green}>NAME</T>
      <T x={descX} y={BV.bodyTop} size={12} fill={COLOR.ink}>青蛙导航 — 本地书签启动台。所有操作在命令行完成。</T>

      <T x={X} y={BV.bodyTop + 30} size={12} weight={700} fill={COLOR.green}>SYNOPSIS</T>
      <T x={descX} y={BV.bodyTop + 30} size={12} fill={COLOR.ink}>frog [command] · :commands 管理自定义命令 · :help 帮助 · / 搜索</T>

      <T x={X} y={BV.bodyTop + 64} size={12} weight={700} fill={COLOR.green}>COMMANDS</T>
      {ctx.commands.map(([name, desc, usage, note], i) => {
        const cy = BV.bodyTop + 88 + i * 20;
        return (
          <g key={name}>
            <T x={X} y={cy} size={12} weight={600} fill={COLOR.teal}>{":" + name}</T>
            <T x={descX} y={cy} size={11.5} fill={COLOR.ink}>{desc}</T>
            <T x={usageX} y={cy} size={10.5} fill={COLOR.muted}>{truncate(usage + (note ? " · " + note : ""), 10.5, 220)}</T>
          </g>
        );
      })}

      <L x1={BV.x + 990} y1={BV.bodyTop + 58} x2={BV.x + 990} y2={BV.bodyTop + 500} stroke={COLOR.line} />
      <T x={keysX} y={BV.bodyTop + 64} size={12} weight={700} fill={COLOR.green}>KEYS</T>
      {ctx.shortcuts.map(([k, d], i) => {
        const cy = BV.bodyTop + 88 + i * 20;
        return (
          <g key={k + i}>
            <T x={keysX} y={cy} size={11} weight={600} fill={COLOR.teal}>{k}</T>
            <T x={keysX + 130} y={cy} size={11.5} fill={COLOR.ink}>{d}</T>
          </g>
        );
      })}

      <L x1={X} y1={BV.bodyTop + 500} x2={BV.x + 960} y2={BV.bodyTop + 520} stroke={COLOR.line} />
      <T x={X} y={BV.bodyTop + 520} size={12} weight={700} fill={COLOR.green}>EXAMPLES</T>
      {[
        ":add                                  逐项输入网址 / 标题 / 位置",
        ":edit url                             修改当前书签网址",
        ":delete                               命令行 y/N 确认删除",
        ":set corner right-up                  修改屏幕触角",
        ":backup ~/Documents/frog.json         导出备份",
      ].map((line, i) => (
        <T key={i} x={X} y={BV.bodyTop + 542 + i * 17} size={11.5} fill={COLOR.ink2}>{line}</T>
      ))}

      <T x={X} y={BV.y + BV.h - 10} size={10} fill={COLOR.muted}>
        {truncate(`FILES: ${s.settings.dataPath.replace(/\/+$/, "")}/bookmarks.json`, 10, BV.w - 48)}
      </T>
    </g>
  );
}

/* ================= 日志缓冲区 ================= */

function bvLog(ctx) {
  const { s, act } = ctx;
  const lines = s.log.slice(-26);
  return (
    <g>
      {bvTitle(ctx, "log", ":clear 清空 · Esc 返回")}
      {lines.map((l, i) => {
        const y = BV.bodyTop + i * 20;
        return (
          <g key={l.seq}>
            {bvLineNo(BV.x + 32, y, i + 1)}
            <T x={BV.x + 76} y={y} size={11} fill={COLOR.muted}>{l.time}</T>
            <T x={BV.x + 150} y={y} size={12}
               fill={l.kind === "error" ? COLOR.red : l.kind === "warn" ? COLOR.amber : l.kind === "ok" ? COLOR.green : COLOR.ink2}>
              {l.text}
            </T>
          </g>
        );
      })}
      {!lines.length && <T x={BV.x + 32} y={BV.bodyTop} size={12} fill={COLOR.muted}>日志为空。</T>}
    </g>
  );
}

/* ================= 计算器缓冲区 ================= */

function bvCalc(ctx) {
  const { s, act } = ctx;
  const X = BV.x + 32;
  const RIGHT = BV.x + BV.w - 32;
  const calc = s.calc;
  const expr = calc.expr.trim();
  const error = calc.error && calc.error.expr === expr ? calc.error : null;
  const trial = expr && !error ? frogCalcTry(expr) : null;
  const value = trial && trial.ok ? frogCalcFormat(trial.value) : null;
  const capacity = CALC_VISIBLE_ROWS;
  const start = Math.min(Math.max(0, calc.offset || 0), Math.max(0, calc.history.length - capacity));
  const history = calc.history.slice(start, start + capacity);
  const resultY = BV.bodyTop + 30;

  return (
    <g onClick={() => act.focusInput()} style={{ cursor: "text" }}>
      {bvTitle(ctx, "calc", `${calc.history.length} 条历史 · Esc 关闭`)}

      <g data-calc-result={value != null ? "value" : error ? "error" : expr ? "pending" : "empty"}>
        {value != null ? (
          <T x={X} y={resultY} size={40} weight={700} fill={COLOR.green}
             style={{ fontVariantNumeric: "tabular-nums" }}>{truncate(value, 40, RIGHT - X)}</T>
        ) : error ? (
          <T x={X} y={resultY - 6} size={15} weight={600} fill={COLOR.red}>✗ {error.message}</T>
        ) : expr ? (
          <T x={X} y={resultY} size={34} weight={700} fill={COLOR.line}>…</T>
        ) : (
          <T x={X} y={resultY - 4} size={14} fill={COLOR.muted}>输入算式后按 Enter 计算</T>
        )}
      </g>

      <L x1={X} y1={BV.bodyTop + 84} x2={RIGHT} y2={BV.bodyTop + 84} stroke={COLOR.line} />
      <T x={X} y={BV.bodyTop + 108} size={10.5} fill={COLOR.muted} spacing={1.6}>
        {`HISTORY · ${calc.history.length} 条`}
      </T>
      <T x={RIGHT} y={BV.bodyTop + 108} size={10.5} anchor="end" fill={COLOR.muted}>
        ↑↓ 选择 · 点击载入 · c 复制结果
      </T>

      {history.length ? history.map((entry, i) => {
        const index = start + i;
        const y = BV.bodyTop + 132 + i * 26;
        const sel = calc.histIndex === index;
        const exprMax = RIGHT - X - 130 - textW(entry.value, 13) - 24;
        return (
          <g key={entry.id} data-calc-row={entry.expr} data-selected={sel ? "true" : "false"}
             onClick={(e) => { e.stopPropagation(); act.calcUse(entry.id); }}
             style={{ cursor: "pointer" }}>
            <R x={X - 8} y={y - 11} w={RIGHT - X + 16} h={22} fill="transparent" />
            {sel && <R x={X - 8} y={y - 11} w={RIGHT - X + 16} h={22} fill={COLOR.ink} />}
            {sel && <R x={X - 8} y={y - 11} w={3} h={22} fill={COLOR.yellow} />}
            <T x={X} y={y} size={10} fill={sel ? COLOR.yellow : COLOR.muted}>{String(index + 1).padStart(2, "0")}</T>
            <T x={X + 28} y={y} size={11} fill={sel ? COLOR.mint : COLOR.muted}>{entry.time}</T>
            <T x={X + 100} y={y} size={12.5} fill={sel ? COLOR.paper : COLOR.ink}>
              {truncate(entry.expr, 12.5, Math.max(80, exprMax))}
            </T>
            <T x={RIGHT} y={y} size={13} weight={600} anchor="end" fill={sel ? COLOR.mint : COLOR.green}>
              {entry.value}
            </T>
          </g>
        );
      }) : null}

      <T x={X} y={BV.y + BV.h - 10} size={10} fill={COLOR.muted}>
        支持 + - * / 与括号 · 结果保留 12 位有效数字 · 历史最多 50 条，重复算式只保留最新一条
      </T>
    </g>
  );
}

/* ================= 任务输出缓冲区 ================= */

function bvJob(ctx) {
  const { s, act } = ctx;
  const job = s.job || { title: "job", status: "ok", lines: [] };
  const statusColor = job.status === "running" ? COLOR.amber : job.status === "error" ? COLOR.red : COLOR.green;
  return (
    <g>
      {bvTitle(ctx, "job", "Esc 返回 · :log 查看日志")}
      <T x={BV.x + 32} y={BV.bodyTop} size={11} fill={COLOR.muted}>TASK</T>
      <T x={BV.x + 110} y={BV.bodyTop} size={13} weight={700} fill={COLOR.ink}>{job.title}</T>
      <Tag x={BV.x + 250} y={BV.bodyTop} label={job.status === "running" ? "RUNNING" : job.status === "error" ? "ERROR" : "DONE"}
           fill={job.status === "error" ? COLOR.red : job.status === "running" ? COLOR.yellow : COLOR.mint}
           fg={job.status === "error" ? COLOR.paper : COLOR.ink} size={10} />
      <L x1={BV.x + 32} y1={BV.bodyTop + 20} x2={BV.x + BV.w - 32} y2={BV.bodyTop + 20} stroke={COLOR.line} />
      {job.lines.map((l, i) => {
        const y = BV.bodyTop + 48 + i * 24;
        const c = l.kind === "cmd" ? COLOR.teal : l.kind === "error" ? COLOR.red : l.kind === "ok" ? COLOR.green : l.kind === "muted" ? COLOR.muted : COLOR.ink2;
        return (
          <g key={i}>
            <T x={BV.x + 32} y={y} size={10} fill={COLOR.muted}>{String(i + 1).padStart(2, "0")}</T>
            <T x={BV.x + 76} y={y} size={12.5} fill={c}>{l.text}</T>
          </g>
        );
      })}
      {job.status === "running" && (
        <T x={BV.x + 32} y={BV.bodyTop + 48 + job.lines.length * 24 + 10} size={12} fill={COLOR.amber}>▊ 运行中…</T>
      )}
      <T x={BV.x} y={BV.y + BV.h - 8} size={10} fill={COLOR.muted}>
        任务不会阻塞书签浏览。命令与结果同时写入 :log。
      </T>
    </g>
  );
}

/* ================= 界面地图缓冲区 ================= */

function bvAtlas(ctx) {
  const { s, act } = ctx;
  const scenes = window.FROG_SCENES || [];
  let acc = 0;
  const groups = scenes.map((g) => {
    const items = g.items.map(([id, label], i) => ({ id, label, n: acc + i + 1 }));
    acc += g.items.length;
    return { name: g.group, items };
  });
  const c1 = groups.filter((g) => ["主流程", "整理与拖拽"].includes(g.name));
  const c2 = groups.filter((g) => ["命令行", "缓冲区"].includes(g.name));
  const c3 = groups.filter((g) => ["任务输出", "系统"].includes(g.name));
  const Y0 = BV.bodyTop + 10;
  const heightOf = (list) => list.reduce((sum, g) => sum + 24 + g.items.length * 22 + 10, 0);

  const column = (x, w, list) => {
    let y = Y0;
    return (
      <g>
        {list.map((grp) => {
          const head = (
            <g key={"h" + grp.name}>
              <T x={x} y={y + 9} size={10} weight={700} fill={COLOR.ink2} spacing={0.8}>{grp.name}</T>
              <T x={x + libTextW(grp.name, 10) + 8} y={y + 9} size={9} fill={COLOR.muted}>{String(grp.items.length).padStart(2, "0")}</T>
              <L x1={x + libTextW(grp.name, 10) + 34} y1={y + 9} x2={x + w} y2={y + 9} stroke={COLOR.line} dash="2 5" />
            </g>
          );
          y += 22;
          const rows = grp.items.map((it) => {
            const ry = y;
            y += 22;
            const cur = it.n - 1 === s.atlasCursor;
            return (
              <g key={it.id} onClick={() => act.jumpScene(it.id)} style={{ cursor: "pointer" }}>
                {cur && <R x={x} y={ry} w={w} h={20} fill={COLOR.ink} />}
                <T x={x + 4} y={ry + 10} size={9.5} fill={cur ? COLOR.yellow : COLOR.muted}>{String(it.n).padStart(2, "0")}</T>
                <T x={x + 34} y={ry + 10} size={11.5} fill={cur ? COLOR.paper : COLOR.ink}>{it.label}</T>
                {cur && <T x={x + w - 6} y={ry + 10} size={9} anchor="end" fill={COLOR.mint}>当前</T>}
              </g>
            );
          });
          y += 10;
          return <g key={grp.name}>{head}{rows}</g>;
        })}
      </g>
    );
  };

  return (
    <g>
      {bvTitle(ctx, "atlas", `${acc} 个场景 · j/k 移动 · Enter 打开 · F1/Esc 关闭`)}
      {column(BV.x + 20, 410, c1)}
      {column(BV.x + 470, 410, c2)}
      {column(BV.x + 920, 400, c3)}
      <R x={BV.x + 920} y={Y0 + heightOf(c3) + 10} w={400} h={74} fill={COLOR.surface} stroke={COLOR.line} />
      <T x={BV.x + 936} y={Y0 + heightOf(c3) + 30} size={10.5} fill={COLOR.ink2}>当前项：墨黑底 + 鸦黄序号</T>
      <T x={BV.x + 936} y={Y0 + heightOf(c3) + 48} size={10.5} fill={COLOR.muted}>?scene=&lt;id&gt; 可直接分享单帧。</T>
      <T x={BV.x + 936} y={Y0 + heightOf(c3) + 66} size={10.5} fill={COLOR.muted}>所有操作都通过命令行完成。</T>
    </g>
  );
}

function libTextW(str, size) {
  let w = 0;
  for (const ch of String(str || "")) w += ch.charCodeAt(0) > 255 ? size : size * 0.6;
  return w;
}

/* ================= 系统文件面板（外部窗口 mock） ================= */

function bvFilePanel(ctx) {
  const { s, act } = ctx;
  const hidden = s.filepanel && s.filepanel.hidden;
  const P = { x: 170, y: 86, w: 1100, h: 640 };
  const files = [
    ["青蛙导航.app", "今天 09:30", "24.6 MB", "app"],
    ["使用说明.pdf", "昨天 18:02", "1.2 MB", "doc"],
    ["品牌草稿.md", "2026-10-28", "4 KB", "doc"],
    ["截图", "2026-10-21", "12 项", "folder"],
  ];
  return (
    <g>
      <R x={P.x + 5} y={P.y + 5} w={P.w} h={P.h} fill={COLOR.line} opacity={0.55} />
      <R x={P.x} y={P.y} w={P.w} h={P.h} fill={COLOR.surface} stroke={COLOR.ink} sw={1.2} />
      <R x={P.x} y={P.y} w={P.w} h={30} fill={COLOR.ink} />
      <T x={P.x + 14} y={P.y + 15.5} size={13} weight={700} fill={COLOR.paper}>打开</T>
      <g onClick={() => act.closeScreen()} style={{ cursor: "pointer" }}>
        <T x={P.x + P.w - 14} y={P.y + 15.5} size={11} anchor="end" fill={COLOR.paper} opacity={0.85}>Esc 关闭</T>
      </g>

      <L x1={P.x + 190} y1={P.y + 30} x2={P.x + 190} y2={P.y + 574} stroke={COLOR.line} />
      <T x={P.x + 20} y={P.y + 56} size={10} fill={COLOR.muted}>位置</T>
      {["桌面", "文稿", "下载", "项目目录"].map((n, i) => {
        const y = P.y + 82 + i * 28;
        const sel = n === "项目目录";
        return (
          <g key={n}>
            {sel && <R x={P.x + 10} y={y - 12} w={168} h={24} fill={COLOR.ink} />}
            <Icon name="folder" x={P.x + 22} y={y - 8} size={14} color={sel ? COLOR.yellow : COLOR.muted} />
            <T x={P.x + 48} y={y} size={11.5} fill={sel ? COLOR.paper : COLOR.ink2}>{n}</T>
          </g>
        );
      })}
      <T x={P.x + 20} y={P.y + 236} size={10} fill={COLOR.muted}>标签</T>
      {["最近使用", "个人收藏", "设计"].map((n, i) => (
        <g key={n}>
          <Icon name={i === 0 ? "clock" : "dot"} x={P.x + 22} y={P.y + 260 + i * 26 - 7} size={12} color={COLOR.muted} />
          <T x={P.x + 48} y={P.y + 260 + i * 26} size={11} fill={COLOR.ink2}>{n}</T>
        </g>
      ))}

      <T x={P.x + 214} y={P.y + 56} size={10} fill={COLOR.muted}>个人 › 项目目录</T>
      <T x={P.x + P.w - 20} y={P.y + 56} size={10} anchor="end" fill={COLOR.muted}>4 个项目</T>
      <L x1={P.x + 206} y1={P.y + 70} x2={P.x + P.w - 12} y2={P.y + 70} stroke={COLOR.line} />
      <T x={P.x + 220} y={P.y + 88} size={10} fill={COLOR.muted}>名称</T>
      <T x={P.x + 720} y={P.y + 88} size={10} fill={COLOR.muted}>修改日期</T>
      <T x={P.x + 900} y={P.y + 88} size={10} fill={COLOR.muted}>大小</T>
      {files.map(([name, date, size, kind], i) => {
        const y = P.y + 112 + i * 30;
        const sel = i === 0;
        return (
          <g key={name}>
            {sel && <R x={P.x + 206} y={y - 13} w={P.w - 220} h={26} fill={COLOR.ink} />}
            <Icon name={kind === "folder" ? "folder" : "page"} x={P.x + 220} y={y - 8} size={14}
                  color={sel ? COLOR.yellow : kind === "folder" ? COLOR.purple : COLOR.ink2} />
            <T x={P.x + 246} y={y} size={11.5} fill={sel ? COLOR.paper : COLOR.ink}>{name}</T>
            <T x={P.x + 720} y={y} size={10.5} fill={sel ? COLOR.mint : COLOR.muted}>{date}</T>
            <T x={P.x + 900} y={y} size={10.5} fill={sel ? COLOR.mint : COLOR.muted}>{size}</T>
          </g>
        );
      })}
      <T x={P.x + 220} y={P.y + 250} size={10} fill={COLOR.muted}>已选择“青蛙导航.app” · 双击打开，或按 Enter 确认</T>

      <L x1={P.x} y1={P.y + 574} x2={P.x + P.w} y2={P.y + 574} stroke={COLOR.line} />
      <T x={P.x + 20} y={P.y + 596} size={11} fill={COLOR.muted}>文件名:</T>
      <R x={P.x + 76} y={P.y + 582} w={P.w - 300} h={28} fill={COLOR.paper} stroke={COLOR.line} />
      <T x={P.x + 88} y={P.y + 596} size={11.5} fill={COLOR.ink}>青蛙导航.app</T>
      <Btn x={P.x + P.w - 210} y={P.y + 582} w={88} h={28} label="取消" onClick={act.closeScreen} />
      <Btn x={P.x + P.w - 110} y={P.y + 582} w={90} h={28} label="打开" kind="primary" onClick={act.closeScreen} />

      {/* Finder 目录浮条 */}
      {hidden ? (
        <g>
          <R x={400} y={742} w={640} h={40} fill="none" stroke={COLOR.line} dash="4 4" />
          <T x={420} y={762} size={11} fill={COLOR.muted}>没有有效 Finder 目录 → 入口完全隐藏，⌃G 不拦截</T>
        </g>
      ) : (
        <g>
          <R x={400} y={742} w={640} h={40} fill={COLOR.mint} stroke={COLOR.green} sw={1.2} />
          <Icon name="folder" x={416} y={753} size={16} color={COLOR.green} />
          <T x={442} y={762} size={11.5} weight={600} fill={COLOR.green}>项目目录（Finder）</T>
          <T x={442} y={776} size={9.5} fill={COLOR.pine}>~/Documents/项目目录</T>
          <Kbd x={948} y={762} label="⌃G" size={10} />
        </g>
      )}
      <T x={40} y={776} size={10} fill={COLOR.muted}>G 切换有 / 无目录 · Esc 返回</T>
    </g>
  );
}

/* ================= 对外接口 ================= */

function renderBuffer(ctx) {
  switch (ctx.s.buffer) {
    case "settings": return bvSettings(ctx);
    case "help": return bvHelp(ctx);
    case "log": return bvLog(ctx);
    case "job": return bvJob(ctx);
    case "atlas": return bvAtlas(ctx);
    case "calc": return bvCalc(ctx);
    default: return null;
  }
}

window.FrogBuffers = { renderBuffer, renderFilePanel: bvFilePanel };
