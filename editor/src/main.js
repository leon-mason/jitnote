// Jitnote note editor: a WYSIWYG view over a plain Markdown file.
//
// Host contract (Android today, other clients later):
//   host → editor   window.JitnoteEditor.load(markdown, { readonly, baseUrl, notebookUrl })
//                   window.JitnoteEditor.getMarkdown()  → current Markdown
//                   window.JitnoteEditor.setReadonly(readonly)  → switch editing / read-only without reloading
//   editor → host   window.JitnoteHost.onReady()
//                   window.JitnoteHost.onChange(markdown)   (debounced, only after real edits)
//                   window.JitnoteHost.resolveFile(path)    → notebook-relative path or "" (sync)
//                   window.JitnoteHost.openImage(path)      (user tapped an image)
// Without a host (e.g. `npm run dev` in a browser) a sample note is loaded.

import { CrepeBuilder } from '@milkdown/crepe/builder'
import { cursor } from '@milkdown/crepe/feature/cursor'
import { linkTooltip } from '@milkdown/crepe/feature/link-tooltip'
import { listItem } from '@milkdown/crepe/feature/list-item'
import { placeholder } from '@milkdown/crepe/feature/placeholder'
import { table } from '@milkdown/crepe/feature/table'
import { toolbar as selectionToolbar } from '@milkdown/crepe/feature/toolbar'
import { commandsCtx, editorViewCtx, remarkStringifyOptionsCtx } from '@milkdown/kit/core'
import { redoCommand, undoCommand } from '@milkdown/kit/plugin/history'
import { remarkGFMPlugin } from '@milkdown/kit/preset/gfm'
import {
  blockquoteSchema,
  bulletListSchema,
  headingSchema,
  imageSchema,
  listItemSchema,
  orderedListSchema,
  paragraphSchema,
  setBlockTypeCommand,
  toggleStrongCommand,
  wrapInBlockTypeCommand,
} from '@milkdown/kit/preset/commonmark'
// Only the pieces of Crepe a note needs; the full bundle adds math fonts, a code editor and AI (~3 MB).
import '@milkdown/crepe/theme/common/prosemirror.css'
import '@milkdown/crepe/theme/common/reset.css'
import '@milkdown/crepe/theme/common/cursor.css'
import '@milkdown/crepe/theme/common/link-tooltip.css'
import '@milkdown/crepe/theme/common/list-item.css'
import '@milkdown/crepe/theme/common/placeholder.css'
import '@milkdown/crepe/theme/common/table.css'
import '@milkdown/crepe/theme/common/toolbar.css'
import './style.css'
import { createImageSupport } from './images.js'

const host = window.JitnoteHost
const root = document.getElementById('editor')
const toolbar = document.getElementById('toolbar')

const images = createImageSupport(host)
images.handleTaps(root)

let crepe = null
// YAML front matter is not part of CommonMark; keep it aside so it survives untouched.
let frontMatter = ''
let changeTimer = null
// The latest read-only wish from the host; applied once the editor exists, and again on every change.
let wantReadonly = false
let created = false

function splitFrontMatter(markdown) {
  const match = /^---\r?\n[\s\S]*?\r?\n---\r?\n/.exec(markdown)
  return match ? [match[0], markdown.slice(match[0].length)] : ['', markdown]
}

/**
 * The CommonMark serializer escapes syntax it does not know. Undo that for the Obsidian
 * extensions people commonly have in their notes, so saving never breaks them:
 * [[wiki links]], ![[embeds]], > [!callouts] and #tags at the start of a line.
 */
function restoreObsidianSyntax(markdown) {
  let result = markdown
    .replace(/(!?)\\\[\\\[/g, '$1[[')
    .replace(/^((?:[ \t]*>[ \t]?)+)\\\[!/gm, '$1[!')
    .replace(/^([ \t]*)\\#(?=[^\s#])/gm, '$1#')
    // ==highlight== at the start of a line or list item: only a line of nothing but "=" is special.
    .replace(/^((?:[ \t]*(?:[-*+]|\d+[.)]|>)[ \t]+)*[ \t]*)\\=(?=[^\n]*[^=\s])/gm, '$1=')
  // Plain brackets like a[0] or [备注] cannot become links unless the note defines link
  // references ("[x]: url"; footnotes "[^1]:" don't count), so their escapes are just noise.
  if (!/^ {0,3}\[(?!\^)[^\]\n]+\]:/m.test(result)) {
    result = result.replace(/\\\[([^[\]\n]*)\](?![([:])/g, '[$1]')
  }
  return result
}

/** Width as shown in a monospace font: CJK and full-width characters take two columns. */
function displayWidth(text) {
  let width = 0
  for (const char of text) {
    width += /[\u1100-\u115f\u2e80-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60\uffe0-\uffe6]/.test(char) ? 2 : 1
  }
  return width
}

function getMarkdown() {
  return crepe ? frontMatter + restoreObsidianSyntax(crepe.getMarkdown()) : ''
}

function emitChange() {
  clearTimeout(changeTimer)
  changeTimer = setTimeout(() => host?.onChange(getMarkdown()), 400)
}

function applyReadonly() {
  if (created) crepe.setReadonly(wantReadonly)
  toolbar.hidden = wantReadonly
  document.body.classList.toggle('with-toolbar', !wantReadonly)
  // Drop focus so the on-screen keyboard closes and no caret is left in a read-only note.
  if (wantReadonly) document.activeElement?.blur?.()
}

function setReadonly(readonly) {
  wantReadonly = Boolean(readonly)
  applyReadonly()
}

async function load(markdown, options = {}) {
  wantReadonly = Boolean(options.readonly)
  created = false
  // Not a <base> tag: that would also re-resolve the editor's own stylesheet.
  images.configure(options)
  const [front, body] = splitFrontMatter(markdown ?? '')
  frontMatter = front
  if (crepe) await crepe.destroy()
  root.innerHTML = ''

  crepe = new CrepeBuilder({ root, defaultValue: body })
    .addFeature(cursor)
    .addFeature(listItem)
    .addFeature(linkTooltip, { inputPlaceholder: '粘贴网址，回车确认' })
    .addFeature(placeholder, { text: '从这里开始写…', mode: 'doc' })
    .addFeature(table)
    .addFeature(selectionToolbar)
  crepe.editor.config((ctx) => {
    // Write lists and dividers the way most editors (Obsidian, Typora, GitHub) do, so files don't churn.
    ctx.update(remarkStringifyOptionsCtx, (prev) => ({ ...prev, bullet: '-', rule: '-' }))
    // Align table columns by display width, so Chinese tables line up in desktop editors too.
    ctx.set(remarkGFMPlugin.options.key, { stringLength: displayWidth })
    // Show images from the notebook without touching the stored path.
    // (Crepe's image-block feature is not used: it rewrites the alt text into a size ratio.)
    ctx.update(imageSchema.key, (prev) => (schemaCtx) => {
      const schema = prev(schemaCtx)
      return {
        ...schema,
        toDOM: (node) => {
          const [tag, attrs] = schema.toDOM(node)
          return [tag, { ...attrs, ...images.imageAttrs(node.attrs.src) }]
        },
      }
    })
  })
  crepe.editor.use(images.plugins)
  crepe.on((listener) => {
    listener.markdownUpdated((_ctx, next, prev) => {
      if (next !== prev) emitChange()
    })
  })
  await crepe.create()
  created = true
  applyReadonly()
}

function fitToWindow() {
  document.documentElement.style.setProperty('--app-height', `${window.innerHeight}px`)
}
window.addEventListener('resize', fitToWindow)
fitToWindow()

// ------------------------------------------------------------------ toolbar

function run(action) {
  if (!crepe || crepe.readonly) return
  crepe.editor.action((ctx) => {
    action(ctx, ctx.get(commandsCtx))
    ctx.get(editorViewCtx).focus()
  })
}

function currentBlock(ctx) {
  return ctx.get(editorViewCtx).state.selection.$from.parent
}

const buttons = [
  {
    label: '标题',
    icon: '<path d="M6 4v16M18 4v16M6 12h12"/>',
    run: () =>
      run((ctx, commands) => {
        const isHeading = currentBlock(ctx).type === headingSchema.type(ctx)
        commands.call(setBlockTypeCommand.key, isHeading
          ? { nodeType: paragraphSchema.type(ctx) }
          : { nodeType: headingSchema.type(ctx), attrs: { level: 2 } })
      }),
  },
  {
    label: '加粗',
    icon: '<path d="M7 4h6a4 4 0 0 1 0 8H7zM7 12h7a4 4 0 0 1 0 8H7z"/>',
    run: () => run((_ctx, commands) => commands.call(toggleStrongCommand.key)),
  },
  {
    label: '列表',
    icon: '<path d="M9 6h11M9 12h11M9 18h11"/><circle cx="4.5" cy="6" r="1"/><circle cx="4.5" cy="12" r="1"/><circle cx="4.5" cy="18" r="1"/>',
    run: () => run((ctx, commands) => commands.call(wrapInBlockTypeCommand.key, { nodeType: bulletListSchema.type(ctx) })),
  },
  {
    label: '编号',
    icon: '<path d="M10 6h10M10 12h10M10 18h10M4 5l1.5-1v5M3.5 14.5a1.5 1.5 0 1 1 2.6 1L4 18h2.5"/>',
    run: () => run((ctx, commands) => commands.call(wrapInBlockTypeCommand.key, { nodeType: orderedListSchema.type(ctx) })),
  },
  {
    label: '待办',
    icon: '<rect x="3.5" y="4" width="16" height="16" rx="3"/><path d="M8 12l3 3 5-6"/>',
    run: () =>
      run((ctx, commands) =>
        commands.call(wrapInBlockTypeCommand.key, { nodeType: listItemSchema.type(ctx), attrs: { checked: false } })),
  },
  {
    label: '引用',
    icon: '<path d="M5 6v12M10 8h9M10 12h9M10 16h6"/>',
    run: () => run((ctx, commands) => commands.call(wrapInBlockTypeCommand.key, { nodeType: blockquoteSchema.type(ctx) })),
  },
  {
    label: '撤销',
    icon: '<path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>',
    run: () => run((_ctx, commands) => commands.call(undoCommand.key)),
  },
  {
    label: '重做',
    icon: '<path d="M15 14l5-5-5-5"/><path d="M20 9H10a6 6 0 0 0 0 12h3"/>',
    run: () => run((_ctx, commands) => commands.call(redoCommand.key)),
  },
]

for (const button of buttons) {
  const el = document.createElement('button')
  el.type = 'button'
  el.innerHTML =
    `<svg viewBox="0 0 24 24" aria-hidden="true">${button.icon}</svg><span>${button.label}</span>`
  // Keep focus (and the keyboard) in the editor while tapping toolbar buttons.
  el.addEventListener('mousedown', (e) => e.preventDefault())
  el.addEventListener('touchstart', (e) => {
    e.preventDefault()
    button.run()
  }, { passive: false })
  el.addEventListener('click', button.run)
  toolbar.append(el)
}

// ------------------------------------------------------------------ host bridge

window.JitnoteEditor = { load, getMarkdown, setReadonly }

if (host) {
  host.onReady()
} else {
  load('# 示例笔记\n\n这是 **Jitnote** 的编辑器。\n\n- [ ] 买牛奶\n- [x] 写日记\n\n> 引用一段话\n')
}
