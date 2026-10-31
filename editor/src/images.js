// Images inside notes.
//
// Notes come from many editors, which point at images differently:
//   Typora / VS Code   ![猫](assets/cat.png)            relative to the note
//   Obsidian            ![猫](附件/cat.png)              relative to the notebook root
//   Obsidian            ![[cat.png]]  ![[cat.png|300]]   just a file name, found anywhere
// The host knows the files, so it resolves a path to "notebook-relative path or nothing"
// (GitNotebookHost.resolveFile); the editor only ever displays, never rewrites, the reference.

import { $nodeSchema, $remark } from '@milkdown/kit/utils'

const IMAGE_EXTENSIONS = /\.(png|jpe?g|gif|webp|bmp|svg|avif|heic|heif)$/i
// ![[target]] or ![[target|size]], the Obsidian embed syntax.
const EMBED = /!\[\[([^\]|\n]+?)(?:\|([^\]\n]*))?\]\]/g

export function createImageSupport(host) {
  // Where relative paths start from (the note's folder) and where the notebook is served.
  let baseUrl = document.baseURI
  let notebookUrl = null

  function configure(options) {
    baseUrl = options.baseUrl ?? document.baseURI
    notebookUrl = options.notebookUrl ?? null
  }

  /** Notebook-relative path of the file [url] points at, if the host can find it. */
  function notebookPath(url) {
    if (!host?.resolveFile || !url || /^[a-z][a-z0-9+.-]*:/i.test(url) || url.startsWith('//')) return null
    let path = url.split(/[?#]/)[0]
    try {
      path = decodeURI(path)
    } catch {
      // Keep the raw text when it is not valid percent-encoding.
    }
    return host.resolveFile(path) || null
  }

  function displayUrl(url) {
    const path = notebookPath(url)
    if (path && notebookUrl) return notebookUrl + path.split('/').map(encodeURIComponent).join('/')
    if (!url || /^[a-z][a-z0-9+.-]*:/i.test(url)) return url
    try {
      return new URL(url, baseUrl).href
    } catch {
      return url
    }
  }

  /** DOM attributes for an image: where to load it from, and what to open when tapped. */
  function imageAttrs(url) {
    const path = notebookPath(url)
    return path ? { src: displayUrl(url), 'data-gn-path': path } : { src: displayUrl(url) }
  }

  // ---------------------------------------------------------------- ![[embed]] support

  /** Turns ![[image.png]] inside text into its own node; other embeds (notes) stay text. */
  const remarkEmbeds = $remark('remarkObsidianImageEmbeds', () => () => (tree) => {
    const visit = (node) => {
      if (!Array.isArray(node.children)) return
      const children = []
      for (const child of node.children) {
        if (child.type === 'text' && child.value.includes('![[')) {
          children.push(...splitEmbeds(child.value))
        } else {
          visit(child)
          children.push(child)
        }
      }
      node.children = children
    }
    visit(tree)
  })

  function splitEmbeds(text) {
    const parts = []
    let last = 0
    for (const match of text.matchAll(EMBED)) {
      const [whole, target, size] = match
      if (!IMAGE_EXTENSIONS.test(target.trim())) continue
      if (match.index > last) parts.push({ type: 'text', value: text.slice(last, match.index) })
      parts.push({ type: 'obsidianImageEmbed', target, size: size ?? null })
      last = match.index + whole.length
    }
    if (last < text.length) parts.push({ type: 'text', value: text.slice(last) })
    return parts.length ? parts : [{ type: 'text', value: text }]
  }

  const embedSchema = $nodeSchema('obsidian_image_embed', () => ({
    inline: true,
    group: 'inline',
    atom: true,
    selectable: true,
    attrs: {
      target: { default: '' },
      // Text after "|" exactly as written; "300" or "300x200" also sets the display width.
      size: { default: null },
    },
    parseDOM: [
      {
        tag: 'img[data-obsidian-embed]',
        getAttrs: (dom) => ({
          target: dom.getAttribute('data-obsidian-embed') ?? '',
          size: dom.getAttribute('data-size'),
        }),
      },
    ],
    toDOM: (node) => {
      const width = /^(\d+)(?:x\d+)?$/.exec(node.attrs.size ?? '')?.[1]
      return [
        'img',
        {
          ...imageAttrs(node.attrs.target),
          alt: node.attrs.target,
          'data-obsidian-embed': node.attrs.target,
          ...(node.attrs.size != null ? { 'data-size': node.attrs.size } : {}),
          ...(width ? { style: `width: ${width}px` } : {}),
        },
      ]
    },
    parseMarkdown: {
      match: (node) => node.type === 'obsidianImageEmbed',
      runner: (state, node, type) => state.addNode(type, { target: node.target, size: node.size }),
    },
    toMarkdown: {
      match: (node) => node.type.name === 'obsidian_image_embed',
      runner: (state, node) => {
        const { target, size } = node.attrs
        // Raw output, so the serializer does not escape the brackets.
        state.addNode('html', undefined, `![[${target}${size != null ? `|${size}` : ''}]]`)
      },
    },
  }))

  /** Tapping an image from the notebook opens it full screen in the host. */
  function handleTaps(root) {
    root.addEventListener('click', (event) => {
      const image = event.target.closest?.('img[data-gn-path]')
      if (image && host?.openImage) {
        event.preventDefault()
        host.openImage(image.getAttribute('data-gn-path'))
      }
    })
  }

  return { configure, imageAttrs, plugins: [remarkEmbeds, embedSchema].flat(), handleTaps }
}
