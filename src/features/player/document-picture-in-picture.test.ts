import { describe, expect, it } from "vitest"
import { getPictureInPictureSize } from "./document-picture-in-picture"

describe("document picture-in-picture sizing", () => {
  it("uses a square window for the 1:1 preference", () => {
    expect(getPictureInPictureSize("1:1")).toEqual({ width: 569, height: 569 })
  })

  it("uses a portrait window for the 9:16 preference", () => {
    expect(getPictureInPictureSize("9:16")).toEqual({ width: 320, height: 569 })
  })
})
