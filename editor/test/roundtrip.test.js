// @vitest-environment jsdom
// Opening and saving a note must not change what the user did not touch. People bring notes
// from Obsidian / Typora, so their syntax has to survive the WYSIWYG round trip byte for byte.
import { beforeAll, describe, expect, it } from 'vitest'

let editor
const files = { 'assets/cat.png': 'notes/assets/cat.png', '封面.png': '附件/封面.png', '附件/封面.png': '附件/封面.png' }
const opened = []

beforeAll(async () => {
  document.body.innerHTML = '<div id="editor"></div><nav id="toolbar" hidden></nav>'
  window.GitNotebookHost = {
    onReady() {},
    onChange() {},
    resolveFile: (path) => files[path] ?? '',
    openImage: (path) => opened.push(path),
  }
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
  'image embeds': '![[封面.png]]\n\n带宽度：![[封面.png|120]] 和 ![[a.jpg|300x200]] 文字\n',
  'note embeds': '![[另一篇笔记]]\n',
}

describe('images', () => {
  const options = { baseUrl: 'https://app.test/notebook/notes/', notebookUrl: 'https://app.test/notebook/' }

  it('loads images the host can find from the notebook, tagged for tapping', async () => {
    await editor.load('![猫](assets/cat.png)\n\n![[封面.png|120]]\n', options)
    const [cat, cover] = document.querySelectorAll('.milkdown img[data-gn-path]')
    expect(cat.getAttribute('src')).toBe('https://app.test/notebook/notes/assets/cat.png')
    expect(cover.getAttribute('src')).toBe(`https://app.test/notebook/${encodeURIComponent('附件')}/${encodeURIComponent('封面.png')}`)
    expect(cover.style.width).toBe('120px')
    cover.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(opened).toContain('附件/封面.png')
  })

  it('falls back to the note folder for files the host does not know', async () => {
    await editor.load('![x](missing.png)\n', options)
    const image = [...document.querySelectorAll('.milkdown img')].find((img) => img.alt === 'x')
    expect(image.getAttribute('src')).toBe('https://app.test/notebook/notes/missing.png')
    expect(image.hasAttribute('data-gn-path')).toBe(false)
  })
})

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
