import { configureStore } from "@reduxjs/toolkit";

import {
  themeReducer,
  logInStatusReducer,
  accessModalReducer,
  sideMenuMobileReducer,
  moreAboutUserModalReducer,
  showMobileSearchAndSortReducer
} from "../features";

export const store = configureStore({
  reducer: {
    darkThemeStatus: themeReducer,
    logInStatus: logInStatusReducer,
    accessModal: accessModalReducer,
    sideMenuMobile: sideMenuMobileReducer,
    moreAboutUserModal: moreAboutUserModalReducer,
    showMobileSearchAndSort: showMobileSearchAndSortReducer
  },
});
