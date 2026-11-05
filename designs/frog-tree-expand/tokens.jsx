/* 青蛙导航 · 回声终端 — 设计令牌
 * 冷白纸面 + 中国传统色；全部操作以命令行与缓冲区表达，无弹窗。
 * 文字颜色对 象牙白 #FFFEF8 的对比度均 ≥ 4.5:1。
 */

const COLOR = {
  /* ===== 底色（去黄） ===== */
  paper:    "#FFFEF8", // 象牙白 — 终端画布
  surface:  "#F8F4ED", // 汉白玉 — 缓冲区块底
  line:     "#E4DFD7", // 珍珠灰 — 分隔线、边框、禁用填充

  /* ===== 文字 ===== */
  ink:      "#0F1A20", // 墨黑 17.0:1
  ink2:     "#3B3A3E", // 松烟墨 10.9:1
  muted:    "#695E45", // 蟹壳灰 6.3:1
  green:    "#0D5E3A", // 深绿 7.6:1
  pine:     "#2E4B26", // 松墨 9.5:1
  purple:   "#7E1671", // 魏紫 9.1:1
  blue:     "#1661AB", // 靛青 6.2:1
  teal:     "#126E82", // 玉鈫蓝 5.8:1
  red:      "#7C1823", // 枣红 10.2:1
  amber:    "#862617", // 赭石 8.9:1

  /* ===== 填充 ===== */
  yellow:   "#E6C24D", // 鸦黄 — 光标 / 选中标记
  lemon:    "#F8DF72", // 茉莉黄 — 警告底
  mint:     "#ADD5A2", // 嘉陵水绿 — 成功 / 目标底
  forest:   "#1A3B2E", // 墨绿 — 状态栏
  gold:     "#FFD111", // 藤黄
};

const TILE_COLORS = [
  COLOR.green, COLOR.purple, COLOR.blue, COLOR.red,
  COLOR.amber, COLOR.teal, COLOR.pine, COLOR.forest,
];

function frogTileColor(id) {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return TILE_COLORS[h % TILE_COLORS.length];
}

/* ===== 画布与栅格（1440 × 900，页面即应用主界面，全出血无外框） ===== */
const LAYOUT = {
  W: 1440,
  H: 900,
  cmd:    { x: 0, y: 752, w: 1440, h: 40 },
  status: { x: 0, y: 796, w: 1440, h: 36 },
  hintY:  856,
  list:   { x: 40, y: 24, w: 1360, h: 600 },
  log:    { x: 40, y: 664, w: 1360, h: 72 },
  margin: 40,
  rowH: 32,
  pad: 16,
};

/* 列表可视区几何：单页滚动，不分页；文件夹内预留面包屑高度 */
const CRUMB_H = 40;

function frogListGeom(showCrumb) {
  const rowsTop = LAYOUT.list.y + (showCrumb ? CRUMB_H : 0);
  const rowsBottom = LAYOUT.log.y - 16;
  return {
    rowsTop,
    rowsBottom,
    visible: Math.max(1, Math.floor((rowsBottom - rowsTop) / LAYOUT.rowH)),
  };
}

/* 文件夹内显示面包屑；搜索结果跨文件夹，不显示 */
function frogShowsCrumb(s) {
  return !!s.folderId && !s.query.trim();
}

const FONT_MONO = '"SF Mono", "JetBrains Mono", "Cascadia Mono", Menlo, Consolas, "PingFang SC", "Noto Sans Mono CJK SC", monospace';
const FONT_SANS = '-apple-system, BlinkMacSystemFont, "PingFang SC", "Microsoft YaHei", sans-serif';

const TYPE = {
  xs: 10, sm: 11, meta: 12, body: 14, strong: 15,
  title: 18, panel: 19, hero: 22, hint: 11.5,
};

/* 状态栏 / 帮助 / 命令补全共用的键位提示 */
const KEYMAP_HINTS = [
  ["j / k", "移动"],
  ["/", "搜索"],
  [":", "命令"],
  ["a", "添加"],
  ["n", "新建文件夹"],
  ["e", "编辑"],
  ["m", "移动"],
  ["D", "删除"],
  ["o", "排序整理"],
  ["F1", "地图"],
  ["?", "帮助"],
];

const COMMANDS = [
  ["add", "添加书签", "add", "逐项输入网址、标题与位置"],
  ["edit", "编辑标题与网址", "edit [url|title]", "Tab 切换字段，Enter 保存全部"],
  ["rename", "重命名文件夹", "rename", "以当前名称预填"],
  ["mkdir", "新建文件夹", "mkdir [名称]", "无名称时提示输入，建在根目录"],
  ["delete", "删除当前项", "delete", "命令行确认 y/N"],
  ["move", "移动书签到分组", "move", "补全目标位置"],
  ["open", "打开第 n 条", "open <n>", ""],
  ["copy", "复制当前链接", "copy", ""],
  ["group", "进入文件夹", "group <名称>", "根目录：group 根目录"],
  ["find", "搜索", "find <关键词>", "等同 /"],
  ["set", "查看或修改设置", "set [key] [value]", "无参数打开设置缓冲区"],
  ["backup", "导出备份", "backup [文件路径]", "另存书签与文件夹 JSON"],
  ["restore", "恢复备份", "restore <备份文件>", "替换当前全部书签与文件夹"],
  ["cd", "切换数据目录", "cd <目录>", "使用目录中的 bookmarks.json"],
  ["help", "打开帮助", "help [命令]", "等同 ?"],
  ["atlas", "界面地图", "atlas", "等同 F1"],
  ["log", "查看完整日志", "log", ""],
  ["retry", "重试数据载入", "retry", ""],
  ["clear", "清空日志", "clear", ""],
  ["q", "退出（原型不退出）", "q", ""],
];

const DEMO_TOAST_MS = 2200;
