// GitNotebook note editor: a WYSIWYG view over a plain Markdown file.
//
// Host contract (Android today, other clients later):
//   host → editor   window.GitNotebookEditor.load(markdown, { readonly, baseUrl })
//                   window.GitNotebookEditor.getMarkdown()  → current Markdown
//   editor → host   window.GitNotebookHost.onReady()
//                   window.GitNotebookHost.onChange(markdown)   (debounced, only after real edits)
// Without a host (e.g. `npm run dev` in a browser) a sample note is loaded.

import { CrepeBuilder } from '@milkdown/crepe/builder'
import { cursor } from '@milkdown/crepe/feature/cursor'
import { imageBlock } from '@milkdown/crepe/feature/image-block'
import { linkTooltip } from '@milkdown/crepe/feature/link-tooltip'
import { listItem } from '@milkdown/crepe/feature/list-item'
import { placeholder } from '@milkdown/crepe/feature/placeholder'
import { table } from '@milkdown/crepe/feature/table'
import { toolbar as selectionToolbar } from '@milkdown/crepe/feature/toolbar'
import { commandsCtx, editorViewCtx, remarkStringifyOptionsCtx } from '@milkdown/kit/core'
import { redoCommand, undoCommand } from '@milkdown/kit/plugin/history'
import {
  blockquoteSchema,
  bulletListSchema,
  headingSchema,
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
import '@milkdown/crepe/theme/common/image-block.css'
import '@milkdown/crepe/theme/common/link-tooltip.css'
import '@milkdown/crepe/theme/common/list-item.css'
import '@milkdown/crepe/theme/common/placeholder.css'
import '@milkdown/crepe/theme/common/table.css'
import '@milkdown/crepe/theme/common/toolbar.css'
import './style.css'

const host = window.GitNotebookHost
const root = document.getElementById('editor')
const toolbar = document.getElementById('toolbar')

let crepe = null
// YAML front matter is not part of CommonMark; keep it aside so it survives untouched.
let frontMatter = ''
// Folder of the note, so relative image paths (e.g. assets/2026-10/a.webp) load from the notebook.
let baseUrl = document.baseURI
let changeTimer = null

function splitFrontMatter(markdown) {
  const match = /^---\r?\n[\s\S]*?\r?\n---\r?\n/.exec(markdown)
  return match ? [match[0], markdown.slice(match[0].length)] : ['', markdown]
}

function resolveImage(url) {
  if (!url || /^[a-z][a-z0-9+.-]*:/i.test(url)) return url
  try {
    return new URL(url, baseUrl).href
  } catch {
    return url
  }
}

function getMarkdown() {
  return crepe ? frontMatter + crepe.getMarkdown() : ''
}

function emitChange() {
  clearTimeout(changeTimer)
  changeTimer = setTimeout(() => host?.onChange(getMarkdown()), 400)
}

async function load(markdown, options = {}) {
  // Not a <base> tag: that would also re-resolve the editor's own stylesheet.
  baseUrl = options.baseUrl ?? document.baseURI
  const [front, body] = splitFrontMatter(markdown ?? '')
  frontMatter = front
  if (crepe) await crepe.destroy()
  root.innerHTML = ''

  crepe = new CrepeBuilder({ root, defaultValue: body })
    .addFeature(cursor)
    .addFeature(listItem)
    .addFeature(linkTooltip, { inputPlaceholder: '粘贴网址，回车确认' })
    .addFeature(imageBlock, {
      proxyDomURL: resolveImage,
      blockCaptionPlaceholderText: '图片说明',
      blockUploadPlaceholderText: '或粘贴图片网址',
      inlineUploadPlaceholderText: '或粘贴图片网址',
      blockConfirmButton: '确定',
      blockUploadButton: '选择图片',
      inlineUploadButton: '选择图片',
    })
    .addFeature(placeholder, { text: '从这里开始写…', mode: 'doc' })
    .addFeature(table)
    .addFeature(selectionToolbar)
  // Write lists the way most editors (Obsidian, Typora, GitHub) do, so files don't churn.
  crepe.editor.config((ctx) => {
    ctx.update(remarkStringifyOptionsCtx, (prev) => ({ ...prev, bullet: '-' }))
  })
  crepe.on((listener) => {
    listener.markdownUpdated((_ctx, next, prev) => {
      if (next !== prev) emitChange()
    })
  })
  await crepe.create()
  crepe.setReadonly(Boolean(options.readonly))
  toolbar.hidden = Boolean(options.readonly)
  document.body.classList.toggle('with-toolbar', !options.readonly)
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

window.GitNotebookEditor = { load, getMarkdown }

if (host) {
  host.onReady()
} else {
  load('# 示例笔记\n\n这是 **GitNotebook** 的编辑器。\n\n- [ ] 买牛奶\n- [x] 写日记\n\n> 引用一段话\n')
}
