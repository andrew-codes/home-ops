import { logger } from "@ha/logger"
import { createMqtt } from "@ha/mqtt-client"
import { isEmpty } from "lodash"
import { call, takeLatest } from "redux-saga/effects"
import { connected } from "../features/macAddresses"

function* publishUniqueMacAddresses(action: ReturnType<typeof connected>) {
  if (isEmpty(action.payload)) {
    logger.warn("No MAC addresses to publish")
    return
  }

  try {
    const mqtt = yield call(
      createMqtt,
      process.env.MQTT_HOST,
      parseInt(process.env.MQTT_PORT || "1883", 10),
      process.env.MQTT_USERNAME,
      process.env.MQTT_PASSWORD,
    )
    yield call(
      mqtt.publish,
      "guest-registrar-unifi/guests",
      JSON.stringify(action.payload),
    )
  } catch (error) {
    logger.error("Error publishing MAC addresses:", error)
  }
}

function* saga() {
  yield takeLatest(connected.type, publishUniqueMacAddresses)
}

export default saga
