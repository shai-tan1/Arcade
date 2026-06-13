import {
  useEffect,
  useState
} from "react";
import { useSelector } from "react-redux";

import { UpButtonIcon } from "../../../shared/ui";

import styles from "./UpButton.module.css";

export function UpButton() {
  const darkThemeStatus = useSelector((state) => state.darkThemeStatus);

  const [showUpButton, setShowUpButton] = useState(false);

  // to track proximity to the bottom
  const [isNearBottom, setIsNearBottom] = useState(false); 
  
  const scrollToTop = () => {
    window.scrollTo({
      top: 0,
    });
  };

  useEffect(() => {
    const handleScroll = () => {
      const currentScrollY = window.scrollY;
      
      // 1. Show the button
      setShowUpButton(currentScrollY > 300);

      // 2. Checking the bottom of the page
      
      // document.documentElement.scrollHeight - the full height of the page
      const totalHeight = document.documentElement.scrollHeight;
      
      // window.innerHeight + window.scrollY - how much we see + how much we scrolled.
      // Math.ceil is needed to round off fractional pixels on mobile devices.
      const currentBottomPosition = Math.ceil(window.innerHeight + currentScrollY);
      
      const nearBottomThreshold = 170; 

      const isAtBottom = currentBottomPosition >= (totalHeight - nearBottomThreshold);
      
      setIsNearBottom(isAtBottom);
    };

    // passive: true improves scrolling performance on mobile devices.
    window.addEventListener("scroll", handleScroll, { passive: true });
    
    return () => window.removeEventListener("scroll", handleScroll); 
  }, []);

  return (
    showUpButton &&
    <div
      onClick={scrollToTop}
      className={styles.up_button}
      data-up-button-dark-theme={darkThemeStatus}
      data-near-bottom={isNearBottom} 
      >
      <UpButtonIcon />
    </div>
  );
}