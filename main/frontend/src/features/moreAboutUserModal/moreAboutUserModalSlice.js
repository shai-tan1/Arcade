import { createSlice } from "@reduxjs/toolkit";

const moreAboutUserModalSlice = createSlice({

  name: "moreAboutUser",
  initialState: {
    showMoreAboutUserModal: false,
    switchMoreAboutUserModal: true,
    userId: null,
  },

  reducers: {
    setShowMoreAboutUserModal: (state, action) => {
      state.showMoreAboutUserModal = action.payload;
    },
    setSwitchMoreAboutUserModal: (state, action) => {
      state.switchMoreAboutUserModal = action.payload;
    },
    setUserId: (state, action) => {
      state.userId = action.payload;
    },
  },

});

export const {
  setShowMoreAboutUserModal,
  setSwitchMoreAboutUserModal,
  setUserId,
} = moreAboutUserModalSlice.actions;

export const moreAboutUserModalReducer = moreAboutUserModalSlice.reducer;
