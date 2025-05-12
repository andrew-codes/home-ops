import { logger } from "@ha/logger"
import { createMqtt } from "@ha/mqtt-client"
import { call, select, takeLatest } from "redux-saga/effects"
import { connected } from "../features/macAddresses"

function* publishUniqueMacAddresses(action: ReturnType<typeof connected>) {
  const existingAddresses = yield select(
    (state) => state.macAddresses.addresses,
  )
  const newMacAddresses = action.payload.filter(
    (mac) => !existingAddresses[mac],
  )

  if (newMacAddresses.length > 0) {
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
        JSON.stringify(newMacAddresses),
      )
    } catch (error) {
      logger.error("Error publishing MAC addresses:", error)
    }
  }
}

function* saga() {
  yield takeLatest(connected.type, publishUniqueMacAddresses)
}

export default saga
