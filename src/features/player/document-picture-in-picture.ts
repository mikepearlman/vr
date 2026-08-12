import type { PreferredSplitAspect } from "../vr/config"
import { createSignal } from "solid-js"
import { getSplitAspectRatio } from "../vr/config"

const PICTURE_IN_PICTURE_HEIGHT = 569

export const getPictureInPictureSize = (aspect: PreferredSplitAspect) => {
  const width = Math.round(PICTURE_IN_PICTURE_HEIGHT * getSplitAspectRatio(aspect))
  return { width, height: PICTURE_IN_PICTURE_HEIGHT }
}

const copyDocumentStyles = (target: Document) => {
  for (const node of document.head.querySelectorAll<HTMLStyleElement | HTMLLinkElement>("style, link[rel=\"stylesheet\"]")) {
    const clone = node.cloneNode(true) as HTMLStyleElement | HTMLLinkElement
    if (node instanceof HTMLLinkElement && clone instanceof HTMLLinkElement) clone.href = node.href
    target.head.append(clone)
  }
}

export function createDocumentPictureInPicture(options: {
  getContent: () => HTMLElement
  getPreferredAspect: () => PreferredSplitAspect
  onLayoutChange?: () => void
  resourcesReady: () => boolean
}) {
  const [active, setActive] = createSignal(false)
  const supported = typeof window.documentPictureInPicture?.requestWindow === "function"
  let pipWindow: Window | undefined
  let restoreAnchor: Comment | undefined
  let opening = false
  let requestGeneration = 0

  const resizeWindow = (target: Window, aspect: PreferredSplitAspect) => {
    if (typeof target.resizeBy !== "function") return
    const size = getPictureInPictureSize(aspect)
    target.resizeBy(size.width - target.innerWidth, size.height - target.innerHeight)
  }

  const notifyLayoutChange = (target: Window) => {
    options.onLayoutChange?.()
    target.requestAnimationFrame(() => options.onLayoutChange?.())
  }

  const restore = () => {
    if (restoreAnchor?.isConnected) restoreAnchor.replaceWith(options.getContent())
    restoreAnchor = undefined
    pipWindow = undefined
    opening = false
    setActive(false)
    notifyLayoutChange(window)
  }

  const exit = () => {
    if (!pipWindow && !opening) return
    requestGeneration += 1
    pipWindow?.close()
    restore()
  }

  const enter = async () => {
    if (!supported || !options.resourcesReady() || pipWindow || opening) return
    const content = options.getContent()
    const anchor = document.createComment("vr-picture-in-picture")
    content.replaceWith(anchor)
    const generation = ++requestGeneration
    restoreAnchor = anchor
    opening = true

    try {
      const nextWindow = await window.documentPictureInPicture!.requestWindow(
        getPictureInPictureSize(options.getPreferredAspect()),
      )
      if (generation !== requestGeneration) {
        nextWindow.close()
        return
      }
      pipWindow = nextWindow
      copyDocumentStyles(nextWindow.document)
      nextWindow.document.documentElement.className = document.documentElement.className
      nextWindow.document.title = document.title
      nextWindow.document.body.className = "m-0 overflow-hidden bg-black"
      nextWindow.document.body.append(content)
      nextWindow.addEventListener("pagehide", () => {
        if (pipWindow === nextWindow) restore()
      }, { once: true })
      opening = false
      setActive(true)
      notifyLayoutChange(nextWindow)
    } catch (error) {
      if (generation !== requestGeneration) return
      restore()
      console.warn("picture-in-picture could not start", error)
    }
  }

  const toggle = async () => {
    if (pipWindow || opening) {
      exit()
      return
    }
    await enter()
  }

  return {
    active,
    dispose: exit,
    setPreferredAspect: (aspect: PreferredSplitAspect) => {
      if (!pipWindow) return
      resizeWindow(pipWindow, aspect)
      notifyLayoutChange(pipWindow)
    },
    supported,
    toggle,
  }
}
