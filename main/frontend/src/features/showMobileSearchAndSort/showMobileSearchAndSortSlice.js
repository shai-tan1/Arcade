import { createSlice } from "@reduxjs/toolkit";

const showMobileSearchAndSortSlice = createSlice({

  name: "showMobileSearchAndSort",
  initialState: {
    showMobileSearchAndSort: false,
  },

  reducers: {
    setShowMobileSearchAndSort: (state, action) => {
      state.showMobileSearchAndSort = action.payload;
    }
  },

});

export const {
  setShowMobileSearchAndSort
} = showMobileSearchAndSortSlice.actions;

export const showMobileSearchAndSortReducer = showMobileSearchAndSortSlice.reducer;
