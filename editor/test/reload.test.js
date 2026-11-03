// @vitest-environment jsdom
// The host can load another text into an open editor (a note changed on disk behind the app's back).
// A change waiting to be reported belongs to the text that is being replaced; reporting it afterwards
// would hand the host the new text as if the user had edited it, and the app would rewrite the file.
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

describe('load', () => {
  it('reloadingDropsTheChangeWaitingForTheOldText', async () => {
    await editor.load('正文\n', {})
    changes.length = 0
    document.querySelector('#toolbar button').click() // the first button, 标题, changes the document
    // Wait until the editor has noticed the edit and queued its report (it first debounces on its own).
    await new Promise((resolve) => setTimeout(resolve, 350))
    await editor.load('在别处改过\n', {})
    await new Promise((resolve) => setTimeout(resolve, 1000))
    expect(changes).toEqual([])
    expect(editor.getMarkdown()).toContain('在别处改过')
  })
})
