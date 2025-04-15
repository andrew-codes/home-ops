jest.mock("@ha/mqtt-client")
jest.mock("@ha/http-heartbeat")
jest.mock("@ha/unifi-client")
import { createHeartbeat } from "@ha/http-heartbeat"
import type { AsyncMqttClient } from "@ha/mqtt-client"
import { createMqtt } from "@ha/mqtt-client"
import { Controller, createUnifi } from "@ha/unifi-client"
import { when } from "jest-when"
import run from "../app"

describe.skip("guest wifi renewal", () => {
  const subscribe = jest.fn()
  const onMock = jest.fn()
  const authorizeGuest = jest.fn()

  beforeEach(() => {
    jest.mocked(createMqtt).mockResolvedValue({
      on: onMock,
      subscribe,
    } as unknown as AsyncMqttClient)
    jest.mocked(createUnifi).mockResolvedValue({
      authorizeGuest,
    } as unknown as Controller)
  })

  test("sets up a heartbeat health check", async () => {
    await run()

    expect(createHeartbeat).toBeCalled()
  })

  test("run will subscribe to device renewal topics", async () => {
    await run()

    expect(subscribe).toHaveBeenCalledWith("homeassistant/group/guest/renew")
  })

  test("messages with topics other than device renewal do not authorize devices", async () => {
    let messageHandler
    when(onMock)
      .calledWith("message", expect.any(Function))
      .mockImplementation((type, handler) => {
        messageHandler = handler
      })
    await run()

    await messageHandler("another/message", "{}")
    expect(authorizeGuest).not.toHaveBeenCalled()
  })

  test("messages with device renewal topic will authorize all registered guest devices provided in mqtt message", async () => {
    let messageHandler
    ;(onMock as jest.Mock).mockImplementation((type, handler) => {
      messageHandler = handler
    })

    await run()

    await messageHandler("homeassistant/group/guest/renew", "address,address-2")
    expect(authorizeGuest).toHaveBeenCalledWith("address", 4320)
    expect(authorizeGuest).toHaveBeenCalledWith("address-2", 4320)
  })
})
