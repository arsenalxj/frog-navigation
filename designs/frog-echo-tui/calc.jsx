/* 青蛙导航 · 计算器 — 算式求值
 * 只支持 + - * /、小括号、小数与空格；不使用 eval。
 * frogCalcTry 返回 { ok, value } 或 { ok: false, message }，界面直接消费。
 */

const frogCalcMaxLength = 256;
const FROG_CALC_ALLOWED = /[0-9+\-*/().eE\s]/;

function frogCalcNormalize(text) {
  return String(text === null || text === undefined ? "" : text)
    .replace(/（/g, "(").replace(/）/g, ")");
}

/* 输入与粘贴统一过滤；长度上限同时保护递归解析。 */
function frogCalcFilter(text) {
  const normalized = frogCalcNormalize(text);
  let result = "";
  for (const character of normalized) {
    if (FROG_CALC_ALLOWED.test(character)) result += character;
  }
  return result.slice(0, frogCalcMaxLength);
}

function frogCalcTry(source) {
  const text = frogCalcNormalize(source);
  if (!text.trim()) return { ok: false, message: "请输入算式" };
  if (text.length > frogCalcMaxLength) return { ok: false, message: "算式过长" };

  let i = 0;
  const fail = (message) => { throw new Error(message); };
  const skip = () => { while (i < text.length && /\s/.test(text[i])) i += 1; };

  function parseExpr() {
    let value = parseTerm();
    for (;;) {
      skip();
      const op = text[i];
      if (op !== "+" && op !== "-") return value;
      i += 1;
      const right = parseTerm();
      value = op === "+" ? value + right : value - right;
    }
  }

  function parseTerm() {
    let value = parseUnary();
    for (;;) {
      skip();
      const op = text[i];
      if (op !== "*" && op !== "/") return value;
      i += 1;
      const right = parseUnary();
      if (op === "/" && right === 0) fail("不能除以 0");
      value = op === "*" ? value * right : value / right;
    }
  }

  function parseUnary() {
    skip();
    if (text[i] === "+") { i += 1; return parseUnary(); }
    if (text[i] === "-") { i += 1; return -parseUnary(); }
    return parsePrimary();
  }

  function parsePrimary() {
    skip();
    if (text[i] === "(") {
      i += 1;
      const value = parseExpr();
      skip();
      if (text[i] !== ")") fail("缺少右括号");
      i += 1;
      return value;
    }
    const start = i;
    let dot = false;
    while (i < text.length) {
      const ch = text[i];
      if (ch >= "0" && ch <= "9") { i += 1; continue; }
      if (ch === "." && !dot) { dot = true; i += 1; continue; }
      break;
    }
    if (i === start) fail(text[i] === ")" ? "多余的右括号" : "算式不完整");
    if (text[i] === "e" || text[i] === "E") {
      i += 1;
      if (text[i] === "+" || text[i] === "-") i += 1;
      const exponentStart = i;
      while (i < text.length && text[i] >= "0" && text[i] <= "9") i += 1;
      if (i === exponentStart) fail("算式不完整");
    }
    const literal = text.slice(start, i);
    if (literal === ".") fail("算式不完整");
    const value = Number(literal);
    if (!Number.isFinite(value)) fail("数字格式无效");
    return value;
  }

  try {
    const value = parseExpr();
    skip();
    if (i < text.length) {
      fail(text[i] === ")" ? "多余的右括号" : `无法识别的字符 “${text[i]}”`);
    }
    if (!Number.isFinite(value)) fail("结果超出可计算范围");
    return { ok: true, value };
  } catch (error) {
    return { ok: false, message: error && error.message ? error.message : "无法计算" };
  }
}

/* 12 位有效数字消除 0.1 + 0.2 一类浮点尾差；整数不带小数点 */
function frogCalcFormat(value) {
  const rounded = Number(value.toPrecision(12));
  if (Object.is(rounded, -0)) return "0";
  return String(rounded);
}
