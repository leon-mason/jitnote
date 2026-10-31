// @vitest-environment jsdom
// Opening and saving a note must not change what the user did not touch. People bring notes
// from Obsidian / Typora, so their syntax has to survive the WYSIWYG round trip byte for byte.
import { beforeAll, describe, expect, it } from 'vitest'

let editor

beforeAll(async () => {
  document.body.innerHTML = '<div id="editor"></div><nav id="toolbar" hidden></nav>'
  // jsdom lacks a few layout APIs ProseMirror probes for.
  document.elementFromPoint = () => null
  Range.prototype.getClientRects = () => []
  Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 })
  await import('../src/main.js')
  editor = window.GitNotebookEditor
})

async function roundTrip(markdown) {
  await editor.load(markdown, {})
  return editor.getMarkdown()
}

const unchanged = {
  'front matter': '---\ntags: [demo]\n---\n# 标题\n',
  'wiki links': '见 [[读书笔记]] 和 [[项目/计划|计划]]。\n',
  embeds: '![[图片.png]]\n',
  tags: '#读书 #待整理\n\n正文 #标签 在中间。\n',
  callouts: '> [!tip] 提醒\n> 每天读 30 分钟\n',
  highlights: '- ==重点== 内容\n\n==开头高亮== 段落\n',
  'plain brackets': '数组 a[0] 和 [备注] 普通括号\n',
  'brackets with footnotes': '数组 a[0]\n\n脚注[^1]\n\n[^1]: 内容\n',
  'image alt text': '![猫](assets/cat.png)\n',
  'dash lists and tasks': '- 一\n  - 一点一\n- [ ] 待办\n- [x] 完成\n',
  dividers: '---\n\n文字\n',
  'aligned table': '| 书名     | 进度 |\n| -------- | ---- |\n| 人类简史 | 50%  |\n',
  'links and code': '[百度](https://baidu.com)\n\n```js\nconst a = 1\n```\n',
}

describe('round trip', () => {
  for (const [name, markdown] of Object.entries(unchanged)) {
    it(`keeps ${name}`, async () => {
      expect(await roundTrip(markdown)).toBe(markdown)
    })
  }

  it('still escapes text that would otherwise become a link', async () => {
    const markdown = '见 [官网]。\n\n[官网]: https://example.com\n'
    expect(await roundTrip('字面 \\[不是链接](真的)\n')).not.toContain('[不是链接](真的)')
    expect(await roundTrip(markdown)).toContain('https://example.com')
  })
})
