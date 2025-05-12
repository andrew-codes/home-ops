import type { PayloadAction } from "@reduxjs/toolkit"
import { createSlice } from "@reduxjs/toolkit"

export interface State {
  addresses: Record<string, boolean>
}

const initialState: State = {
  addresses: {},
}

export const macAddressesSlice = createSlice({
  name: "macAddresses",
  initialState,
  reducers: {
    connected: (state, action: PayloadAction<Array<string>>) => {
      action.payload.forEach((address) => {
        state.addresses[address] = true
      })
    },
    loaded: (state, action: PayloadAction<Array<string>>) => {
      action.payload.forEach((address) => {
        state.addresses[address] = true
      })
    },
  },
})

export const { loaded, connected } = macAddressesSlice.actions
export default macAddressesSlice.reducer
