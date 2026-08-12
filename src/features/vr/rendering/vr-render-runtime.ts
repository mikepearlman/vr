import type { PerspectiveCamera } from "three"
import type { CameraView, PreferredSplitAspect, ProjectionMode, ProjectionQuality, SplitCount } from "../config"
import { MathUtils, Vector3 } from "three"
import { getSplitAspectRatio } from "../config"
import { createVrPlayerRenderer } from "./vr-player-renderer"

type ValueOrGetter<T> = T | (() => T)

export interface ReadonlyRefObject<T> { readonly current: T }

export interface PanoramaRenderTile {
  yaw: number
  pitch: number
  fov: number
}

export interface InferenceFrameSize {
  width: number
  height: number
}

export interface RenderViewport { x: number, y: number, width: number, height: number }

export interface VrCanvasMetrics {
  width: number
  height: number
  pixelRatio: number
}

export interface VrRenderRuntimeOptions {
  video: HTMLVideoElement
  mount: HTMLElement
  projection: ValueOrGetter<ProjectionMode>
  quality: ValueOrGetter<ProjectionQuality>
  splitCount: ValueOrGetter<SplitCount>
  preferredSplitAspect: ValueOrGetter<PreferredSplitAspect>
  viewRef: ReadonlyRefObject<CameraView> | (() => CameraView)
}

export interface VrRenderRuntime {
  readonly camera: PerspectiveCamera
  readonly canvas: HTMLCanvasElement
  setProjection: (projection?: ProjectionMode) => void
  setQuality: (quality?: ProjectionQuality) => void
  resize: () => void
  applyCameraPose: (view?: CameraView) => void
  renderVisibleViewports: () => void
  captureViewportInference: (
    targetCanvas: HTMLCanvasElement,
    targetContext: CanvasRenderingContext2D,
    sampleWidth: number,
  ) => InferenceFrameSize | undefined
  capturePanoramaTile: (
    targetCanvas: HTMLCanvasElement,
    targetContext: CanvasRenderingContext2D,
    tile: PanoramaRenderTile,
    sampleWidth: number,
  ) => InferenceFrameSize | undefined
  invalidateTexture: () => void
  getSplitCount: () => number
  getCanvasMetrics: () => VrCanvasMetrics
  getGpuLabel: () => string
  clearMediaFrame: () => void
  resetMedia: () => void
  destroy: () => void
}

export const getRenderViewports = (
  width: number,
  height: number,
  splitCount: SplitCount,
  preferredSplitAspect: PreferredSplitAspect,
): RenderViewport[] => {
  if (splitCount === 1 || width <= height) return [{ x: 0, y: 0, width, height }]

  const preferredAspect = getSplitAspectRatio(preferredSplitAspect)
  const preferredPanelCount = Math.max(1, Math.round(width / (height * preferredAspect)))
  const panelCount = Math.min(splitCount, preferredPanelCount)
  const panelWidth = width / panelCount
  return Array.from({ length: panelCount }, (_, index) => ({
    x: panelWidth * index,
    y: 0,
    width: panelWidth,
    height,
  }))
}

const resizeCanvas = (canvas: HTMLCanvasElement, width: number, height: number) => {
  if (canvas.width !== width) canvas.width = width
  if (canvas.height !== height) canvas.height = height
}

export const getViewportInferenceSampleSize = (sourceWidth: number, sourceHeight: number, sampleWidth: number) => {
  if (!sourceWidth || !sourceHeight) return undefined
  const width = Math.max(160, Math.round(sampleWidth))
  return { width, height: Math.max(120, Math.round(width / (sourceWidth / sourceHeight))) }
}

export const drawViewportInferenceSample = (
  canvas: HTMLCanvasElement,
  context: CanvasRenderingContext2D,
  source: CanvasImageSource,
  sourceX: number,
  sourceY: number,
  sourceWidth: number,
  sourceHeight: number,
  sampleWidth: number,
) => {
  const size = getViewportInferenceSampleSize(sourceWidth, sourceHeight, sampleWidth)
  if (!size) return undefined
  resizeCanvas(canvas, size.width, size.height)
  context.drawImage(
    source,
    sourceX,
    sourceY,
    sourceWidth,
    sourceHeight,
    0,
    0,
    size.width,
    size.height,
  )
  return size
}

const readValue = <T>(source: ValueOrGetter<T>): T =>
  typeof source === "function" ? (source as () => T)() : source

export const createVrRenderRuntime = (options: VrRenderRuntimeOptions): VrRenderRuntime => {
  const initialWidth = Math.max(1, options.mount.clientWidth)
  const initialHeight = Math.max(1, options.mount.clientHeight)
  const initialSplitCount = readValue(options.splitCount)
  const initialPreferredSplitAspect = readValue(options.preferredSplitAspect)
  const initialViewport = getRenderViewports(initialWidth, initialHeight, initialSplitCount, initialPreferredSplitAspect)[0]
  const core = createVrPlayerRenderer({
    video: options.video,
    projection: readValue(options.projection),
    quality: readValue(options.quality),
    width: options.mount.clientWidth,
    height: options.mount.clientHeight,
    aspect: initialViewport.width / initialViewport.height,
    devicePixelRatio: window.devicePixelRatio || 1,
  })
  const { camera, renderer, scene, texture } = core
  const canvas = renderer.domElement
  const cameraForward = new Vector3()
  let disposed = false

  const getSplitCount = () => readValue(options.splitCount)
  const getPreferredSplitAspect = () => readValue(options.preferredSplitAspect)
  const getView = () => typeof options.viewRef === "function"
    ? options.viewRef()
    : options.viewRef.current
  const getMountSize = () => ({
    width: Math.max(1, options.mount.clientWidth),
    height: Math.max(1, options.mount.clientHeight),
  })
  const getVisibleViewports = (width: number, height: number): RenderViewport[] =>
    getRenderViewports(width, height, getSplitCount(), getPreferredSplitAspect())

  const resize = () => {
    const { width, height } = getMountSize()
    const primaryViewport = getVisibleViewports(width, height)[0]
    core.setSize(width, height, primaryViewport.width / primaryViewport.height)
  }

  const setQuality = (quality = readValue(options.quality)) => {
    core.setQuality(quality, window.devicePixelRatio || 1)
    core.setSize(options.mount.clientWidth, options.mount.clientHeight, camera.aspect)
    canvas.style.imageRendering = "auto"
    canvas.dataset.quality = quality
    canvas.dataset.pixelRatio = renderer.getPixelRatio().toFixed(2)
  }

  const applyCameraPose = (view = getView()) => {
    camera.rotation.set(MathUtils.degToRad(view.pitch), MathUtils.degToRad(view.yaw), 0, "YXZ")
    cameraForward
      .set(0, 0, -1)
      .applyEuler(camera.rotation)
      .multiplyScalar(view.forward)
    camera.position.copy(cameraForward)
  }

  const renderVisibleViewports = () => {
    const { width, height } = getMountSize()
    const viewports = getVisibleViewports(width, height)
    renderer.setScissorTest(viewports.length > 1)
    renderer.setViewport(0, 0, width, height)
    renderer.setScissor(0, 0, width, height)
    viewports.forEach((viewport) => {
      renderer.setViewport(viewport.x, viewport.y, viewport.width, viewport.height)
      renderer.setScissor(viewport.x, viewport.y, viewport.width, viewport.height)
      renderer.render(scene, camera)
    })
    renderer.setScissorTest(false)
  }

  const captureViewportInference = (
    targetCanvas: HTMLCanvasElement,
    targetContext: CanvasRenderingContext2D,
    sampleWidth: number,
  ) => {
    const viewports = getVisibleViewports(canvas.width, canvas.height)
    const sourceRect = viewports[Math.floor(viewports.length / 2)]
    return drawViewportInferenceSample(
      targetCanvas,
      targetContext,
      canvas,
      sourceRect.x,
      sourceRect.y,
      sourceRect.width,
      sourceRect.height,
      sampleWidth,
    )
  }

  const capturePanoramaTile = (
    targetCanvas: HTMLCanvasElement,
    targetContext: CanvasRenderingContext2D,
    tile: PanoramaRenderTile,
    sampleWidth: number,
  ) => {
    const savedCamera = {
      aspect: camera.aspect,
      fov: camera.fov,
      zoom: camera.zoom,
      x: camera.rotation.x,
      y: camera.rotation.y,
      z: camera.rotation.z,
      order: camera.rotation.order,
      positionX: camera.position.x,
      positionY: camera.position.y,
      positionZ: camera.position.z,
    }
    const { width, height } = getMountSize()
    const side = Math.max(1, Math.min(width, height))
    const sidePixels = Math.min(
      canvas.width,
      canvas.height,
      Math.max(1, Math.round(side * renderer.getPixelRatio())),
    )

    let size: InferenceFrameSize | undefined
    try {
      camera.aspect = 1
      camera.fov = tile.fov
      camera.zoom = 1
      camera.position.set(0, 0, 0)
      camera.rotation.set(MathUtils.degToRad(tile.pitch), MathUtils.degToRad(tile.yaw), 0, "YXZ")
      camera.updateProjectionMatrix()
      renderer.setScissorTest(true)
      renderer.setViewport(0, 0, side, side)
      renderer.setScissor(0, 0, side, side)
      renderer.render(scene, camera)

      size = drawViewportInferenceSample(
        targetCanvas,
        targetContext,
        canvas,
        0,
        canvas.height - sidePixels,
        sidePixels,
        sidePixels,
        sampleWidth,
      )
    } finally {
      camera.aspect = savedCamera.aspect
      camera.fov = savedCamera.fov
      camera.zoom = savedCamera.zoom
      camera.position.set(savedCamera.positionX, savedCamera.positionY, savedCamera.positionZ)
      camera.rotation.set(savedCamera.x, savedCamera.y, savedCamera.z, savedCamera.order)
      camera.updateProjectionMatrix()
      renderVisibleViewports()
    }

    return size
  }

  canvas.className = "block h-dvh w-full touch-none saturate-105 contrast-102"
  setQuality()
  options.mount.appendChild(canvas)

  return {
    camera,
    canvas,
    setProjection: projection => core.setProjection(projection ?? readValue(options.projection)),
    setQuality,
    resize,
    applyCameraPose,
    renderVisibleViewports,
    captureViewportInference,
    capturePanoramaTile,
    invalidateTexture: () => (texture.needsUpdate = true),
    getSplitCount: () => {
      const { width, height } = getMountSize()
      return getVisibleViewports(width, height).length
    },
    getCanvasMetrics: () => ({
      width: canvas.width,
      height: canvas.height,
      pixelRatio: renderer.getPixelRatio(),
    }),
    getGpuLabel: () => {
      const gl = renderer.getContext()
      const rendererInfo = gl.getExtension("WEBGL_debug_renderer_info")
      return String(rendererInfo
        ? gl.getParameter(rendererInfo.UNMASKED_RENDERER_WEBGL)
        : gl.getParameter(gl.RENDERER))
    },
    clearMediaFrame: core.clearMediaFrame,
    resetMedia: () => {
      texture.needsUpdate = true
      core.resetMedia()
    },
    destroy: () => {
      if (disposed) return
      disposed = true
      core.destroy()
      canvas.remove()
    },
  }
}
