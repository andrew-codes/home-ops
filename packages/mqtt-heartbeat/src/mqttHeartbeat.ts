import { logger } from "@ha/logger"
import createSagaMiddleware from "@redux-saga/core"
import { applyMiddleware, createStore } from "redux"
import { reducer, registerWithHomeAssistant, saga } from "./redux"

const createHeartbeat = async (serviceName: string): Promise<void> => {
  logger.info("Started")
  const sagaMiddleware = createSagaMiddleware()
  const store = createStore(reducer, applyMiddleware(sagaMiddleware))
  sagaMiddleware.run(saga)
  store.dispatch(registerWithHomeAssistant(serviceName))
}

export default createHeartbeat
