// @vitest-environment jsdom
// The preview outline reads headings from the loaded note and scrolls to one without editing it.
import { beforeAll, describe, expect, it } from 'vitest'

let editor
const changes = []

beforeAll(async () => {
  document.body.innerHTML = '<div id="editor"></div><nav id="toolbar" hidden></nav>'
  window.JitnoteHost = {
    onReady() {},
    onChange: (markdown) => changes.push(markdown),
    resolveFile: () => '',
    openImage() {},
  }
  document.elementFromPoint = () => null
  Range.prototype.getClientRects = () => []
  Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 })
  await import('../src/main.js')
  editor = window.JitnoteEditor
})

describe('headings', () => {
  it('isNullUntilTheNoteHasLoaded', async () => {
    const loading = editor.load('# 稍等\n', { readonly: true })
    expect(editor.headings()).toBe(null)
    await loading
    expect(editor.headings()).toEqual([{ level: 1, text: '稍等' }])
  })

  it('listsHeadingsInOrderAndSkipsWhatIsNotAHeading', async () => {
    await editor.load(
      [
        '---',
        'title: 不是标题',
        '---',
        '# 一',
        '',
        '正文',
        '',
        '## 二',
        '',
        '```',
        '# 代码里的井号',
        '```',
        '',
        '### ',
        '',
        '小标题',
        '====',
        '',
      ].join('\n'),
      { readonly: true },
    )
    expect(editor.headings()).toEqual([
      { level: 1, text: '一' },
      { level: 2, text: '二' },
      { level: 3, text: '' },
      { level: 1, text: '小标题' },
    ])
  })

  it('scrollsToThatHeadingWithoutEditing', async () => {
    await editor.load('# 标题\n\n正文\n\n## 下一节\n', { readonly: true })
    changes.length = 0
    let scrolled = null
    HTMLElement.prototype.scrollIntoView = function scrollIntoView() {
      scrolled = this
    }
    editor.scrollToHeading(1)
    expect(scrolled?.tagName).toBe('H2')
    expect(scrolled?.textContent).toBe('下一节')
    await new Promise((resolve) => setTimeout(resolve, 500))
    expect(changes).toEqual([])
  })
})
