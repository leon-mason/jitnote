// @vitest-environment jsdom
// The host can flip a loaded note between editing and read-only without reloading it.
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
  // jsdom lacks a few layout APIs ProseMirror probes for.
  document.elementFromPoint = () => null
  Range.prototype.getClientRects = () => []
  Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 })
  await import('../src/main.js')
  editor = window.JitnoteEditor
})

describe('setReadonly', () => {
  it('setReadonlyTogglesEditingAndToolbar', async () => {
    await editor.load('正文\n', {})
    editor.setReadonly(true)
    expect(document.querySelector('#toolbar').hidden).toBe(true)
    expect(document.body.classList.contains('with-toolbar')).toBe(false)
    expect(document.querySelector('.ProseMirror').getAttribute('contenteditable')).toBe('false')
    editor.setReadonly(false)
    expect(document.querySelector('#toolbar').hidden).toBe(false)
    expect(document.body.classList.contains('with-toolbar')).toBe(true)
  })

  it('setReadonlyDuringLoadWins', async () => {
    const loading = editor.load('正文\n', { readonly: false })
    editor.setReadonly(true)
    await loading
    expect(document.querySelector('#toolbar').hidden).toBe(true)
    expect(document.querySelector('.ProseMirror').getAttribute('contenteditable')).toBe('false')
  })

  it('editJustBeforePreviewIsStillSaved', async () => {
    await editor.load('正文\n', {})
    changes.length = 0
    document.querySelector('#toolbar button').click() // the first button, 标题, changes the document
    editor.setReadonly(true)
    await new Promise((resolve) => setTimeout(resolve, 1000))
    expect(changes.at(-1)).toContain('## 正文')
  })
})
