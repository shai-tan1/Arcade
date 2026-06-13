import {
  useState,
  useEffect
} from "react";
import {
  useSelector
} from 'react-redux';
import { Link } from "react-router-dom";

import { CrystalIcon, SearchAndSort } from "../../shared/ui";
import { OptionsMenu } from "../../widgets";

import styles from "./HeaderMobile.module.css";

export function HeaderMobile() {

  const { showMobileSearchAndSort } = useSelector(
    (state) => state.showMobileSearchAndSort
  );

  // checking user log in
  const logInStatus = useSelector((state) => state.logInStatus)
  // /checking user log in

  const [showLogo, setShowLogo] = useState(true);
  const [showSearch, setShowSearch] = useState();

  useEffect(() => {
    window.addEventListener("scroll", () => {
      if (window.scrollY > 20) {
        setShowLogo(false);
        setShowSearch(true);
      } else {
        setShowLogo(true);
        setShowSearch(false);
      }
    });
  }, []);

  return (
    <div className={styles.header_mobile_wrap}>
      <div className={styles.logo_options_menu_wrap}>

        <Link className={styles.logo} to="/">
          <CrystalIcon />
          {(!logInStatus && showLogo) && <p>Crystal</p>}
        </Link>

        <OptionsMenu />
      </div>

      {showSearch &&
        (showMobileSearchAndSort) &&
        <div className={styles.search_and_sort_wrap}>
          <SearchAndSort />
        </div>
      }

    </div>
  );
}
