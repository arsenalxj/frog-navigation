import { test, expect } from '@playwright/test';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { dirname, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const directory = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const runtimePaths = new Map([
  ['https://unpkg.com/react@18.3.1/umd/react.development.js', join(dirname(require.resolve('react/package.json')), 'umd/react.development.js')],
  ['https://unpkg.com/react-dom@18.3.1/umd/react-dom.development.js', join(dirname(require.resolve('react-dom/package.json')), 'umd/react-dom.development.js')],
  ['https://unpkg.com/@babel/standalone@7.29.0/babel.min.js', require.resolve('@babel/standalone/babel.min.js')],
]);
const errors = new WeakMap();
let server;
let origin;

test.use({ viewport: { width: 1440, height: 900 }, browserName: 'chromium' });
test.beforeAll(async () => {
  server = createServer(async (request, response) => {
    const path = decodeURIComponent(new URL(request.url, 'http://localhost').pathname).slice(1);
    if (path !== basename(path) || !/\.(html|jsx)$/.test(path)) {
      response.writeHead(404).end();
      return;
    }
    try {
      const content = await readFile(join(directory, path));
      response.writeHead(200, {
        'Content-Type': path.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/javascript; charset=utf-8',
        'Cache-Control': 'no-store',
      });
      response.end(content);
    } catch {
      response.writeHead(404).end();
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
});
test.afterAll(async () => {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});
test.beforeEach(async ({ page }) => {
  errors.set(page, []);
  page.on('pageerror', (error) => errors.get(page).push(error.message));
  await page.route('https://unpkg.com/**', async (route) => {
    const file = runtimePaths.get(route.request().url());
    if (!file) throw new Error(`未锁定的运行时依赖：${route.request().url()}`);
    await route.fulfill({
      body: await readFile(file),
      contentType: 'application/javascript',
      headers: { 'Access-Control-Allow-Origin': '*' },
    });
  });
  await page.goto(`${origin}/${encodeURIComponent('青蛙导航 回声终端.html')}`);
  await expect(svgText(page, 'GitHub')).toBeVisible();
  // 编辑类用例从真实点击 GitHub 开始，不依赖根目录默认选中书签。
  await svgText(page, 'GitHub').click();
});
test.afterEach(async ({ page }) => {
  expect(errors.get(page), '页面不得产生运行时异常').toEqual([]);
});

function svgText(page, value) {
  return page.locator('svg text').filter({ hasText: new RegExp(`^${value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`) });
}
function input(page) {
  return page.getByRole('textbox', { name: '命令行输入' });
}
async function expectPrompt(page, command, field) {
  await expect(page.locator('svg text').filter({ hasText: new RegExp(`^${command}(?: \\d/\\d)? › ${field}$`) })).toBeVisible();
}
async function replaceText(page, value) {
  await expect(input(page)).toBeFocused();
  await page.keyboard.press('ControlOrMeta+A');
  await page.keyboard.insertText(value);
  await expect(input(page)).toHaveValue(value);
}
async function addTitleStep(page) {
  await page.keyboard.press('a');
  await expectPrompt(page, 'add', 'url');
  await replaceText(page, 'example.com');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'add', 'title');
}
async function addLocationStep(page) {
  await addTitleStep(page);
  await replaceText(page, '测试书签');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'add', 'location');
}
async function chooseNewFolder(page) {
  for (let i = 0; i < 6; i++) await page.keyboard.press('ArrowDown');
  await expect(input(page)).toHaveValue('新建文件夹…');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'add', 'folder');
}

for (const target of ['标题文字', '行内空白']) {
  test(`鼠标点击${target}选中 ChatGPT 后，e 编辑的是 ChatGPT`, async ({ page }) => {
    const title = svgText(page, 'ChatGPT');
    if (target === '标题文字') {
      await title.click();
    } else {
      const box = await title.locator('..').boundingBox();
      await page.mouse.click(box.x + box.width * 0.6, box.y + box.height / 2);
    }
    await page.keyboard.press('e');
    await expectPrompt(page, 'edit', 'title');
    await expect(input(page)).toHaveValue('ChatGPT');
    await replaceText(page, '已修改 ChatGPT');
    await page.keyboard.press('Enter');
    await expect(svgText(page, '已修改 ChatGPT')).toBeVisible();
    await expect(svgText(page, 'ChatGPT')).toHaveCount(0);
    await expect(svgText(page, 'GitHub')).toBeVisible();
  });
}

for (const key of ['e', 'm', 'a']) {
  test(`搜索后鼠标选中 GitHub，再按 ${key} 不应继续向搜索框输入`, async ({ page }) => {
    await page.keyboard.press('/');
    await replaceText(page, 'git');
    await expect(page.locator('svg text').filter({ hasText: /“git”/ })).toBeVisible();
    await svgText(page, 'GitHub').click();
    await page.keyboard.press(key);
    await expectPrompt(page, { e: 'edit', m: 'move', a: 'add' }[key], { e: 'title', m: 'to', a: 'url' }[key]);
    if (key === 'e') await expect(input(page)).toHaveValue('GitHub');
    if (key === 'm') {
      await page.keyboard.press('ArrowDown');
      await expect(input(page)).toHaveValue('开发工具');
      await page.keyboard.press('Enter');
      await page.keyboard.press('Escape');
      await svgText(page, '开发工具').dblclick();
      await expect(svgText(page, 'GitHub')).toBeVisible();
    }
  });
}

test('命令输入中点击书签后 e 应编辑所选项，不是继续输入命令', async ({ page }) => {
  await page.keyboard.press(':');
  await replaceText(page, 'op');
  await svgText(page, 'Google').click();
  await page.keyboard.press('e');
  await expectPrompt(page, 'edit', 'title');
  await expect(input(page)).toHaveValue('Google');
});


test('鼠标点击行内空白后 m 移动目标是 ChatGPT，不是初始项', async ({ page }) => {
  const box = await svgText(page, 'ChatGPT').locator('..').boundingBox();
  await page.mouse.click(box.x + box.width * 0.6, box.y + box.height / 2);
  await page.keyboard.press('m');
  await expectPrompt(page, 'move', 'to');
  await page.keyboard.press('ArrowDown');
  await expect(input(page)).toHaveValue('开发工具');
  await page.keyboard.press('Enter');
  await expect(svgText(page, 'ChatGPT')).toHaveCount(0);
  await expect(svgText(page, 'GitHub')).toBeVisible();
  await svgText(page, '开发工具').dblclick();
  await expect(svgText(page, 'ChatGPT')).toBeVisible();
  await expect(svgText(page, 'GitHub')).toHaveCount(0);
});

test('已在文本输入模式时 a/e/m 是文字，Esc 退出后再恢复快捷键', async ({ page }) => {
  await svgText(page, 'ChatGPT').click();
  await page.keyboard.press('e');
  await replaceText(page, '');
  await page.keyboard.type('aem');
  await expectPrompt(page, 'edit', 'title');
  await expect(input(page)).toHaveValue('aem');
  await page.keyboard.press('Escape');
  await page.keyboard.press('m');
  await expectPrompt(page, 'move', 'to');
});

test('新增标题中 Backspace 只删字，删空再连续按也不退回网址', async ({ page }) => {
  await addTitleStep(page);
  await replaceText(page, 'abc');
  await page.keyboard.press('ArrowLeft');
  await page.keyboard.press('Backspace');
  await expect(input(page)).toHaveValue('ac');
  await replaceText(page, '');
  await page.keyboard.press('Backspace');
  await page.keyboard.press('Backspace');
  await expectPrompt(page, 'add', 'title');
  await expect(input(page)).toHaveValue('');
});

test('新增位置输入删空或零结果后，候选可恢复且 Backspace 不切步骤', async ({ page }) => {
  await addLocationStep(page);
  await replaceText(page, '没有这个分组');
  await replaceText(page, '');
  await page.keyboard.press('Backspace');
  await expectPrompt(page, 'add', 'location');
  await page.keyboard.press('ArrowDown');
  await expect(input(page)).toHaveValue('开发工具');
});

test('新文件夹名称为空时 Backspace 不返回位置选择', async ({ page }) => {
  await addLocationStep(page);
  await chooseNewFolder(page);
  await page.keyboard.press('Backspace');
  await expectPrompt(page, 'add', 'folder');
  await expect(input(page)).toHaveValue('');
});

test('尚未按 Enter 的标题草稿在 Shift+Tab 返回网址后仍保留', async ({ page }) => {
  await addTitleStep(page);
  await replaceText(page, '尚未提交的标题');
  await page.keyboard.press('Shift+Tab');
  await expectPrompt(page, 'add', 'url');
  await replaceText(page, 'changed.example.com');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'add', 'title');
  await expect(input(page)).toHaveValue('尚未提交的标题');
});

test('已选分组回退修改标题后仍保持，最终新增到正确分组', async ({ page }) => {
  await addLocationStep(page);
  await page.keyboard.press('ArrowDown');
  await expect(input(page)).toHaveValue('开发工具');
  await page.keyboard.press('Shift+Tab');
  await expectPrompt(page, 'add', 'title');
  await replaceText(page, '回退后的书签');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'add', 'location');
  await expect(input(page)).toHaveValue('开发工具');
  await page.keyboard.press('Enter');
  await svgText(page, '开发工具').dblclick();
  await expect(svgText(page, '回退后的书签')).toBeVisible();
});

test('新文件夹未提交的名称在回退到位置再前进时保留', async ({ page }) => {
  await addLocationStep(page);
  await chooseNewFolder(page);
  await replaceText(page, '尚未提交的分组');
  await page.keyboard.press('Shift+Tab');
  await expectPrompt(page, 'add', 'location');
  await expect(input(page)).toHaveValue('新建文件夹…');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'add', 'folder');
  await expect(input(page)).toHaveValue('尚未提交的分组');
});

test('新建文件夹：n 点输入名称后创建并选中，出现在根目录列表', async ({ page }) => {
  await page.keyboard.press('n');
  await expectPrompt(page, 'mkdir', 'name');
  await replaceText(page, '收藏夹');
  await page.keyboard.press('Enter');
  await expect(svgText(page, '收藏夹')).toBeVisible();
  await expect(page.locator('svg text').filter({ hasText: /已创建文件夹 “收藏夹”/ })).toBeVisible();
});

test('新建文件夹：:mkdir 带名称直接创建，重名报错且不重复创建', async ({ page }) => {
  await page.keyboard.press(':');
  await replaceText(page, 'mkdir 新夹');
  await page.keyboard.press('Enter');
  await expect(svgText(page, '新夹')).toBeVisible();
  await page.keyboard.press(':');
  await replaceText(page, 'mkdir 新夹');
  await page.keyboard.press('Enter');
  await expect(page.locator('svg text').filter({ hasText: /已存在同名文件夹/ })).toBeVisible();
  await expect(svgText(page, '新夹')).toHaveCount(1);
});

test('移动时新建文件夹先询问名称，Shift+Tab 可返回，确认后移入新文件夹', async ({ page }) => {
  await svgText(page, 'ChatGPT').click();
  await page.keyboard.press('m');
  await expectPrompt(page, 'move', 'to');
  for (let i = 0; i < 6; i++) await page.keyboard.press('ArrowDown');
  await expect(input(page)).toHaveValue('新建文件夹…');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'move', 'name');
  await page.keyboard.press('Shift+Tab');
  await expectPrompt(page, 'move', 'to');
  await expect(input(page)).toHaveValue('新建文件夹…');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'move', 'name');
  await replaceText(page, '音乐');
  await page.keyboard.press('Enter');
  await expect(svgText(page, 'ChatGPT')).toHaveCount(0);
  await expect(svgText(page, '音乐')).toBeVisible();
  await svgText(page, '音乐').last().dblclick();
  await expect(svgText(page, 'ChatGPT')).toBeVisible();
});

test('移动候选导航到末项时，新建文件夹仍显示在候选区域', async ({ page }) => {
  await svgText(page, 'ChatGPT').click();
  await page.keyboard.press('m');
  await expectPrompt(page, 'move', 'to');
  for (let i = 0; i < 6; i++) await page.keyboard.press('ArrowDown');
  await expect(input(page)).toHaveValue('新建文件夹…');
  const completions = page.locator('svg text').filter({ hasText: /^PROMPT · MOVE/ }).locator('..');
  await expect(completions.locator('text').filter({ hasText: /^新建文件夹…$/ })).toBeVisible();
});

test('单页列表：首尾条目同屏可见，且没有翻页控件', async ({ page }) => {
  await expect(svgText(page, 'GitHub')).toBeVisible();
  await expect(svgText(page, 'Spotify')).toBeVisible();
  await expect(page.locator('svg text').filter({ hasText: /^翻页$/ })).toHaveCount(0);
  await expect(page.locator('svg text').filter({ hasText: /每页 \d+ 条/ })).toHaveCount(0);
  await svgText(page, 'Spotify').click();
  await page.keyboard.press('e');
  await expectPrompt(page, 'edit', 'title');
  await expect(input(page)).toHaveValue('Spotify');
});

test('提示流中点击其他行不重定向未提交草稿，结束输入后可重新选择', async ({ page }) => {
  await svgText(page, 'ChatGPT').click();
  await page.keyboard.press('e');
  await replaceText(page, '未提交修改');
  await svgText(page, 'Google').click();
  await expectPrompt(page, 'edit', 'title');
  await expect(input(page)).toHaveValue('未提交修改');
  await expect(input(page)).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(svgText(page, '未提交修改')).toBeVisible();
  await expect(svgText(page, 'Google')).toBeVisible();
  await svgText(page, 'Google').click();
  await page.keyboard.press('e');
  await expect(input(page)).toHaveValue('Google');
});

test('编辑双字段：e 可来回切换标题和网址，Enter 同时保存两项', async ({ page }) => {
  await svgText(page, 'ChatGPT').click();
  await page.keyboard.press('e');
  await replaceText(page, '工作助手');
  await page.keyboard.press('Tab');
  await expectPrompt(page, 'edit', 'url');
  await expect(input(page)).toHaveValue('https://chatgpt.com');
  await replaceText(page, 'assistant.example.com/work');
  await page.keyboard.press('Shift+Tab');
  await expectPrompt(page, 'edit', 'title');
  await expect(input(page)).toHaveValue('工作助手');
  await page.keyboard.press('Enter');
  await expect(svgText(page, '工作助手')).toBeVisible();
  await expect(svgText(page, 'assistant.example.com')).toBeVisible();
  await expect(svgText(page, 'GitHub')).toBeVisible();
  await svgText(page, '工作助手').click();
  await page.keyboard.press('e');
  await page.keyboard.press('Tab');
  await expect(input(page)).toHaveValue('https://assistant.example.com/work');
});

test('编辑双字段：Esc 不会保存切换字段时留下的草稿', async ({ page }) => {
  await page.keyboard.press('e');
  await replaceText(page, '临时标题');
  await page.keyboard.press('Tab');
  await expectPrompt(page, 'edit', 'url');
  await replaceText(page, 'cancel.example.com');
  await page.keyboard.press('Escape');
  await expect(svgText(page, '临时标题')).toHaveCount(0);
  await page.keyboard.press('e');
  await expect(input(page)).toHaveValue('GitHub');
  await page.keyboard.press('Tab');
  await expect(input(page)).toHaveValue('https://github.com');
});

test('编辑双字段：edit url 命令直接打开网址，仍可切换到标题', async ({ page }) => {
  await page.keyboard.press(':');
  await replaceText(page, 'edit url');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'edit', 'url');
  await replaceText(page, 'https://github.com/settings');
  await page.keyboard.press('Tab');
  await expectPrompt(page, 'edit', 'title');
  await expect(input(page)).toHaveValue('GitHub');
  await page.keyboard.press('Tab');
  await expect(input(page)).toHaveValue('https://github.com/settings');
});

for (const url of ['', 'ftp://example.com', 'https://']) {
  test(`编辑双字段：拒绝无效网址 ${JSON.stringify(url)}，不提前保存标题`, async ({ page }) => {
    await page.keyboard.press('e');
    await replaceText(page, '待保存标题');
    await page.keyboard.press('Tab');
    await expectPrompt(page, 'edit', 'url');
    await replaceText(page, url);
    await page.keyboard.press('Enter');
    await expectPrompt(page, 'edit', 'url');
    await expect(svgText(page, 'GitHub')).toBeVisible();
    await expect(svgText(page, '待保存标题')).toHaveCount(0);
    await replaceText(page, 'https://valid.example.com');
    await page.keyboard.press('Enter');
    await expect(svgText(page, '待保存标题')).toBeVisible();
    await expect(svgText(page, 'valid.example.com')).toBeVisible();
  });
}

async function expectAbove(first, second) {
  await expect.poll(async () => {
    const a = await first.boundingBox();
    const b = await second.boundingBox();
    return a && b ? a.y < b.y : false;
  }).toBe(true);
}

test('整理模式：只调整书签顺序，书签不能移到置顶文件夹之前', async ({ page }) => {
  await svgText(page, 'GitHub').click();
  await page.keyboard.press('o');
  await page.keyboard.press('Shift+ArrowUp');
  await expectAbove(svgText(page, '生活服务'), svgText(page, 'GitHub'));
  await expectAbove(svgText(page, 'GitHub'), svgText(page, 'ChatGPT'));
  await page.keyboard.press('Shift+ArrowDown');
  await expectAbove(svgText(page, 'ChatGPT'), svgText(page, 'GitHub'));
  await page.keyboard.press('o');
  await expectAbove(svgText(page, 'ChatGPT'), svgText(page, 'GitHub'));
  await page.keyboard.press('e');
  await expect(input(page)).toHaveValue('GitHub');
});

test('整理模式：文件夹位置固定，不出现排序整理的删除标记', async ({ page }) => {
  const folder = svgText(page, '设计灵感');
  await folder.click();
  await page.keyboard.press('o');
  for (const key of ['J', 'K', 'Shift+ArrowDown', 'Shift+ArrowUp']) await page.keyboard.press(key);
  await expectAbove(svgText(page, '开发工具'), folder);
  await expectAbove(folder, svgText(page, '资讯阅读'));
  await expect(folder.locator('..').locator('text').filter({ hasText: /^\[×\]$/ })).toHaveCount(0);
  await page.keyboard.press('Escape');
  await page.keyboard.press('r');
  await expect(input(page)).toHaveValue('设计灵感');
});

test('整理模式：文件夹内的添加入口不参与排序，书签排序独立保留', async ({ page }) => {
  await svgText(page, '开发工具').last().dblclick();
  await expect(svgText(page, 'MDN Web Docs')).toBeVisible();
  await page.keyboard.press('o');
  await page.keyboard.press('Shift+ArrowUp');
  await expectAbove(svgText(page, 'MDN Web Docs'), svgText(page, 'Stack Overflow'));
  await page.keyboard.press('Shift+ArrowDown');
  await expectAbove(svgText(page, 'Stack Overflow'), svgText(page, 'MDN Web Docs'));
  await page.keyboard.press('Escape');
  await page.keyboard.press('Escape');
  await svgText(page, '开发工具').last().dblclick();
  await expectAbove(svgText(page, 'Stack Overflow'), svgText(page, 'MDN Web Docs'));
});

test('整理模式：书签下移一位后选中项仍跟随该书签', async ({ page }) => {
  await svgText(page, 'Vercel').click();
  await page.keyboard.press('o');
  await page.keyboard.press('Shift+ArrowDown');
  await page.keyboard.press('Escape');
  await page.keyboard.press('e');
  await expect(input(page)).toHaveValue('Vercel');
});

test('整理模式：搜索结果不改变跨分组的原始排序', async ({ page }) => {
  await page.keyboard.press('/');
  await replaceText(page, 'git');
  await svgText(page, 'GitHub').click();
  await page.keyboard.press('o');
  await expect(page.locator('svg text').filter({ hasText: /搜索结果不能排序/ })).toBeVisible();
  await page.keyboard.press('Shift+ArrowDown');
  await page.keyboard.press('Escape');
  await expectAbove(svgText(page, 'GitHub'), svgText(page, 'ChatGPT'));
});

test('整理模式：点击未选中行的删除标记，目标必须是该行', async ({ page }) => {
  await page.keyboard.press('o');
  const row = svgText(page, 'ChatGPT').locator('..');
  await row.locator('text').filter({ hasText: /^\[×\]$/ }).click();
  await expectPrompt(page, 'delete', 'confirm');
  await expect(page.locator('svg text').filter({ hasText: /删除“ChatGPT”？/ }).first()).toBeVisible();
  await page.keyboard.press('y');
  await expect(svgText(page, 'ChatGPT')).toHaveCount(0);
  await expect(svgText(page, 'GitHub')).toBeVisible();
});

test('退格编辑：进入标题后 Backspace 只删除末尾一字', async ({ page }) => {
  await page.keyboard.press('e');
  await expectPrompt(page, 'edit', 'title');
  await page.keyboard.press('Backspace');
  await expect(input(page)).toHaveValue('GitHu');
  await page.keyboard.press('Enter');
  await expect(svgText(page, 'GitHu')).toBeVisible();
  await expect(svgText(page, 'GitHub')).toHaveCount(0);
});

test('退格编辑：Tab 切到网址可逐字退格，返回标题也不全选', async ({ page }) => {
  await page.keyboard.press('e');
  await page.keyboard.press('Tab');
  await expectPrompt(page, 'edit', 'url');
  await page.keyboard.press('Backspace');
  await expect(input(page)).toHaveValue('https://github.co');
  await page.keyboard.press('Shift+Tab');
  await expectPrompt(page, 'edit', 'title');
  await page.keyboard.press('Backspace');
  await expect(input(page)).toHaveValue('GitHu');
  await page.keyboard.press('Tab');
  await expect(input(page)).toHaveValue('https://github.co');
  await page.keyboard.press('Enter');
  await expect(svgText(page, 'GitHu')).toBeVisible();
  await expect(svgText(page, 'github.co')).toBeVisible();
});

test('退格编辑：修改草稿后切换回原字段，继续从末尾删除', async ({ page }) => {
  await page.keyboard.press('e');
  await replaceText(page, '新的标题');
  await page.keyboard.press('Tab');
  await expectPrompt(page, 'edit', 'url');
  await replaceText(page, 'https://example.com/path');
  await page.keyboard.press('Shift+Tab');
  await page.keyboard.press('Backspace');
  await expect(input(page)).toHaveValue('新的标');
  await page.keyboard.press('Tab');
  await page.keyboard.press('Backspace');
  await expect(input(page)).toHaveValue('https://example.com/pat');
  await page.keyboard.press('Enter');
  await expect(svgText(page, '新的标')).toBeVisible();
  await expect(svgText(page, 'example.com')).toBeVisible();
});

test('退格编辑：方向键定位到中间后删除光标前一个字符', async ({ page }) => {
  await page.keyboard.press('e');
  await expectPrompt(page, 'edit', 'title');
  await page.keyboard.press('ArrowLeft');
  await page.keyboard.press('Backspace');
  await expect(input(page)).toHaveValue('GitHb');
  await page.keyboard.press('Enter');
  await expect(svgText(page, 'GitHb')).toBeVisible();
});

test('退格编辑：中文书签名称同样按字符删除', async ({ page }) => {
  await svgText(page, '资讯阅读').dblclick();
  await svgText(page, '少数派').click();
  await page.keyboard.press('e');
  await expectPrompt(page, 'edit', 'title');
  await page.keyboard.press('Backspace');
  await expect(input(page)).toHaveValue('少数');
  await page.keyboard.press('Enter');
  await expect(svgText(page, '少数')).toBeVisible();
});

test('退格编辑：只有显式全选后才删除全部，空标题不提前保存', async ({ page }) => {
  await page.keyboard.press('e');
  await expectPrompt(page, 'edit', 'title');
  await page.keyboard.press('ControlOrMeta+A');
  await page.keyboard.press('Backspace');
  await expect(input(page)).toHaveValue('');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'edit', 'title');
  await expect(input(page)).toHaveValue('');
  await expect(svgText(page, 'GitHub')).toBeVisible();
});

test('退格编辑：新增预填标题与回退到网址时不暗中全选', async ({ page }) => {
  await addTitleStep(page);
  await page.keyboard.press('Backspace');
  await expect(input(page)).toHaveValue('example.co');
  await page.keyboard.press('Shift+Tab');
  await expectPrompt(page, 'add', 'url');
  await page.keyboard.press('Backspace');
  await expect(input(page)).toHaveValue('https://example.co');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'add', 'title');
  await expect(input(page)).toHaveValue('example.co');
});

test('退格编辑：重命名文件夹时保留未删除的名称', async ({ page }) => {
  await svgText(page, '开发工具').last().click();
  await page.keyboard.press('r');
  await expectPrompt(page, 'rename', 'name');
  await page.keyboard.press('Backspace');
  await expect(input(page)).toHaveValue('开发工');
  await page.keyboard.press('Enter');
  await expect(svgText(page, '开发工').last()).toBeVisible();
  await expect(svgText(page, '开发工具')).toHaveCount(0);
});

test('文件夹内左上角显示面包屑，点根目录可返回', async ({ page }) => {
  await svgText(page, '开发工具').dblclick();
  await expect(svgText(page, 'MDN Web Docs')).toBeVisible();
  const crumb = page.locator('svg text').filter({ hasText: /^根目录$/ });
  await expect(crumb).toHaveCount(1);
  await expect(crumb).toBeVisible();
  await expect(page.locator('svg text').filter({ hasText: /^开发工具$/ })).toHaveCount(1);
  await crumb.click();
  await expect(svgText(page, 'GitHub')).toBeVisible();
  await expect(page.locator('svg text').filter({ hasText: /^根目录$/ })).toHaveCount(0);
});

test('单列表：文件夹全部置顶，列表铺满原侧栏区域', async ({ page }) => {
  for (const name of ['开发工具', '设计灵感', '资讯阅读', '影音娱乐', '生活服务']) {
    await expect(svgText(page, name)).toHaveCount(1);
    await expectAbove(svgText(page, name), svgText(page, 'GitHub'));
    await expectAbove(svgText(page, name), svgText(page, 'ChatGPT'));
  }
  const board = await page.locator('svg.board').boundingBox();
  const row = await svgText(page, 'GitHub').locator('..').boundingBox();
  expect(row.x - board.x).toBeLessThan(board.width * 0.1);
  expect(row.width).toBeGreaterThan(board.width * 0.9);
});

test('单列表：方向键与 Enter 进入文件夹，Esc 返回根目录', async ({ page }) => {
  await page.keyboard.press('g');
  await page.keyboard.press('Enter');
  await expect(svgText(page, 'MDN Web Docs')).toBeVisible();
  await expect(svgText(page, 'GitHub')).toHaveCount(0);
  await page.keyboard.press('Escape');
  await expect(svgText(page, 'GitHub')).toBeVisible();
  await page.keyboard.press('j');
  await page.keyboard.press('Enter');
  await expect(svgText(page, 'Dribbble')).toBeVisible();
});

test('单列表：数字键不切文件夹、不打开书签、不改变选中项', async ({ page }) => {
  await svgText(page, 'ChatGPT').click();
  for (const key of '0123456789') await page.keyboard.press(key);
  await expect(svgText(page, 'GitHub')).toBeVisible();
  await expect(page.locator('svg text').filter({ hasText: /^✓ 已打开 / })).toHaveCount(0);
  await page.keyboard.press('e');
  await expect(input(page)).toHaveValue('ChatGPT');
});

test('设置缓冲区：单字母不改设置、不启动任务、不触发主列表动作', async ({ page }) => {
  await page.keyboard.press(',');
  const values = page.locator('svg text').filter({ hasText: /^(login|hotkey|corner|finder|file)$/ })
    .locator('..').locator('text:nth-of-type(4)');
  const before = await values.allTextContents();
  for (const key of ['l', 'h', 'r', 'c', 'C', 'p', 'b', 'R', 'd', 'a', 'e', 'm']) {
    await page.keyboard.press(key);
    await expect(svgText(page, '[settings]')).toBeVisible();
    await expect(svgText(page, 'PROMPT')).toHaveCount(0);
    await expect(values).toHaveText(before);
  }
  await page.keyboard.press('Escape');
  await expect(svgText(page, 'GitHub')).toBeVisible();
});

test('设置缓冲区：英文角落可设置，非法值不覆盖当前角落', async ({ page }) => {
  await page.keyboard.press(',');
  for (const value of ['right-up', 'right-down', 'left-down', 'left-up']) {
    await page.keyboard.press(':');
    await page.keyboard.insertText(`set corner ${value}`);
    await page.keyboard.press('Enter');
    await expect(svgText(page, value)).toBeVisible();
  }
  await page.keyboard.press(':');
  await page.keyboard.insertText('set corner nowhere');
  await page.keyboard.press('Enter');
  await expect(svgText(page, 'left-up')).toBeVisible();
  await page.keyboard.press(':');
  await page.keyboard.insertText('log');
  await page.keyboard.press('Enter');
  await expect(page.locator('svg text').filter({ hasText: /✗ corner/ })).toBeVisible();
});

test('设置命令：录入组合键后可保存，取消再次录入保留原绑定', async ({ page }) => {
  await page.keyboard.press(',');
  await page.keyboard.press(':');
  await page.keyboard.insertText('set hotkey record');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'hotkey', 'press keys');
  await page.keyboard.press('Control+k');
  await expect(svgText(page, 'Ctrl+K')).toBeVisible();
  await expect(svgText(page, 'PROMPT')).toHaveCount(0);
  await page.keyboard.press(':');
  await page.keyboard.insertText('set hotkey record');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'hotkey', 'press keys');
  await page.keyboard.press('Escape');
  await expect(svgText(page, 'Ctrl+K')).toBeVisible();
});

test('单列表：命令行字段中的数字正常输入，不作为导航键', async ({ page }) => {
  await page.keyboard.press('a');
  await expectPrompt(page, 'add', 'url');
  await page.keyboard.type('https://example.com/1234567890');
  await expect(input(page)).toHaveValue('https://example.com/1234567890');
  await page.keyboard.press('Enter');
  await expectPrompt(page, 'add', 'title');
  await replaceText(page, '1234567890');
  await expectPrompt(page, 'add', 'title');
});
