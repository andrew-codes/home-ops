import { configureStore } from "@reduxjs/toolkit"
import createSagaMiddleware from "redux-saga"
import macAddressReducer from "./features/macAddresses"
import saga from "./sideEffects/saga"

const sagaMiddleware = createSagaMiddleware()
const store = configureStore({
  reducer: {
    macAddresses: macAddressReducer,
  },
  middleware: (getDefaultMiddleware) =>
    getDefaultMiddleware().concat(sagaMiddleware),
})

sagaMiddleware.run(saga)

type RootState = ReturnType<typeof store.getState>
type AppDispatch = typeof store.dispatch

export { store }
export type { AppDispatch, RootState }
