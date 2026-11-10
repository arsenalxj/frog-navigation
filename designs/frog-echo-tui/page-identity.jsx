/* B 方案：输入区使用传统色原值；来源为 zhongguo-traditional-colors/assets/data/images.js。 */
const IDENTITY_PAGES = {
  main: { label: "主界面", colorName: "艾背绿", colorID: "498", band: "#DFECD5", accent: COLOR.green },
  commands: { label: "自定义命令", colorName: "远天蓝", colorID: "368", band: "#D0DFE6", accent: COLOR.blue },
  calc: { label: "计算器", colorName: "杏仁黄", colorID: "002", band: "#F7E8AA", accent: COLOR.amber },
};
function pageIdentity(s) {
  if ((s.buffer && !["commands", "calc"].includes(s.buffer)) || s.screen === "filepanel") return null;
  return IDENTITY_PAGES[s.buffer || "main"];
}
