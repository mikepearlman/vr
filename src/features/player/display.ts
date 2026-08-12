import type { ValueUpdate } from "../../lib/value-update"
import type { CameraView, PreferredSplitAspect, SplitCount } from "../vr/config"
import { createSignal, createStore } from "solid-js"
import { resolveValueUpdate } from "../../lib/value-update"
import { DEFAULT_FORWARD, DEFAULT_PREFERRED_SPLIT_ASPECT, DEFAULT_SPLIT_COUNT, QUALITY_OPTIONS } from "../vr/config"
import { createDocumentPictureInPicture } from "./document-picture-in-picture"

interface ViewRef { current: CameraView }

export function createDisplay(options: {
  getPlayer: () => HTMLElement
  resourcesReady: () => boolean
  viewRef: ViewRef
  onManualViewChange?: () => void
  onPictureInPictureLayoutChange?: () => void
  initialState?: Partial<{
    qualityId: number
    renderFrameRateId: number
    splitCount: SplitCount
    preferredSplitAspect: PreferredSplitAspect
    faceAutoCenter: boolean
    resumeFaceAutoCenterAfterViewChange: boolean
  }>
}) {
  const [state, setState] = createStore({
    projectionId: 0,
    qualityId: options.initialState?.qualityId ?? 2,
    renderFrameRateId: options.initialState?.renderFrameRateId ?? 3,
    splitCount: options.initialState?.splitCount ?? DEFAULT_SPLIT_COUNT,
    preferredSplitAspect: options.initialState?.preferredSplitAspect ?? DEFAULT_PREFERRED_SPLIT_ASPECT,
    faceAutoCenter: options.initialState?.faceAutoCenter ?? true,
    resumeFaceAutoCenterAfterViewChange: options.initialState?.resumeFaceAutoCenterAfterViewChange ?? true,
  })
  const [fullscreen, setFullscreen] = createSignal(false)
  let pictureInPictureContent!: HTMLElement
  const documentPictureInPicture = createDocumentPictureInPicture({
    getContent: () => pictureInPictureContent,
    getPreferredAspect: () => state.preferredSplitAspect,
    onLayoutChange: options.onPictureInPictureLayoutChange,
    resourcesReady: options.resourcesReady,
  })

  const setValue = <K extends keyof typeof state>(key: K, update: ValueUpdate<(typeof state)[K]>) => {
    setState((draft) => {
      draft[key] = resolveValueUpdate(draft[key], update)
    })
  }
  const setProjectionId = (update: ValueUpdate<number>) => {
    const next = resolveValueUpdate(state.projectionId, update)
    setValue("projectionId", next)
    return next
  }
  const setQualityId = (update: ValueUpdate<number>) => setValue("qualityId", update)
  const setRenderFrameRateId = (update: ValueUpdate<number>) => {
    const next = resolveValueUpdate(state.renderFrameRateId, update)
    setValue("renderFrameRateId", Math.min(3, Math.max(1, Math.round(next))))
  }
  const setSplitCount = (update: ValueUpdate<SplitCount>) => setValue("splitCount", update)
  const setPreferredSplitAspect = (update: ValueUpdate<PreferredSplitAspect>) => {
    const next = resolveValueUpdate(state.preferredSplitAspect, update)
    setValue("preferredSplitAspect", next)
    documentPictureInPicture.setPreferredAspect(next)
  }
  const setFaceAutoCenter = (update: ValueUpdate<boolean>) => setValue("faceAutoCenter", update)
  const setResumeFaceAutoCenterAfterViewChange = (update: ValueUpdate<boolean>) =>
    setValue("resumeFaceAutoCenterAfterViewChange", update)

  const restoreProjection = (projectionId: number) => {
    setValue("projectionId", projectionId)
  }

  const resetTransientView = () => {
    options.viewRef.current.yaw = 0
    options.viewRef.current.pitch = 0
    options.viewRef.current.forward = DEFAULT_FORWARD
    options.viewRef.current.pausedUntil = performance.now() + 900
  }

  const resetView = () => {
    if (!options.resourcesReady()) return
    resetTransientView()
    options.onManualViewChange?.()
  }

  const changeQualityBy = (amount: number) => {
    if (!options.resourcesReady()) return
    setQualityId(current => Math.min(QUALITY_OPTIONS.length - 1, Math.max(0, current + amount)))
  }

  const toggleFullscreen = async () => {
    if (!options.resourcesReady()) return
    try {
      if (document.fullscreenElement) {
        await document.exitFullscreen()
      } else {
        await options.getPlayer().requestFullscreen()
      }
    } catch (error) {
      console.warn("fullscreen toggle failed", error)
    }
  }

  const syncFullscreen = () => {
    setFullscreen(document.fullscreenElement === options.getPlayer())
  }

  const controller = {
    fullscreen,
    pictureInPicture: documentPictureInPicture.active,
    pictureInPictureSupported: documentPictureInPicture.supported,
    resetView,
    setFaceAutoCenter,
    setResumeFaceAutoCenterAfterViewChange,
    setProjectionId,
    setQualityId,
    setRenderFrameRateId,
    setSplitCount,
    setPreferredSplitAspect,
    state,
    togglePictureInPicture: documentPictureInPicture.toggle,
    toggleFullscreen,
  }

  return {
    changeQualityBy,
    controller,
    dispose: documentPictureInPicture.dispose,
    faceAutoCenter: () => state.faceAutoCenter,
    projectionId: () => state.projectionId,
    qualityId: () => state.qualityId,
    renderFrameRateId: () => state.renderFrameRateId,
    preferredSplitAspect: () => state.preferredSplitAspect,
    resumeFaceAutoCenterAfterViewChange: () => state.resumeFaceAutoCenterAfterViewChange,
    splitCount: () => state.splitCount,
    resetTransientView,
    restoreProjection,
    setPictureInPictureContent: (element: HTMLElement) => (pictureInPictureContent = element),
    syncFullscreen,
  }
}
